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
#   6. Gives every runner, new or existing, the .env settings that tell jobs where to install tools
#      (.NET, and the tool cache Python and Ruby need), restarting idle runners whose settings changed.
#   7. Installs the "ghrunner" management command (/usr/local/bin/ghrunner).
#
# Needs runner-lib.sh and ghrunner.sh in the same folder as this script.
#
# Usage (as root, on the VM):
#   setup-runner.sh            set up, or bring runners in line with this machine's size
#   setup-runner.sh status     list the runners (same as "ghrunner status")
#   setup-runner.sh remove     unregister every runner on this VM (before deleting it)
#
# Settings come from environment variables (defaults in brackets):
#   GITHUB_OWNER        [Sna-ke]      account that owns the repositories
#   RUNNER_REPOS        [GroundCore]  comma-separated repositories to serve
#   RUNNER_COUNT        [auto]        runners per repository; auto = one per 5 GB of RAM and 3 cores,
#                                     at least 1 (OVH VPS-1 and VPS-2: 1; VPS-3 and VPS-4: 2)
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

RUNNER_REPOS="${RUNNER_REPOS:-GroundCore}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-auto}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [[ ! -f ${SCRIPT_DIR}/runner-lib.sh ]]; then
  printf '\nERROR: runner-lib.sh is missing from %s. Download it and ghrunner.sh next to this script.\n' \
    "${SCRIPT_DIR}" >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/runner-lib.sh
. "${SCRIPT_DIR}/runner-lib.sh"
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

# Resolves the "auto" settings from the machine's memory, so one script fits VPS-1 to VPS-3.
resolve_auto_settings() {
  local memory
  memory="$(memory_gb)"
  resolve_runner_settings
  if [[ ${SWAP_SIZE_GB} == "auto" ]]; then
    if ((memory < 10)); then SWAP_SIZE_GB=4; else SWAP_SIZE_GB=0; fi
  fi
  note "memory ${memory} GB, $(cpu_count) cores: ${RUNNER_COUNT} runner(s) per repository, stack label ${STACK_LABEL}, swap ${SWAP_SIZE_GB} GB"
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
  cat >"${PRUNE_SCRIPT}" <<'EOF'
#!/bin/sh
# Written by setup-runner.sh: CI leaves images, build cache and volumes behind.
# "ghrunner prune" runs this file too. The journal line (tag docker-prune) is how "ghrunner stats"
# knows when it last ran.
set -e
docker system prune -af --filter "until=168h" >/dev/null
docker volume prune -af >/dev/null
logger -t docker-prune "Docker clean-up finished"
EOF
  chmod +x "${PRUNE_SCRIPT}"
}

# Installs the management command, plus copies of all three files in /usr/local/lib/ghrunner, so
# "ghrunner self-update" can tell which version is installed. Records the commit they came from (given
# by self-update as GHRUNNER_COMMIT; "unknown" for a download by hand). Copies, not links, so deleting
# the download folder doesn't break it; running this again just replaces them.
install_ghrunner() {
  local file
  log "Installing the ghrunner command"
  install -d -m 0755 "${GHRUNNER_LIB_DIR}"
  if [[ ${SCRIPT_DIR} != "${GHRUNNER_LIB_DIR}" ]]; then
    for file in "${GHRUNNER_FILES[@]}"; do
      install -m 0644 "${SCRIPT_DIR}/${file}" "${GHRUNNER_LIB_DIR}/${file}"
    done
  fi
  install -m 0755 "${SCRIPT_DIR}/ghrunner.sh" /usr/local/bin/ghrunner
  # Re-running the installed copy keeps the recorded commit: the files are the same ones.
  if [[ -n ${GHRUNNER_COMMIT:-} || ${SCRIPT_DIR} != "${GHRUNNER_LIB_DIR}" || ! -f ${GHRUNNER_LIB_DIR}/VERSION ]]; then
    echo "${GHRUNNER_COMMIT:-unknown}" >"${GHRUNNER_LIB_DIR}/VERSION"
  fi
  note "ghrunner ${GHRUNNER_VERSION} (commit $(cut -c1-7 "${GHRUNNER_LIB_DIR}/VERSION")); run 'ghrunner help' for its commands"
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
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------

setup() {
  log "setup-runner.sh ${GHRUNNER_VERSION}"
  require_root_on_ubuntu
  [[ -f ${SCRIPT_DIR}/ghrunner.sh ]] || die "ghrunner.sh is missing from ${SCRIPT_DIR}; download it next to this script"
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
  install_ghrunner

  # RUNNER_REPOS plus any repository given runners later with ghrunner, so a re-run after a VM resize
  # adjusts them all (same code as "ghrunner resize").
  local repository full
  local -a repositories requested=()
  IFS=',' read -r -a repositories <<<"${RUNNER_REPOS}"
  for repository in "${repositories[@]}"; do
    full="$(full_repository_name "${repository}")" || exit 1
    requested+=("${full}")
  done
  mapfile -t repositories < <({ printf '%s\n' "${requested[@]}"; repositories_with_runners; } | sort -fu)
  for full in "${repositories[@]}"; do
    resize_repository "${full}"
  done

  log "Runner settings (.env)"
  configure_runners
  note "all runners up to date"

  log "Done"
  if [[ -f /var/run/reboot-required ]]; then
    note "The system update needs a reboot: run 'reboot' now. The runners start again by themselves."
  fi
  note "Next, in each repository: Settings > Secrets and variables > Actions > Variables."
  note "GroundCore: CI_RUNNER=groundcore-ci; CI_STACK_RUNNER=groundcore-stack only if a runner has that label."
  note "Check the host any time with: ghrunner doctor"
  if ((${#RESIZE_TODO[@]} > 0)); then
    log "Still to do"
    printf '    - %s\n' "${RESIZE_TODO[@]}"
  fi
}

status() {
  bash "${SCRIPT_DIR}/ghrunner.sh" status
}

# Unregisters every runner on this VM, so GitHub doesn't keep offline runners after the VM is gone.
remove() {
  require_root_on_ubuntu
  local directory
  for directory in "${RUNNER_HOME}"/*/; do
    [[ -f ${directory}.runner ]] || continue
    log "Removing $(basename "${directory}") from $(runner_repository "${directory%/}")"
    unregister_runner "${directory}"
  done
  log "Done: runners unregistered. The VM can be deleted."
}

case "${1:-setup}" in
  setup) setup ;;
  status) status ;;
  remove) remove ;;
  *) die "unknown command '$1' (use setup, status or remove)" ;;
esac
