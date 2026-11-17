#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners.
#
# What it does (each step is safe to run again; finished steps are skipped):
#   0. On a host set up before, runs "ghrunner audit" first and stops if anything changed that you
#      haven't accepted, so an update never blesses a tampered machine.
#   1. Updates the system, turns on daily security updates, and schedules a weekly full update.
#   2. Hardens SSH (keys only, asks for the port), the firewall (SSH in, rate-limited, nothing else)
#      and a few kernel network settings. Optionally sets a URL that alerts are posted to.
#   3. Installs Docker Engine from Docker's own apt repository. Published ports bind
#      to 127.0.0.1 by default, because Docker's port rules bypass the firewall.
#   4. Creates the "runner" user, adds swap on small machines, and schedules a weekly
#      Docker clean-up.
#   5. Downloads the latest runner release, checks its SHA-256, and registers runners
#      for each repository as systemd services.
#   6. Gives every runner, new or existing, the .env settings that tell jobs where to install tools
#      (.NET, and the tool cache Python and Ruby need), restarting idle runners whose settings changed.
#   7. Installs the "ghrunner" management command (/usr/local/bin/ghrunner), schedules its daily audit,
#      and records what the machine looks like now as the audit's baseline.
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
#   SSH_PORT            [ask]         SSH port; asked each run (Enter keeps the current one, 9452 at first)
#   UPDATE_SCHEDULE     [Sun 11:00 UTC]  when the weekly full update runs (systemd OnCalendar format)
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
SSH_PORT="${SSH_PORT:-}"
SSH_PORT_DEFAULT=9452
SSH_SETTINGS_FILE="/etc/ssh/sshd_config.d/10-runner-host.conf"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-Sun *-*-* 11:00:00 UTC}"
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

# Daily security updates (Ubuntu's unattended-upgrades). The weekly full update is schedule_ghrunner_jobs.
enable_automatic_updates() {
  log "Turning on automatic security updates"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# ---------------------------------------------------------------------------------------------
# SSH and the firewall
# ---------------------------------------------------------------------------------------------

# The ports sshd listens on now, one per line, from its effective settings.
current_ssh_ports() {
  # Ubuntu 24.04 starts sshd on demand (ssh.socket), so its privilege separation directory may not
  # exist yet, and "sshd -t"/"sshd -T" fail without it.
  install -d -m 0755 /run/sshd
  sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un
}

# True for a port SSH may use: 22, or 1024 to 65535.
valid_ssh_port() {
  [[ $1 =~ ^[0-9]+$ ]] && { (($1 == 22)) || (($1 >= 1024 && $1 <= 65535)); }
}

# Prints the SSH port to use: SSH_PORT if set, else asks (Enter keeps the current port, or 9452 on a
# host still on 22). Without a terminal it never changes the port: prints the current one.
choose_ssh_port() {
  local current="$1" default answer
  default="${current}"
  if [[ ${current} == "22" ]]; then default="${SSH_PORT_DEFAULT}"; fi
  if [[ -n ${SSH_PORT} ]]; then
    valid_ssh_port "${SSH_PORT}" || die "SSH_PORT must be 22 or 1024 to 65535, not '${SSH_PORT}'"
    echo "${SSH_PORT}"
    return
  fi
  if ! has_terminal; then
    echo "${current}"
    return
  fi
  while true; do
    printf '    SSH port [%s]: ' "${default}" >/dev/tty
    read -r answer </dev/tty
    answer="${answer:-${default}}"
    if valid_ssh_port "${answer}"; then break; fi
    printf '    Use 22, or a number from 1024 to 65535.\n' >/dev/tty
  done
  echo "${answer}"
}

# True when a user other than root, who may sudo, has an SSH key: then root needn't log in at all.
admin_has_key() {
  local user home
  while IFS=: read -r user _ _ _ _ home _; do
    [[ ${user} != "root" && -s ${home}/.ssh/authorized_keys ]] || continue
    if [[ " $(id -nG "${user}" 2>/dev/null) " == *" sudo "* ]]; then return 0; fi
  done </etc/passwd
  return 1
}

# Prints the sshd settings this host uses, listening on the ports given. <has_key>: "yes" when an SSH key
# exists, so password login can be turned off without locking anyone out.
ssh_settings() {
  local has_key="$1" root_login="$2" port
  shift 2
  echo "# Written by setup-runner.sh. Ubuntu 24.04 takes the listening ports from the Port lines below."
  for port in "$@"; do echo "Port ${port}"; done
  if [[ ${has_key} == "yes" ]]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
  fi
  cat <<EOF
PermitRootLogin ${root_login}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
DenyUsers ${RUNNER_USER}
EOF
}

# Installs sshd settings from stdin when they differ from the current ones, checks them with sshd (and
# puts the old ones back if they fail), then makes ssh.socket listen on the new ports.
apply_ssh_settings() {
  local settings backup=""
  settings="$(cat)"
  if [[ -f ${SSH_SETTINGS_FILE} && "$(<"${SSH_SETTINGS_FILE}")" == "${settings}" ]]; then return; fi
  if [[ -f ${SSH_SETTINGS_FILE} ]]; then backup="$(<"${SSH_SETTINGS_FILE}")"; fi
  printf '%s\n' "${settings}" >"${SSH_SETTINGS_FILE}"
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    if [[ -n ${backup} ]]; then printf '%s\n' "${backup}" >"${SSH_SETTINGS_FILE}"; else rm -f "${SSH_SETTINGS_FILE}"; fi
    die "the new SSH settings failed sshd's check; the old ones were put back and nothing was reloaded"
  fi
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; fi
  systemctl try-reload-or-restart ssh
}

# Lets SSH in on <port>, rate-limited (ufw blocks an address after 6 attempts in 30 seconds). For 22,
# also drops the plain "allow OpenSSH" rule older setups added, which would bypass the limit.
firewall_allow_ssh() {
  ufw limit "$1/tcp" comment "SSH" >/dev/null
  if [[ $1 == "22" ]]; then ufw delete allow OpenSSH >/dev/null 2>&1 || true; fi
}

# Removes the firewall rules for an SSH port that is no longer used.
firewall_remove_ssh() {
  ufw delete limit "$1/tcp" >/dev/null 2>&1 || true
  ufw delete allow "$1/tcp" >/dev/null 2>&1 || true
  if [[ $1 == "22" ]]; then ufw delete allow OpenSSH >/dev/null 2>&1 || true; fi
}

# Asks the person running setup to log in on the new port from a second terminal before the old one closes.
new_port_works() {
  local port="$1" user="${SUDO_USER:-root}" address
  address="$(hostname -I | awk '{ print $1 }')"
  printf '\n    Before the old port closes, open a NEW terminal and log in on the new one:\n' >/dev/tty
  printf '        ssh -p %s %s@%s\n' "${port}" "${user}" "${address}" >/dev/tty
  printf "    (If OVH's network firewall is on for this VM, allow port %s there first.)\n" "${port}" >/dev/tty
  confirm "    Did that log you in?"
}

# SSH keys only, root login off when another admin has a key, the runner user can't log in, and the
# port asked for. Moving the port listens on both ports until you confirm the new one works; only then
# does the old one close. Without a terminal, or if the new port didn't work, both stay open.
harden_ssh_and_firewall() {
  log "Hardening SSH and the firewall"
  local has_key="no" root_login="prohibit-password" port old
  local -a open_ports both
  mapfile -t open_ports < <(current_ssh_ports)
  ((${#open_ports[@]} > 0)) || open_ports=(22)
  if [[ -n "$(find /root/.ssh /home/*/.ssh -name authorized_keys -size +0 2>/dev/null || true)" ]]; then has_key="yes"; fi
  if admin_has_key; then root_login="no"; fi
  port="$(choose_ssh_port "${open_ports[-1]}")"

  for old in "${open_ports[@]}" "${port}"; do firewall_allow_ssh "${old}"; done
  ufw --force enable >/dev/null
  mapfile -t both < <(printf '%s\n' "${open_ports[@]}" "${port}" | sort -un)
  ssh_settings "${has_key}" "${root_login}" "${both[@]}" | apply_ssh_settings

  if [[ ${#open_ports[@]} -gt 1 || ${open_ports[0]} != "${port}" ]]; then
    if has_terminal && new_port_works "${port}"; then
      ssh_settings "${has_key}" "${root_login}" "${port}" | apply_ssh_settings
      for old in "${open_ports[@]}"; do
        if [[ ${old} != "${port}" ]]; then firewall_remove_ssh "${old}"; fi
      done
      note "SSH is on port ${port} only"
    else
      STILL_TO_DO+=("SSH listens on ports ${open_ports[*]} and ${port}: the new port wasn't confirmed, so the old \
one is still open. Check you can log in with 'ssh -p ${port}', then run setup again and answer yes.")
      note "SSH listens on ports ${open_ports[*]} and ${port} until you confirm ${port} works"
    fi
  else
    note "SSH on port ${port}"
  fi
  if [[ ${has_key} == "yes" ]]; then note "keys only; root login: ${root_login}"; else
    note "no SSH key found anywhere, so password login stays on. Add a key, then run this again."
  fi
}

# Ignore ICMP redirects and source-routed packets (both let others reroute this VM's traffic), send no
# redirects, and hide kernel addresses from unprivileged users.
harden_kernel() {
  log "Hardening kernel network settings"
  cat >/etc/sysctl.d/90-runner-hardening.conf <<'EOF'
# Written by setup-runner.sh.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
  sysctl -q -p /etc/sysctl.d/90-runner-hardening.conf
}

# Asks for the URL alerts are posted to (an ntfy.sh topic works: install the ntfy app and subscribe to
# it). Enter keeps the current one; "-" turns alerts off. Kept in a root-only file.
configure_alerts() {
  log "Alerts"
  local current="" answer
  if [[ -r ${ALERT_URL_FILE} ]]; then current="$(<"${ALERT_URL_FILE}")"; fi
  if has_terminal; then
    printf '    Where should alerts go? A URL that takes a plain-text POST, e.g. https://ntfy.sh/<long-random-topic>\n' >/dev/tty
    printf '    [%s] (Enter keeps it, "-" for none): ' "${current:-none}" >/dev/tty
    read -r answer </dev/tty
    case "${answer}" in
      "") ;;
      -) current="" ;;
      https://*) current="${answer}" ;;
      *) note "not an https:// URL; keeping the current setting" ;;
    esac
  fi
  install -d -m 0700 "$(dirname "${ALERT_URL_FILE}")"
  (umask 077 && printf '%s' "${current}" >"${ALERT_URL_FILE}")
  if [[ -n ${current} ]]; then
    send_alert "alerts on" "ghrunner will post here when this runner host needs you."
    note "alerts go to the URL you gave (a test alert was sent)"
  else
    note "no alert URL: problems show at SSH login and in 'ghrunner doctor'"
  fi
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

# Writes a systemd service and timer that run "ghrunner <arguments>" on <schedule> (OnCalendar).
schedule_ghrunner() {
  local name="$1" schedule="$2" arguments="$3" description="$4"
  cat >"/etc/systemd/system/${name}.service" <<EOF
# Written by setup-runner.sh.
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ghrunner ${arguments}
TimeoutStartSec=5h
EOF
  cat >"/etc/systemd/system/${name}.timer" <<EOF
# Written by setup-runner.sh.
[Unit]
Description=${description} (schedule)

[Timer]
OnCalendar=${schedule}
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# The weekly full update (waits until no job is running, never reboots) and the daily audit, plus the
# login message that shows anything they found.
schedule_ghrunner_jobs() {
  log "Scheduling the weekly update and the daily audit"
  schedule_ghrunner ghrunner-update "${UPDATE_SCHEDULE}" "update --scheduled" "ghrunner weekly full update"
  schedule_ghrunner ghrunner-audit "daily" "audit --notify" "ghrunner daily audit"
  systemctl daemon-reload
  systemctl enable --now ghrunner-update.timer ghrunner-audit.timer >/dev/null 2>&1
  cat >/etc/update-motd.d/95-ghrunner <<EOF
#!/bin/sh
# Written by setup-runner.sh: shows what ghrunner found that needs you, at every SSH login.
for file in ${GHRUNNER_STATE_DIR}/attention/*; do
  [ -s "\$file" ] || continue
  printf '\n*** ghrunner: needs your attention (details: sudo ghrunner doctor) ***\n'
  cat ${GHRUNNER_STATE_DIR}/attention/*
  break
done
EOF
  chmod 0755 /etc/update-motd.d/95-ghrunner
  note "weekly update: ${UPDATE_SCHEDULE}; audit: daily"
}

# Before changing anything on a host set up before: stop if the audit finds changes nobody accepted.
# Logins from new addresses are shown but don't stop it (you are logged in to run this).
check_audit_first() {
  [[ -f ${GHRUNNER_STATE_DIR}/audit-baseline ]] || return 0
  log "Checking this machine against its audit baseline"
  if bash "${SCRIPT_DIR}/ghrunner.sh" audit --before-setup; then return; fi
  die "something changed since the last audit that nobody accepted (above). If you made these changes, run \
'sudo ghrunner audit --accept' and run this again. If you didn't, treat this VM as compromised: see \
'If the VM is compromised' in github-runner/README.md."
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
  check_audit_first
  install_base_packages
  enable_automatic_updates
  harden_ssh_and_firewall
  harden_kernel
  configure_alerts
  configure_swap
  install_docker
  configure_docker_daemon
  schedule_docker_cleanup
  create_runner_user
  install_ghrunner
  schedule_ghrunner_jobs

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

  log "Recording this machine as the audit baseline"
  bash "${SCRIPT_DIR}/ghrunner.sh" audit --accept >/dev/null
  note "the daily audit reports anything that changes from here"

  log "Done"
  if [[ -f /var/run/reboot-required ]]; then
    note "The system update needs a reboot: run 'reboot' now. The runners start again by themselves."
  fi
  note "Next, in each repository: Settings > Secrets and variables > Actions > Variables."
  note "GroundCore: CI_RUNNER=groundcore-ci; CI_STACK_RUNNER=groundcore-stack only if a runner has that label."
  note "Check the host any time with: ghrunner doctor"
  if ((${#STILL_TO_DO[@]} > 0)); then
    log "Still to do"
    printf '    - %s\n' "${STILL_TO_DO[@]}"
  fi
}

show_status() {
  bash "${SCRIPT_DIR}/ghrunner.sh" status
}

# Unregisters every runner on this VM, so GitHub doesn't keep offline runners after the VM is gone.
remove_all() {
  require_root_on_ubuntu
  local directory
  for directory in "${RUNNER_HOME}"/*/; do
    [[ -f ${directory}.runner ]] || continue
    log "Removing $(basename "${directory}") from $(runner_repository "${directory%/}")"
    unregister_runner "${directory}"
  done
  log "Done: runners unregistered. The VM can be deleted."
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-setup}" in
    setup) setup ;;
    status) show_status ;;
    remove) remove_all ;;
    *) die "unknown command '$1' (use setup, status or remove)" ;;
  esac
fi
