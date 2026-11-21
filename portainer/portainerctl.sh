#!/usr/bin/env bash
# portainerctl: manages Portainer on this host, whether it is the server (the control plane, component
# portainer-server) or a node (a Docker host with the agent, component portainer-node). Installed as
# /usr/local/bin/portainerctl, a link to /usr/local/lib/hostctl/portainer/portainerctl.sh.
#
# Usage: portainerctl <command> [arguments]   (run "portainerctl help" for the list)
#
# status and help only read and work without root (details need sudo). Every other command needs sudo.
# doctor, audit, update, prune, version and self-update are hostctl's, for the whole host: portainerctl
# passes them on.
#
# Commands that change the firewall check the audit first and accept their own change after, so the
# daily audit stays quiet about them but still reports anything else.
#
# Secrets: none. The admin password is asked for each time and never stored; the agent secret lives in
# a root-only file.

set -Eeuo pipefail

PORTAINER_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOST_DIR="$(dirname "${PORTAINER_DIR}")/host"
if [[ ! -f ${HOST_DIR}/host-lib.sh ]]; then
  printf '\nERROR: %s/host-lib.sh not found. Reinstall with the one-line install.\n' "${HOST_DIR}" >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/../host/host-lib.sh
. "${HOST_DIR}/host-lib.sh"
# shellcheck source=SCRIPTDIR/portainer-lib.sh
. "${PORTAINER_DIR}/portainer-lib.sh"
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR
PROGRAM="portainerctl"

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

# Prints "server" or "node" for this host, or nothing when neither component is installed. Without
# root, from the role file setup leaves in STATE_DIR (the component list is root only).
this_role() {
  if [[ ! -r ${COMPONENTS_FILE} ]]; then
    if [[ -r ${PORTAINER_ROLE_FILE} ]]; then cat "${PORTAINER_ROLE_FILE}"; fi
  elif installed_components | grep -qx portainer-server; then
    echo "server"
  elif installed_components | grep -qx portainer-node; then
    echo "node"
  fi
}

# Stops unless this host has <role> ("server" or "node"), naming the right place to run the command.
require_role() {
  local role
  role="$(this_role)"
  [[ ${role} == "$1" ]] && return
  if [[ -z ${role} ]]; then
    die "Portainer isn't installed here (install: see portainer/README.md)"
  fi
  die "'${COMMAND_LINE%% *}' runs on the Portainer $1; this VM is a $role"
}

# Runs a command (the arguments) that changes the firewall or containers: checks the audit first (stops
# if it found changes nobody accepted, as setup does), then accepts the result.
audited_change() {
  if [[ -f ${STATE_DIR}/audit-baseline ]] && ! bash "${HOST_DIR}/hostctl.sh" audit --before-setup >/dev/null; then
    die "the audit found changes nobody accepted: run 'sudo hostctl audit' first"
  fi
  "$@"
  bash "${HOST_DIR}/hostctl.sh" audit --accept >/dev/null
}

# ---------------------------------------------------------------------------------------------
# Server commands
# ---------------------------------------------------------------------------------------------

# portainerctl add-node <name> <private IP>: adds a node whose agent is installed and running to
# Portainer (asks for the admin password).
add_node() {
  require_root
  require_role server
  [[ $# -eq 2 ]] || die "usage: portainerctl add-node <name> <node's private IP>"
  local name="$1" address="$2" answer response id
  valid_node_name "${name}" || die "'${name}' isn't a usable name (letters, digits, . _ -)"
  valid_ipv4 "${address}" || die "'${address}' isn't an IPv4 address"
  answer="$(agent_answer "${address}")"
  if [[ ${answer} != "up" ]]; then
    die "the agent at ${address}:${PORTAINER_AGENT_PORT} is ${answer}. On the node: sudo portainerctl status \
(is the agent running, and does it let in this server's private address, $(config_get PRIVATE_IP)?)"
  fi
  api_login
  response="$(portainer_api GET /endpoints)" || exit 1
  if parse_endpoints <<<"${response}" | awk -F'\t' -v name="${name}" -v address="${address}:${PORTAINER_AGENT_PORT}" \
    '$2 == name || $3 == address { found = 1 } END { exit !found }'; then
    die "Portainer already has a node named ${name} or at ${address} (portainerctl nodes)"
  fi
  response="$(portainer_api POST /endpoints -F "Name=${name}" -F EndpointCreationType=2 \
    -F "URL=tcp://${address}:${PORTAINER_AGENT_PORT}" -F TLS=true -F TLSSkipVerify=true -F TLSSkipClientVerify=true)" ||
    die "Portainer didn't add the node; if it says the agent refused, the node's agent secret differs (on the node: sudo portainerctl set-secret)"
  id="$(jq -r '.Id' <<<"${response}")"
  note "added ${name} (${address}), environment ${id}"
}

# portainerctl remove-node <name>: removes a node from Portainer (its containers keep running; on the
# node, "sudo portainerctl remove" removes the agent).
remove_node() {
  require_root
  require_role server
  [[ $# -eq 1 ]] || die "usage: portainerctl remove-node <name>"
  local response id
  api_login
  response="$(portainer_api GET /endpoints)" || exit 1
  id="$(parse_endpoints <<<"${response}" | awk -F'\t' -v name="$1" '$2 == name { print $1; exit }')"
  [[ -n ${id} ]] || die "Portainer has no node named $1 (portainerctl nodes)"
  confirm "Remove $1 from Portainer? Its containers keep running." || die "not removed"
  portainer_api DELETE "/endpoints/${id}" >/dev/null || exit 1
  note "removed $1 from Portainer; on the node, 'sudo portainerctl remove' removes the agent"
}

# portainerctl nodes: Portainer's environments and whether each answers (asks for the admin password).
nodes() {
  require_root
  require_role server
  no_arguments "$@"
  local response
  api_login
  response="$(portainer_api GET /endpoints)" || exit 1
  { printf 'ID\tNAME\tADDRESS\tSTATE\n'; parse_endpoints <<<"${response}"; } | print_table
}

# portainerctl allow-ip [address...]: sets who may open the web UI (replacing the list); with no
# addresses, asks (Enter keeps the current list).
allow_ip() {
  require_root
  require_role server
  local address
  for address in "$@"; do valid_source "${address}" || die "'${address}' isn't an IP address"; done
  if (($# > 0)); then
    PORTAINER_HOME_IP="$*" audited_change configure_ui_access
  else
    audited_change configure_ui_access
  fi
}

# portainerctl secret: prints the agent secret, to paste when installing a node.
secret() {
  require_root
  require_role server
  no_arguments "$@"
  config_get AGENT_SECRET "${PORTAINER_ENV}"
}

# portainerctl init-admin: creates the admin user when there is none (restarts Portainer first: it only
# accepts this for 5 minutes after starting).
init_admin_command() {
  require_root
  require_role server
  no_arguments "$@"
  admin_exists && die "Portainer already has its admin user"
  has_terminal || die "no terminal to ask the password on"
  ensure_admin
}

# portainerctl backup [file]: backs up Portainer's data and settings (the server stops for seconds).
backup() {
  require_root
  require_role server
  [[ $# -le 1 ]] || die "usage: portainerctl backup [file]"
  local file
  log "Backing up Portainer"
  file="$(backup_server "${1:-}")"
  note "${file} ($(human_bytes "$(stat -c %s "${file}")"); it holds the agent secret, so keep it private)"
  note "To move the server: copy it to the new VM, then see 'Moving the server' in portainer/README.md"
}

# portainerctl restore <file>: replaces Portainer's data with a backup's (the current data is moved
# aside), with the backup's agent secret and UI addresses.
restore() {
  require_root
  require_role server
  [[ $# -eq 1 ]] || die "usage: portainerctl restore <file>"
  [[ -f $1 ]] || die "no file $1"
  confirm "Replace Portainer's data with $1?" || die "not restored"
  log "Restoring Portainer"
  audited_change restore_and_restart "$1"
}

# Restores <file>, lets in the backup's UI addresses, and starts the server with the restored data.
restore_and_restart() {
  restore_server "$1"
  # shellcheck disable=SC2046 # one rule per address
  wg_set_port_sources "${PORTAINER_UI_PORT}" "Portainer UI" $(config_get ALLOWED_IPS)
  ensure_container server
  wait_for_server || die "Portainer didn't start: sudo docker logs ${PORTAINER_SERVER_CONTAINER}"
  note "Portainer $(server_version)"
}

# ---------------------------------------------------------------------------------------------
# Node commands
# ---------------------------------------------------------------------------------------------

# portainerctl set-server [address]: the server's private address changed (it moved): lets only the new
# one reach the agent. With no address, asks.
set_server() {
  require_root
  require_role node
  [[ $# -le 1 ]] || die "usage: portainerctl set-server [server's private IP]"
  if (($# == 1)); then
    valid_ipv4 "$1" || die "'$1' isn't an IPv4 address"
    [[ $1 == "${WG_SERVER_ADDRESS}" ]] || die "move the WireGuard tunnel first; set-server cannot change its peer address"
    PORTAINER_SERVER_IP="$1" audited_change configure_agent_access
  else
    audited_change configure_agent_access
  fi
}

# portainerctl set-secret: replaces the agent secret (asks for it) and restarts the agent with it.
set_secret() {
  require_root
  require_role node
  no_arguments "$@"
  configure_agent_secret ask
  audited_change ensure_container node
}

# ---------------------------------------------------------------------------------------------
# Both
# ---------------------------------------------------------------------------------------------

# portainerctl status: this host's Portainer at a glance.
status() {
  no_arguments "$@"
  local role name state image_id label readable="yes"
  role="$(this_role)"
  if [[ -z ${role} ]]; then
    if [[ ${EUID} -ne 0 && ! -r ${COMPONENTS_FILE} ]]; then die "run with sudo: sudo portainerctl status"; fi
    die "Portainer isn't installed here"
  fi
  [[ -r ${PORTAINER_CONFIG} ]] || readable="no"
  name="$(container_name "${role}")"
  if docker_reachable; then
    IFS=$'\t' read -r state image_id label <<<"$(container_facts "${name}")"
    state="${state:-missing}"
  else
    state="(sudo to see)"
  fi
  {
    printf 'ITEM\tVALUE\n'
    printf 'Role\t%s\n' "${role}"
    printf 'Container\t%s: %s%s\n' "${name}" "${state}" "${image_id:+ ($(container_image "${role}"), ${image_id:7:12})}"
    if [[ ${readable} == "no" ]]; then
      printf 'Settings\t(sudo to see)\n'
    else
      printf 'Private address\t%s\n' "$(config_get PRIVATE_IP)"
    fi
    if [[ ${role} == "server" ]]; then
      printf 'Version\t%s\n' "$(server_version)"
      printf 'Web UI\thttps://%s:%s (WireGuard only)\n' "$(wg_private_ip)" "${PORTAINER_UI_PORT}"
      if [[ ${readable} == "yes" ]]; then printf 'UI lets in\t%s\n' "$(config_get ALLOWED_IPS)"; fi
      case "$(api_status /users/admin/check)" in
        204) printf 'Admin\t%s\n' "${PORTAINER_ADMIN}" ;;
        404) printf 'Admin\tnone yet: sudo portainerctl init-admin\n' ;;
        *) printf 'Admin\t(server not answering)\n' ;;
      esac
      if [[ -r ${PORTAINER_BACKUP_DIR} ]]; then
        local backup
        backup="$(newest_backup)"
        printf 'Last backup\t%s\n' "${backup:+$(when_was "$(stat -c %Y "${backup}")")}"
      fi
    elif [[ ${readable} == "yes" ]]; then
      printf 'Agent\t%s on %s:%s\n' "$(agent_answer "$(config_get PRIVATE_IP)")" "$(config_get PRIVATE_IP)" "${PORTAINER_AGENT_PORT}"
      printf 'Server\t%s (the only address let in)\n' "$(config_get SERVER_IP)"
    fi
  } | print_table
}

# portainerctl upgrade: moves the container to the newest image of its tag now (the weekly update does
# this too). The server is backed up first.
upgrade() {
  require_root
  no_arguments "$@"
  case "$(this_role)" in
    server) pserver_upgrade ;;
    node) pnode_upgrade ;;
    *) die "Portainer isn't installed here" ;;
  esac
}

# Removes this host's Portainer: the container and its firewall rules; keeps the data and settings.
remove_role() {
  local role="$1"
  if [[ ${role} == "server" && -d ${PORTAINER_DATA} ]]; then note "backup: $(backup_server "")"; fi
  docker rm -f "$(container_name "${role}")" >/dev/null 2>&1 || true
  if [[ ${role} == "server" ]]; then
    wg_set_port_sources "${PORTAINER_UI_PORT}" "Portainer UI"
  else
    wg_set_port_sources "${PORTAINER_AGENT_PORT}" "Portainer agent"
  fi
  unregister_components "portainer-${role}"
  rm -f /usr/local/bin/portainerctl "${PORTAINER_ROLE_FILE}"
  # This script runs from that folder; bash keeps reading the open file.
  rm -rf "${TOOLS_DIR:?}/portainer"
}

# portainerctl remove: removes Portainer from this host (keeps its data, settings and backups).
remove() {
  require_root
  no_arguments "$@"
  local role
  role="$(this_role)"
  [[ -n ${role} ]] || die "Portainer isn't installed here"
  if [[ ${role} == "node" ]]; then
    note "Remove it from Portainer first, on the server: sudo portainerctl remove-node <name>"
  fi
  confirm "Remove the Portainer ${role} from this VM?" || die "not removed"
  log "Removing the Portainer ${role}"
  audited_change remove_role "${role}"
  note "kept: ${CONFIG_DIR}/portainer.*$([[ ${role} == server ]] && echo ", ${PORTAINER_DATA} and ${PORTAINER_BACKUP_DIR}")"
  note "WireGuard remains configured for reuse; revoke peers with networkctl as needed."
}


# ---------------------------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------------------------

# portainerctl help: the command list.
usage() {
  printf 'portainerctl (hostctl %s)\n\n' "${TOOLS_VERSION}"
  # "|| true": a reader that stops early (portainerctl help | head) is not an error.
  cat <<'EOF' || true
Usage: portainerctl <command> [arguments]

On the server (control plane)    What it does                                                   Needs sudo
  add-node <name> <private IP>   add a node whose agent is running (asks the admin password)    yes
  remove-node <name>             remove a node from Portainer (its containers keep running)     yes
  nodes                          the nodes and whether each is up (asks the admin password)     yes
  allow-ip [address...]          set who may open the web UI (e.g. your new home IP)            yes
  secret                         print the agent secret, to paste when installing a node        yes
  backup [file]                  back up Portainer's data and settings                          yes
  restore <file>                 replace Portainer's data with a backup's                       yes
  init-admin                     create the admin user if setup couldn't                        yes

On a node                        What it does                                                   Needs sudo
  set-server [private IP]        the server moved: let only its new address reach the agent     yes
  set-secret                     replace the agent secret and restart the agent                 yes

On either                        What it does                                                   Needs sudo
  status                         container, version, addresses, who is let in                   no
  upgrade                        newest image of the tag now (the weekly update does this too)  yes
  remove                         remove Portainer from this VM (keeps data and backups)         yes
  help                           this text                                                      no

For the whole host (these run hostctl): doctor [--fix], audit [--accept], update, prune, version,
self-update.
EOF
}

# Runs the command named on the command line; the host-wide ones go to hostctl.
main() {
  COMMAND_LINE="$*"
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "${command}" in
    add-node) add_node "$@" ;;
    remove-node) remove_node "$@" ;;
    nodes) nodes "$@" ;;
    allow-ip) allow_ip "$@" ;;
    secret) secret "$@" ;;
    backup) backup "$@" ;;
    restore) restore "$@" ;;
    init-admin) init_admin_command "$@" ;;
    set-server) set_server "$@" ;;
    set-secret) set_secret "$@" ;;
    status) status "$@" ;;
    upgrade) upgrade "$@" ;;
    remove) remove "$@" ;;
    doctor | audit | update | prune | version | --version | self-update) exec bash "${HOST_DIR}/hostctl.sh" "${command}" "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2 && die "unknown command '${command}'" ;;
  esac
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
