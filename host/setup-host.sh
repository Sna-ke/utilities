#!/usr/bin/env bash
# Sets up an Ubuntu 24.04 VM as a hardened host, then installs the components asked for.
#
#   sudo bash host/setup-host.sh <component>...     e.g. github-runner
#
# Normally host/install.sh runs this (curl ... | sudo bash -s -- <component>), and "hostctl self-update"
# and "hostctl doctor --fix" run it again. Every step is safe to repeat; a finished step is skipped.
#
# Host steps:
#   0. On a host set up before, runs "hostctl audit" first and stops if anything changed that you
#      haven't accepted, so an update never blesses a tampered machine.
#   1. Updates the system, turns on daily security updates, and schedules a weekly full update.
#   2. Hardens SSH (keys only, asks for the port), the firewall (SSH in, rate-limited, nothing else)
#      and kernel network settings. Asks for Pushover alerts.
#   3. Adds swap on small machines, installs Docker (published ports on 127.0.0.1, live-restore so a
#      Docker upgrade doesn't stop containers) and a weekly clean-up.
#   4. Installs hostctl, schedules its daily audit and the weekly update.
# Then each component's setup, and finally the audit baseline.
#
# Settings (environment variables, all optional):
#   SSH_PORT            [ask]            SSH port; asked each run (Enter keeps the current one, 9452 at first)
#   SWAP_SIZE_GB        [auto]           swap to add; auto = 4 below 10 GB of RAM, else none
#   UPDATE_SCHEDULE     [Sun 11:00 UTC]  when the weekly full update runs (systemd OnCalendar format)
# Components have their own (see their README).

set -Eeuo pipefail

SWAP_SIZE_GB="${SWAP_SIZE_GB:-auto}"
SSH_PORT="${SSH_PORT:-}"
SSH_PORT_DEFAULT=9452
SSH_SETTINGS_FILE="/etc/ssh/sshd_config.d/10-hostctl.conf"
# Where 1.x wrote the SSH settings; replaced by SSH_SETTINGS_FILE.
OLD_SSH_SETTINGS_FILE="/etc/ssh/sshd_config.d/10-runner-host.conf"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-Sun *-*-* 11:00:00 UTC}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# The folder holding host/ and the component folders: a checkout, a download, or TOOLS_DIR.
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=SCRIPTDIR/host-lib.sh
. "${SCRIPT_DIR}/host-lib.sh"
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR

# ---------------------------------------------------------------------------------------------
# Checks and machine facts
# ---------------------------------------------------------------------------------------------

# Stops unless running as root on Ubuntu 24.04.
require_root_on_ubuntu() {
  [[ ${EUID} -eq 0 ]] || die "run with sudo"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID} == "ubuntu" ]] || die "this script supports Ubuntu only (found ${ID})"
  [[ ${VERSION_ID} == "24.04" ]] || note "tested on Ubuntu 24.04; this is ${VERSION_ID}"
}

# Resolves the "auto" swap size from the machine's memory.
resolve_swap_size() {
  if [[ ${SWAP_SIZE_GB} == "auto" ]]; then
    if (("$(memory_gb)" < 10)); then SWAP_SIZE_GB=4; else SWAP_SIZE_GB=0; fi
  fi
  note "memory $(memory_gb) GB, $(cpu_count) cores; swap ${SWAP_SIZE_GB} GB"
}

# ---------------------------------------------------------------------------------------------
# Moving a 1.x install (everything under "ghrunner") to hostctl's layout
# ---------------------------------------------------------------------------------------------

# Copies 1.x's state and settings to hostctl's folders, so the audit check that comes next compares
# against the old baseline, and alerts keep working. Registers the GitHub runner component it served.
# The old timers, login message and files go once the new ones exist (remove_old_layout).
migrate_old_state() {
  [[ -d /var/lib/ghrunner || -d /etc/ghrunner ]] || return 0
  log "Moving ghrunner's state and settings to hostctl (the 2.0.0 layout)"
  install -d -m 0755 "${STATE_DIR}"
  install -d -m 0700 "${CONFIG_DIR}"
  if [[ -d /var/lib/ghrunner ]]; then cp -a /var/lib/ghrunner/. "${STATE_DIR}/"; fi
  if [[ -f /etc/ghrunner/pushover && ! -f ${PUSHOVER_FILE} ]]; then cp -a /etc/ghrunner/pushover "${PUSHOVER_FILE}"; fi
  register_components github-runner
  note "state copied; the old files go once the new layout is in place"
}

# Removes what 1.x left: its timers, login message, settings, state and installed files.
remove_old_layout() {
  local unit
  [[ -d /usr/local/lib/ghrunner || -d /var/lib/ghrunner || -e /etc/systemd/system/ghrunner-audit.timer ]] || return 0
  for unit in ghrunner-update ghrunner-audit; do
    systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.service" "/etc/systemd/system/${unit}.timer"
  done
  systemctl daemon-reload
  rm -f /etc/update-motd.d/95-ghrunner
  rm -rf /usr/local/lib/ghrunner /var/lib/ghrunner /etc/ghrunner
  note "removed ghrunner's 1.x files, timers and login message"
}

# ---------------------------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------------------------

install_base_packages() {
  log "Updating the system and installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get full-upgrade -yq
  apt-get install -yq ca-certificates curl git jq unzip ufw unattended-upgrades libicu-dev
}

# Daily security updates (Ubuntu's unattended-upgrades). The weekly full update is schedule_tool_jobs.
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
  echo "# Written by setup-host.sh. Ubuntu 24.04 takes the listening ports from the Port lines below."
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
EOF
  # Service accounts the components create (e.g. runner) must never log in over SSH.
  local deny
  deny="$(call_hooks ssh_deny_users | paste -sd' ' -)"
  if [[ -n ${deny} ]]; then echo "DenyUsers ${deny}"; fi
}

# Installs sshd settings from stdin when they differ from the current ones, checks them with sshd (and
# puts the old ones back if they fail), then makes ssh.socket listen on the new ports. Removes 1.x's
# settings file, whose Port lines would otherwise still count.
apply_ssh_settings() {
  local settings backup="" old_backup=""
  settings="$(cat)"
  if [[ -f ${SSH_SETTINGS_FILE} && ! -f ${OLD_SSH_SETTINGS_FILE} && "$(<"${SSH_SETTINGS_FILE}")" == "${settings}" ]]; then return; fi
  if [[ -f ${SSH_SETTINGS_FILE} ]]; then backup="$(<"${SSH_SETTINGS_FILE}")"; fi
  if [[ -f ${OLD_SSH_SETTINGS_FILE} ]]; then old_backup="$(<"${OLD_SSH_SETTINGS_FILE}")"; fi
  printf '%s\n' "${settings}" >"${SSH_SETTINGS_FILE}"
  rm -f "${OLD_SSH_SETTINGS_FILE}"
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    if [[ -n ${backup} ]]; then printf '%s\n' "${backup}" >"${SSH_SETTINGS_FILE}"; else rm -f "${SSH_SETTINGS_FILE}"; fi
    if [[ -n ${old_backup} ]]; then printf '%s\n' "${old_backup}" >"${OLD_SSH_SETTINGS_FILE}"; fi
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

# SSH keys only, root login off when another admin has a key, service accounts can't log in, and the
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

# Applies KERNEL_SETTINGS (host-lib.sh says what each does) now and at every boot.
harden_kernel() {
  log "Hardening kernel network settings"
  rm -f /etc/sysctl.d/90-runner-hardening.conf # 1.x's name for this file
  { echo "# Written by setup-host.sh."; printf '%s\n' "${KERNEL_SETTINGS[@]}"; } >/etc/sysctl.d/90-hostctl-hardening.conf
  # -e: skip settings this kernel doesn't have (the IPv6 ones when IPv6 is off) instead of failing.
  sysctl -q -e -p /etc/sysctl.d/90-hostctl-hardening.conf
}

# Asks for Pushover's user key and application token. Prints "keep", "off", or "<user key>\t<token>".
ask_pushover() {
  local current="$1" shown="none" user token
  if [[ -n ${current} ]]; then shown="set, ending ${current: -4}"; fi
  printf '    Alerts go to Pushover. Your user key is on https://pushover.net once you log in. For the token,\n' >/dev/tty
  printf '    create an application at https://pushover.net/apps/build (any name, e.g. "Runner host").\n' >/dev/tty
  printf '    Pushover user key [%s] (Enter keeps it, "-" for no alerts): ' "${shown}" >/dev/tty
  read -r user </dev/tty
  case "${user}" in
    "") echo "keep" && return ;;
    -) echo "off" && return ;;
  esac
  if ! valid_pushover_key "${user}"; then
    printf '    That is not a Pushover user key (30 letters and digits); keeping the current setting.\n' >/dev/tty
    echo "keep"
    return
  fi
  printf '    Pushover application token (hidden): ' >/dev/tty
  read -r -s token </dev/tty
  printf '\n' >/dev/tty
  if ! valid_pushover_key "${token}"; then
    printf '    That is not a Pushover token (30 letters and digits); keeping the current setting.\n' >/dev/tty
    echo "keep"
    return
  fi
  printf '%s\t%s\n' "${user}" "${token}"
}

# Saves the Pushover user key and token in a root-only file.
save_pushover() {
  install -d -m 0700 "$(dirname "${PUSHOVER_FILE}")"
  (umask 077 && printf 'PUSHOVER_USER=%s\nPUSHOVER_TOKEN=%s\n' "$1" "$2" >"${PUSHOVER_FILE}")
}

# Sets up alerts to Pushover: asks for the user key and application token (Enter keeps the current
# ones), checks them with Pushover before saving, and sends a test alert.
configure_alerts() {
  log "Alerts (Pushover)"
  local user="" token="" answer="keep"
  IFS=$'\t' read -r user token <<<"$(pushover_settings)"
  if has_terminal; then answer="$(ask_pushover "${user}")"; fi
  case "${answer}" in
    keep) ;;
    off) rm -f "${PUSHOVER_FILE}" ;;
    *)
      IFS=$'\t' read -r user token <<<"${answer}"
      if pushover_valid "${user}" "${token}"; then
        save_pushover "${user}" "${token}"
        send_alert "alerts on" "hostctl will alert you here when this host needs you."
      else
        STILL_TO_DO+=("Pushover didn't accept that user key and application token, or the account has no active \
device, so alerts were left as they were. Check both on pushover.net, then run setup again.")
      fi
      ;;
  esac
  if [[ -n "$(pushover_settings)" ]]; then
    note "alerts go to Pushover"
  else
    note "no alerts: problems show at SSH login and in 'hostctl doctor'"
  fi
}

# ---------------------------------------------------------------------------------------------
# Swap and Docker
# ---------------------------------------------------------------------------------------------

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
  rm -f /etc/sysctl.d/90-runner-swap.conf # 1.x's name for this file
  echo 'vm.swappiness=10' >/etc/sysctl.d/90-hostctl-swap.conf
  sysctl -q -p /etc/sysctl.d/90-hostctl-swap.conf
}

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

# Published ports bind to 127.0.0.1 unless a container says otherwise: Docker's iptables rules bypass
# ufw, so nothing may reach the internet by accident. live-restore keeps containers running while the
# Docker daemon restarts (the weekly update). Container logs are capped.
configure_docker_daemon() {
  log "Configuring the Docker daemon"
  local settings='{"ip":"127.0.0.1","live-restore":true,"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'
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
  note "published ports default to 127.0.0.1; containers survive Docker restarts; logs capped at 30 MB each"
}

# Prints "full" when a component wants volumes pruned too (CI), else "images" (never volumes: on a
# production host a stopped stack's database lives in one).
prune_level() {
  if call_hooks prune_level | grep -qx full; then echo "full"; else echo "images"; fi
}

# The weekly Docker clean-up (cron), at the level the components need. "hostctl prune" runs it too; its
# journal line (tag docker-prune) is how stats know when it last ran.
schedule_docker_cleanup() {
  local level
  level="$(prune_level)"
  log "Scheduling a weekly Docker clean-up (${level})"
  {
    echo "#!/bin/sh"
    echo "# Written by setup-host.sh (level: ${level}). \"hostctl prune\" runs this file too."
    echo "set -e"
    if [[ ${level} == "full" ]]; then
      echo "# CI leaves images, build cache and volumes behind."
      echo 'docker system prune -af --filter "until=168h" >/dev/null'
      echo "docker volume prune -af >/dev/null"
    else
      echo "# Production: old images and build cache only. Never volumes or stopped containers: they hold data."
      echo 'docker image prune -af --filter "until=168h" >/dev/null'
      echo 'docker builder prune -af --filter "until=168h" >/dev/null'
    fi
    echo 'logger -t docker-prune "Docker clean-up finished"'
  } >"${PRUNE_SCRIPT}"
  chmod +x "${PRUNE_SCRIPT}"
}

# ---------------------------------------------------------------------------------------------
# hostctl itself
# ---------------------------------------------------------------------------------------------

# Installs the tools: copies the scripts of host/ and each component's folder into TOOLS_DIR (keeping the
# repository's layout), links the commands into /usr/local/bin, and records the commit they came from
# (TOOLS_COMMIT, from the installer and self-update; "unknown" for a download by hand). Copies, so
# deleting the download folder breaks nothing; running this again just replaces them.
install_tools() {
  local folder file
  local -a components folders
  log "Installing hostctl ${TOOLS_VERSION}"
  mapfile -t components < <(installed_components)
  mapfile -t folders < <(tool_folders "${components[@]}")
  if [[ ${ROOT_DIR} != "${TOOLS_DIR}" ]]; then
    for folder in "${folders[@]}"; do
      install -d -m 0755 "${TOOLS_DIR}/${folder}"
      for file in "${ROOT_DIR}/${folder}"/*.sh; do install -m 0755 "${file}" "${TOOLS_DIR}/${folder}/"; done
    done
  fi
  ln -sfn "${TOOLS_DIR}/host/hostctl.sh" /usr/local/bin/hostctl
  call_hooks install_commands
  # Re-running the installed copy keeps the recorded commit: the files are the same ones.
  if [[ -n ${TOOLS_COMMIT:-} || ${ROOT_DIR} != "${TOOLS_DIR}" || ! -f ${TOOLS_DIR}/VERSION ]]; then
    echo "${TOOLS_COMMIT:-unknown}" >"${TOOLS_DIR}/VERSION"
  fi
  note "hostctl ${TOOLS_VERSION} (commit $(cut -c1-7 "${TOOLS_DIR}/VERSION")); components: ${components[*]}"
}

# Writes a systemd service and timer that run "hostctl <arguments>" on <schedule> (OnCalendar).
schedule_tool() {
  local name="$1" schedule="$2" arguments="$3" description="$4"
  cat >"/etc/systemd/system/${name}.service" <<EOF
# Written by setup-host.sh.
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hostctl ${arguments}
TimeoutStartSec=5h
EOF
  cat >"/etc/systemd/system/${name}.timer" <<EOF
# Written by setup-host.sh.
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

# The weekly full update (components pause their work first; it never reboots) and the daily audit,
# plus the login message that shows anything they found.
schedule_tool_jobs() {
  log "Scheduling the weekly update and the daily audit"
  schedule_tool hostctl-update "${UPDATE_SCHEDULE}" "update --scheduled" "hostctl weekly full update"
  schedule_tool hostctl-audit "daily" "audit --notify" "hostctl daily audit"
  systemctl daemon-reload
  systemctl enable --now hostctl-update.timer hostctl-audit.timer >/dev/null 2>&1
  cat >/etc/update-motd.d/95-hostctl <<EOF
#!/bin/sh
# Written by setup-host.sh: shows what hostctl found that needs you, at every SSH login.
for file in ${STATE_DIR}/attention/*; do
  [ -s "\$file" ] || continue
  printf '\n*** hostctl: needs your attention (details: sudo hostctl doctor) ***\n'
  cat ${STATE_DIR}/attention/*
  break
done
EOF
  chmod 0755 /etc/update-motd.d/95-hostctl
  note "weekly update: ${UPDATE_SCHEDULE}; audit: daily"
}

# Before changing anything on a host set up before: stop if the audit finds changes nobody accepted.
# Logins from new addresses are shown but don't stop it (you are logged in to run this).
check_audit_first() {
  [[ -f ${STATE_DIR}/audit-baseline ]] || return 0
  log "Checking this machine against its audit baseline"
  if bash "${SCRIPT_DIR}/hostctl.sh" audit --before-setup; then return; fi
  die "something changed since the last audit that nobody accepted (above). If you made these changes, run \
'sudo hostctl audit --accept' and run this again. If you didn't, treat this VM as compromised: see \
'If the VM is compromised' in host/README.md."
}

# ---------------------------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------------------------

# Sets up the host and the components given (or, with none given, the ones already installed).
setup() {
  log "setup-host.sh ${TOOLS_VERSION}"
  require_root_on_ubuntu
  migrate_old_state
  if (($# > 0)); then register_components "$@"; fi
  [[ -n "$(installed_components)" ]] || die "say which component to install, e.g.: sudo bash host/setup-host.sh github-runner"
  load_components "${ROOT_DIR}"
  resolve_swap_size
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
  install_tools
  schedule_tool_jobs
  remove_old_layout
  call_hooks setup

  log "Recording this machine as the audit baseline"
  bash "${SCRIPT_DIR}/hostctl.sh" audit --accept >/dev/null
  note "the daily audit reports anything that changes from here"

  log "Done"
  if [[ -f /var/run/reboot-required ]]; then
    note "The system update needs a reboot: run 'sudo reboot' now. Services start again by themselves."
  fi
  call_hooks notes
  note "Check the host any time with: hostctl doctor"
  if ((${#STILL_TO_DO[@]} > 0)); then
    log "Still to do"
    printf '    - %s\n' "${STILL_TO_DO[@]}"
  fi
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  setup "$@"
fi
