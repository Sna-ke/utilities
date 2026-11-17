#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners.
#
# What it does (each step is safe to run again; finished steps are skipped):
#   1. Updates the system and turns on automatic security updates.
#   2. Hardens SSH (keys only) and turns on the firewall (SSH in, nothing else).
#   3. Installs Docker Engine from Docker's own apt repository. Published ports bind
#      to 127.0.0.1 by default, because Docker's port rules bypass the firewall.
#   4. Creates the "runner" user, adds swap on small machines, and schedules a weekly
#      Docker clean-up.
#   5. Downloads the latest runner release, checks its SHA-256, and registers runners
#      for each repository as systemd services.
#
# Usage (as root, on the VM):
#   setup-runner.sh            set up, or add missing runners
#   setup-runner.sh status     list the runner services
#   setup-runner.sh remove     unregister every runner on this VM (before deleting it)
#
# Settings come from environment variables (defaults in brackets):
#   GITHUB_OWNER        [Sna-ke]      account that owns the repositories
#   RUNNER_REPOS        [GroundCore]  comma-separated repositories to serve
#   RUNNER_COUNT        [auto]        runners per repository; auto = 2 with 10 GB RAM or more, else 1
#   STACK_LABEL         [auto]        give each repository's first runner the "<repo>-stack" label;
#                                     auto = yes with 6 GB RAM or more
#   SWAP_SIZE_GB        [auto]        swap file size; auto = 4 below 10 GB RAM, else none
#   RUNNER_NAME_PREFIX  [hostname]    runner names are <prefix>-<repo>-<n>
#   GITHUB_TOKEN        [none]        fine-grained token with Administration: read and write on the
#                                     repositories; used only to ask GitHub for registration tokens and
#                                     never written to disk. Without it, the script asks you to paste a
#                                     registration token from the repository's Settings page per runner.
#
# Labels: every runner gets "<repo>-ci" (lower case, e.g. groundcore-ci); the first runner of each
# repository also gets "<repo>-stack" when STACK_LABEL is on. The repository's CI picks runners by
# these labels (GroundCore: deploy/ci-runner.md).
#
# Secrets: none are stored in this script or written by it. Registration tokens expire after an hour.

set -Eeuo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-Sna-ke}"
RUNNER_REPOS="${RUNNER_REPOS:-GroundCore}"
RUNNER_COUNT="${RUNNER_COUNT:-auto}"
STACK_LABEL="${STACK_LABEL:-auto}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-auto}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s)}"
RUNNER_USER="runner"
RUNNER_HOME="/home/${RUNNER_USER}"
DOWNLOAD_DIR="/var/cache/actions-runner"

log() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR

# ---------------------------------------------------------------------------------------------
# Checks and machine facts
# ---------------------------------------------------------------------------------------------

require_root_on_ubuntu() {
  [[ ${EUID} -eq 0 ]] || die "run as root: sudo bash $0"
  # shellcheck source=/dev/null
  . /etc/os-release
  # shellcheck disable=SC2154 # ID and VERSION_ID come from /etc/os-release.
  [[ ${ID} == "ubuntu" ]] || die "this script supports Ubuntu only (found ${ID})"
  # shellcheck disable=SC2154
  [[ ${VERSION_ID} == "24.04" ]] || note "tested on Ubuntu 24.04; this is ${VERSION_ID}, continuing"
}

# Total memory in whole gigabytes, rounded to the nearest (a "4 GB" VPS reports about 3.8).
memory_gb() {
  awk '/MemTotal/ { printf "%d", ($2 / 1024 / 1024) + 0.5 }' /proc/meminfo
}

# The runner release's name for this CPU.
runner_architecture() {
  case "$(uname -m)" in
    x86_64) echo "x64" ;;
    aarch64) echo "arm64" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# Resolves the "auto" settings from the machine's memory, so one script fits VPS-1 to VPS-3.
resolve_auto_settings() {
  local memory
  memory="$(memory_gb)"
  if [[ ${RUNNER_COUNT} == "auto" ]]; then
    if ((memory >= 10)); then RUNNER_COUNT=2; else RUNNER_COUNT=1; fi
  fi
  if [[ ${STACK_LABEL} == "auto" ]]; then
    # The GroundCore stack job needs about 3-4 GB on its own; below 6 GB it stays on GitHub's runners.
    if ((memory >= 6)); then STACK_LABEL="yes"; else STACK_LABEL="no"; fi
  fi
  if [[ ${SWAP_SIZE_GB} == "auto" ]]; then
    if ((memory < 10)); then SWAP_SIZE_GB=4; else SWAP_SIZE_GB=0; fi
  fi
  note "memory ${memory} GB: ${RUNNER_COUNT} runner(s) per repository, stack label ${STACK_LABEL}, swap ${SWAP_SIZE_GB} GB"
}

# ---------------------------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------------------------

install_base_packages() {
  log "Updating the system and installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get full-upgrade -yq
  apt-get install -yq ca-certificates curl git jq unzip ufw unattended-upgrades libicu-dev
}

enable_automatic_updates() {
  log "Turning on automatic security updates"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# Keys only. Skipped when no authorized key exists anywhere, so the script can't lock you out.
harden_ssh() {
  log "Hardening SSH"
  local key_files
  key_files="$(find /root/.ssh /home/*/.ssh -name authorized_keys -size +0 2>/dev/null || true)"
  if [[ -z ${key_files} ]]; then
    note "no SSH authorized_keys found; leaving password login on. Add a key, then run this again."
    return
  fi
  cat >/etc/ssh/sshd_config.d/10-runner-host.conf <<'EOF'
# Written by setup-runner.sh: SSH keys only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  # Ubuntu 24.04 starts sshd on demand (ssh.socket), so its privilege separation directory may not
  # exist yet, and "sshd -t" fails without it.
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/10-runner-host.conf
    die "the new SSH settings failed sshd's check; they were removed and nothing was reloaded"
  fi
  # Reloads a running sshd; with socket activation an idle sshd reads the new settings on its next start.
  systemctl try-reload-or-restart ssh
  note "password login is off"
}

# Runners only make outgoing HTTPS calls to GitHub, so nothing but SSH comes in.
configure_firewall() {
  log "Turning on the firewall (SSH only)"
  ufw allow OpenSSH >/dev/null
  ufw --force enable >/dev/null
  ufw status | sed 's/^/    /'
}

# Memory-heavy jobs (.NET builds, Testcontainers) can briefly exceed small machines' RAM.
configure_swap() {
  ((SWAP_SIZE_GB > 0)) || return 0
  log "Adding ${SWAP_SIZE_GB} GB of swap"
  if swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
    note "already on"
    return
  fi
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  echo 'vm.swappiness=10' >/etc/sysctl.d/90-runner-swap.conf
  sysctl -q -p /etc/sysctl.d/90-runner-swap.conf
}

# ---------------------------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------------------------

# Docker's own apt repository, as in Docker's "Install Docker Engine on Ubuntu" guide.
install_docker() {
  log "Installing Docker Engine"
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    note "already installed: $(docker --version)"
    return
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-${VERSION_CODENAME}} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Published ports bind to 127.0.0.1 unless a job says otherwise: Docker's iptables rules bypass ufw,
# and a CI stack must never be reachable from the internet. Container logs are capped.
configure_docker_daemon() {
  log "Configuring the Docker daemon"
  local settings='{"ip":"127.0.0.1","log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'
  local file=/etc/docker/daemon.json
  mkdir -p /etc/docker
  if [[ -s ${file} ]]; then
    jq --argjson add "${settings}" '. * $add' "${file}" >"${file}.new"
  else
    jq -n --argjson add "${settings}" '$add' >"${file}.new"
  fi
  if cmp -s "${file}.new" "${file}"; then
    rm "${file}.new"
    note "unchanged"
    return
  fi
  mv "${file}.new" "${file}"
  systemctl restart docker
  note "published ports default to 127.0.0.1; logs capped at 30 MB per container"
}

schedule_docker_cleanup() {
  log "Scheduling a weekly Docker clean-up"
  cat >/etc/cron.weekly/docker-prune <<'EOF'
#!/bin/sh
# Written by setup-runner.sh: CI leaves images, build cache and volumes behind.
docker system prune -af --filter "until=168h" >/dev/null
docker volume prune -af >/dev/null
EOF
  chmod +x /etc/cron.weekly/docker-prune
}

# ---------------------------------------------------------------------------------------------
# The runner user and the runner software
# ---------------------------------------------------------------------------------------------

# Docker group membership is already root-equivalent, and Playwright's --with-deps installs browser
# libraries with apt, so the runner user may sudo. That is why this VM must hold nothing else.
create_runner_user() {
  log "Creating the ${RUNNER_USER} user"
  if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${RUNNER_USER}" >/dev/null
  fi
  usermod -aG docker "${RUNNER_USER}"
  local sudoers=/etc/sudoers.d/${RUNNER_USER}
  echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" >"${sudoers}.new"
  visudo -cqf "${sudoers}.new" || die "sudoers file failed its check"
  chmod 440 "${sudoers}.new"
  mv "${sudoers}.new" "${sudoers}"

  # actions/setup-dotnet installs into /usr/share/dotnet, which GitHub's own images make writable.
  # Without this, every .NET job fails with "cannot create directory '/usr/share/dotnet'".
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" /usr/share/dotnet
}

# Downloads the latest runner release once and checks it against GitHub's published SHA-256:
# the release asset's digest, or the checksum GitHub lists in the release notes.
# Prints the path of the verified archive.
download_runner() {
  local architecture release version asset expected archive actual
  architecture="$(runner_architecture)"
  release="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
  version="$(jq -r '.tag_name | ltrimstr("v")' <<<"${release}")"
  asset="actions-runner-linux-${architecture}-${version}.tar.gz"
  archive="${DOWNLOAD_DIR}/${asset}"

  expected="$(jq -r --arg name "${asset}" '.assets[] | select(.name == $name) | .digest // empty' <<<"${release}")"
  expected="${expected#sha256:}"
  if [[ -z ${expected} ]]; then
    expected="$(jq -r '.body' <<<"${release}" |
      grep -oE "BEGIN SHA linux-${architecture} -->[0-9a-f]{64}" | grep -oE '[0-9a-f]{64}$' || true)"
  fi
  [[ ${expected} =~ ^[0-9a-f]{64}$ ]] || die "no published SHA-256 found for ${asset}"

  mkdir -p "${DOWNLOAD_DIR}"
  if [[ ! -f ${archive} ]]; then
    curl -fsSL -o "${archive}.part" \
      "https://github.com/actions/runner/releases/download/v${version}/${asset}"
    mv "${archive}.part" "${archive}"
  fi
  actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
  if [[ ${actual} != "${expected}" ]]; then
    rm -f "${archive}"
    die "SHA-256 mismatch for ${asset}: expected ${expected}, got ${actual}"
  fi
  echo "${archive}"
}

# Asks GitHub for a short-lived registration or removal token for one repository.
# kind: registration-token | remove-token
runner_token() {
  local repository="$1" kind="$2" token
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    token="$(curl -fsSL -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${GITHUB_OWNER}/${repository}/actions/runners/${kind}" | jq -r '.token')"
  else
    local action="New self-hosted runner"
    [[ ${kind} == "remove-token" ]] && action="the runner's Remove button"
    printf '    Paste a token for %s/%s (Settings > Actions > Runners > %s): ' \
      "${GITHUB_OWNER}" "${repository}" "${action}" >/dev/tty
    read -r -s token </dev/tty
    printf '\n' >/dev/tty
  fi
  [[ -n ${token} && ${token} != "null" ]] || die "no ${kind} for ${repository}"
  echo "${token}"
}

# Installs, registers and starts runner number <index> for one repository. Skips a runner that is
# already registered, so running the script again only adds what is missing.
install_runner() {
  local repository="$1" index="$2" archive="$3"
  local slug directory name labels token
  slug="$(tr '[:upper:]' '[:lower:]' <<<"${repository}")"
  directory="${RUNNER_HOME}/${slug}-${index}"
  name="${RUNNER_NAME_PREFIX}-${slug}-${index}"
  labels="${slug}-ci"
  if [[ ${index} -eq 1 && ${STACK_LABEL} == "yes" ]]; then labels="${labels},${slug}-stack"; fi

  log "Runner ${name} (labels: ${labels})"
  if [[ -f ${directory}/.runner ]]; then
    note "already registered"
    return
  fi
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${directory}"
  tar -xzf "${archive}" -C "${directory}"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${directory}"
  "${directory}/bin/installdependencies.sh" >/dev/null

  token="$(runner_token "${repository}" registration-token)"
  (cd "${directory}" && sudo -u "${RUNNER_USER}" ./config.sh --unattended --replace \
    --url "https://github.com/${GITHUB_OWNER}/${repository}" --token "${token}" \
    --name "${name}" --labels "${labels}" --work _work)
  (cd "${directory}" && ./svc.sh install "${RUNNER_USER}" >/dev/null && ./svc.sh start >/dev/null)
  note "registered and running"
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------

setup() {
  require_root_on_ubuntu
  resolve_auto_settings
  install_base_packages
  enable_automatic_updates
  harden_ssh
  configure_firewall
  configure_swap
  install_docker
  configure_docker_daemon
  schedule_docker_cleanup
  create_runner_user

  log "Downloading the runner"
  local archive repository index
  local -a repositories
  archive="$(download_runner)"
  note "verified $(basename "${archive}")"

  IFS=',' read -r -a repositories <<<"${RUNNER_REPOS}"
  for repository in "${repositories[@]}"; do
    for ((index = 1; index <= RUNNER_COUNT; index++)); do
      install_runner "${repository}" "${index}" "${archive}"
    done
  done

  log "Done"
  if [[ -f /var/run/reboot-required ]]; then
    note "The system update needs a reboot: run 'reboot' now. The runners start again by themselves."
  fi
  note "Next, in each repository: Settings > Secrets and variables > Actions > Variables."
  note "GroundCore: CI_RUNNER=groundcore-ci; CI_STACK_RUNNER=groundcore-stack only if a runner has that label."
}

status() {
  systemctl list-units --all --no-pager 'actions.runner.*'
}

# Unregisters every runner on this VM, so GitHub doesn't keep offline runners after the VM is gone.
remove() {
  require_root_on_ubuntu
  local directory url repository token
  for directory in "${RUNNER_HOME}"/*/; do
    [[ -f ${directory}.runner ]] || continue
    url="$(jq -r '.gitHubUrl' "${directory}.runner")"
    repository="${url##*/}"
    log "Removing $(basename "${directory}") from ${repository}"
    (cd "${directory}" && ./svc.sh stop >/dev/null && ./svc.sh uninstall >/dev/null) || true
    token="$(runner_token "${repository}" remove-token)"
    (cd "${directory}" && sudo -u "${RUNNER_USER}" ./config.sh remove --token "${token}")
  done
  log "Done: runners unregistered. The VM can be deleted."
}

case "${1:-setup}" in
  setup) setup ;;
  status) status ;;
  remove) remove ;;
  *) die "unknown command '$1' (use setup, status or remove)" ;;
esac
