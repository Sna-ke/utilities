# shellcheck shell=bash
# The Portainer components' shared code: settings, the private network, the firewall rules for Portainer's
# ports, the server and agent containers, backups, Portainer's API, and the hostctl hooks for both
# components. Sourced after host/host-lib.sh by setup-host.sh, hostctl.sh and portainerctl.sh.
#
# Two components, one library:
#   portainer-server (hook prefix pserver)  the control plane: Portainer's web UI and API
#   portainer-node   (hook prefix pnode)    a Docker host Portainer manages through its agent
#
# Network. Both containers use the host's network, so ufw decides who reaches them (ports Docker
# publishes bypass ufw). The UI (9443, HTTPS only) lets in the addresses you allow (your home IP); plain
# HTTP and the Edge tunnel are off the network. Each agent (9001) listens only on its private (vRack)
# address and lets in only the server's private address. The server doesn't mount the Docker socket:
# it manages the nodes, not the machine it runs on.
#
# Secrets: none in the repository. The agent secret (the same on the server and every node) and the
# one-time setup token live in a root-only env file, passed to the containers with --env-file so they
# never appear on a command line. The admin password is asked for each time and never stored.

# Settings (root only): ALLOWED_IPS (server), SERVER_IP (node).
# WireGuard is a reusable network module and owns private addressing and key material.
# shellcheck disable=SC1091 # component is downloaded with network/ during setup
# shellcheck source=../network/wireguard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../network/wireguard-lib.sh"
PORTAINER_CONFIG="${CONFIG_DIR}/portainer.conf"
# Secrets passed to the container (root only): AGENT_SECRET, and on the server PORTAINER_SETUP_TOKEN.
PORTAINER_ENV="${CONFIG_DIR}/portainer.env"
# The server's data (database, certificates), a folder rather than a volume so no prune can delete it.
PORTAINER_DATA="${PORTAINER_DATA:-/var/lib/portainer}"
PORTAINER_BACKUP_DIR="${PORTAINER_BACKUP_DIR:-/var/backups/portainer}"
# Backups kept (setup and upgrades back up before replacing the server; "portainerctl backup" too).
PORTAINER_BACKUPS_KEPT=8
# "lts": the long-term-support line. Server and agents follow the same tag, so they stay in step.
PORTAINER_SERVER_IMAGE="${PORTAINER_SERVER_IMAGE:-portainer/portainer-ce:lts}"
PORTAINER_AGENT_IMAGE="${PORTAINER_AGENT_IMAGE:-portainer/agent:lts}"
PORTAINER_SERVER_CONTAINER="portainer"
PORTAINER_AGENT_CONTAINER="portainer_agent"
PORTAINER_UI_PORT=9443
PORTAINER_AGENT_PORT=9001
# Portainer's plain-HTTP UI and Edge tunnel ports: neither may listen on the network.
PORTAINER_CLOSED_PORTS=(9000 8000)
PORTAINER_API="https://127.0.0.1:${PORTAINER_UI_PORT}/api"
PORTAINER_ADMIN="${PORTAINER_ADMIN:-admin}"
# Portainer's own minimum (its default password rule) and ours.
PORTAINER_PASSWORD_MIN=12
# Portainer management traffic must never be reachable from a public NIC.
WG_ADMIN_ADDRESS="${WG_ADMIN_ADDRESS:-10.70.0.10}"
# Which one this VM is ("server" or "node"), readable by everyone so status works without sudo.
PORTAINER_ROLE_FILE="${STATE_DIR}/portainer-role"
PORTAINER_JWT=""
PORTAINER_SETUP_TOKEN_HEADER=""

# ---------------------------------------------------------------------------------------------
# Settings files (KEY=value lines, read without running them)
# ---------------------------------------------------------------------------------------------

# Prints the value of <key> in <file> (default: the settings file), or nothing.
config_get() {
  local file="${2:-${PORTAINER_CONFIG}}"
  [[ -r ${file} ]] || return 0
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "${file}"
}

# Sets <key> to <value> in <file> (default: the settings file), keeping the other lines. Root only.
config_set() {
  local key="$1" value="$2" file="${3:-${PORTAINER_CONFIG}}"
  [[ ${value} != *$'\n'* ]] || die "a setting can't contain a line break"
  install -d -m 0700 "$(dirname "${file}")"
  (
    umask 077
    { if [[ -f ${file} ]]; then awk -v key="$1" 'index($0, key "=") != 1' "${file}"; fi
      printf '%s=%s\n' "${key}" "${value}"; } >"${file}.new"
  )
  mv "${file}.new" "${file}"
}

# ---------------------------------------------------------------------------------------------
# Checking what people type
# ---------------------------------------------------------------------------------------------

# True for a dotted IPv4 address (no prefix).
valid_ipv4() {
  local part
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for part in "${BASH_REMATCH[@]:1}"; do ((10#${part} <= 255)) || return 1; done
}

# True for an address ufw can match a source against: IPv4 or IPv6, optionally with a /prefix.
valid_source() {
  local address="${1%/*}" prefix=""
  [[ $1 == */* ]] && prefix="${1##*/}"
  if valid_ipv4 "${address}"; then
    [[ -z ${prefix} || (${prefix} =~ ^[0-9]{1,2}$ && $((10#${prefix})) -le 32) ]]
  else
    [[ ${address} =~ ^[0-9A-Fa-f:]+$ && ${address} == *:*:* ]] || return 1
    [[ -z ${prefix} || (${prefix} =~ ^[0-9]{1,3}$ && $((10#${prefix})) -le 128) ]]
  fi
}

# True for a private address with its prefix, e.g. 10.0.0.1/24 (prefix 8 to 30).
valid_private_cidr() {
  [[ $1 == */* ]] && valid_ipv4 "${1%/*}" && [[ ${1##*/} =~ ^[0-9]{1,2}$ ]] &&
    ((10#${1##*/} >= 8 && 10#${1##*/} <= 30))
}

# True for a name Portainer shows a node as: letters, digits, dot, dash, underscore; up to 63.
valid_node_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]
}

# True for an agent secret as the server makes them (setup checks pasted ones): 32 to 128 characters
# that are safe in an env file.
valid_secret() {
  [[ $1 =~ ^[A-Za-z0-9._~+/=-]{32,128}$ ]]
}

# Makes a random secret (64 hex characters).
new_secret() {
  openssl rand -hex 32
}

# ---------------------------------------------------------------------------------------------
# Asking
# ---------------------------------------------------------------------------------------------

# Asks on the terminal until the answer passes <check> (a function); Enter takes <default> when there is
# one. Prints the answer. Without a terminal, prints <default> (fails if there is none).
ask_value() {
  local prompt="$1" default="$2" check="$3" answer
  if ! has_terminal; then
    [[ -n ${default} ]] || return 1
    echo "${default}"
    return
  fi
  while true; do
    printf '    %s%s: ' "${prompt}" "${default:+ [${default}]}" >/dev/tty
    read -r answer </dev/tty
    answer="${answer:-${default}}"
    if [[ -n ${answer} ]] && "${check}" "${answer}"; then
      echo "${answer}"
      return
    fi
    printf '    That doesn'"'"'t look right; try again.\n' >/dev/tty
  done
}

# Asks for a space-separated list of sources (each checked with valid_source). Prints it.
valid_source_list() {
  local item
  for item in $1; do valid_source "${item}" || return 1; done
}

# Asks for a password without showing it, twice, at least PORTAINER_PASSWORD_MIN characters. Prints it.
ask_new_password() {
  local first second
  while true; do
    printf '    New Portainer password for %s (at least %s characters): ' "${PORTAINER_ADMIN}" "${PORTAINER_PASSWORD_MIN}" >/dev/tty
    read -r -s first </dev/tty
    printf '\n    Again: ' >/dev/tty
    read -r -s second </dev/tty
    printf '\n' >/dev/tty
    if ((${#first} < PORTAINER_PASSWORD_MIN)); then
      printf '    Too short.\n' >/dev/tty
    elif [[ ${first} != "${second}" ]]; then
      printf '    They differ.\n' >/dev/tty
    else
      printf '%s' "${first}"
      return
    fi
  done
}

# The address of the SSH session running this (your home IP when you're at home), or nothing.
session_address() {
  local address
  address="$(who -m --ips 2>/dev/null | awk '{ print $NF }' | tr -d '()' || true)"
  if valid_source "${address}"; then echo "${address}"; fi
}

# This machine's public address: the source address of its default route.
public_address() {
  ip -o -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1
}

# ---------------------------------------------------------------------------------------------
# Private management network: provided by network/wireguard-lib.sh, not OVH vRack
# ---------------------------------------------------------------------------------------------

ensure_private_ip() {
  if [[ "${1:-}" == server ]]; then wg_init_server; else wg_init_node; fi
  wg_available || die "WireGuard tunnel is not ready; refusing to start Portainer"
  config_set PRIVATE_IP "$(wg_private_ip)"
}

# ---------------------------------------------------------------------------------------------
# Firewall rules for Portainer's ports
# ---------------------------------------------------------------------------------------------

# From "ufw status" on stdin, prints the source of every rule letting in TCP <port> ("Anywhere" for an
# open one), once each.
port_sources() {
  awk -v port="$1" '
    NR <= 2 || /^To / || /^--/ || NF < 2 { next }
    {
      split($0, field, /  +/)
      target = field[1]; sub(/ \(v6\)$/, "", target)
      if (target != port && target != port "/tcp") next
      if (field[2] !~ /^(ALLOW|LIMIT)/) next
      source = field[3]; sub(/ +#.*$/, "", source); sub(/ \(v6\)$/, "", source)
      if (!(source in seen)) { seen[source] = 1; print source }
    }'
}

# From "ufw status numbered" on stdin, prints "<number>\t<source>" for every rule letting in TCP <port>.
numbered_port_rules() {
  awk -v port="$1" '
    match($0, /^\[ *[0-9]+\] /) {
      number = substr($0, 2, RLENGTH - 3); gsub(/ /, "", number)
      split(substr($0, RLENGTH + 1), field, /  +/)
      target = field[1]; sub(/ \(v6\)$/, "", target)
      if (target != port && target != port "/tcp") next
      if (field[2] !~ /^(ALLOW|LIMIT)/) next
      source = field[3]; sub(/ +#.*$/, "", source); sub(/ \(v6\)$/, "", source)
      print number "\t" source
    }'
}

# Makes TCP <port> reachable from exactly the <sources> given: adds a rule for each, then deletes every
# other rule for the port (highest number first, so the numbers stay right). Adding first means the
# port is never closed to the sources it should stay open to.
set_port_sources() {
  local port="$1" comment="$2" source number
  shift 2
  for source in "$@"; do
    ufw allow proto tcp from "${source}" to any port "${port}" comment "${comment}" >/dev/null
  done
  while read -r number; do
    ufw --force delete "${number}" >/dev/null
  done < <(ufw status numbered | numbered_port_rules "${port}" |
    awk -F'\t' -v keep=" $* " 'index(keep, " " $2 " ") == 0 { print $1 }' | sort -rn)
}

# Deletes every rule for TCP <port>.
close_port() {
  set_port_sources "$1" ""
}

# Doctor row for who can reach <port>: <name>, then the sources that should, space-separated.
check_port_sources() {
  local port="$1" name="$2" wanted="$3" actual
  actual="$(ufw status 2>/dev/null | port_sources "${port}" | LC_ALL=C sort | paste -sd' ' -)"
  wanted="$(tr ' ' '\n' <<<"${wanted}" | sed '/^$/d' | LC_ALL=C sort | paste -sd' ' -)"
  if [[ " ${actual} " == *" Anywhere "* ]]; then
    record FAIL "${name}" "port ${port} is open to anyone (should be: ${wanted:-nobody})" fix
  elif [[ -z ${actual} ]]; then
    record FAIL "${name}" "no firewall rule lets ${wanted:-anyone} reach port ${port}" fix
  elif [[ ${actual} != "${wanted}" ]]; then
    record WARN "${name}" "port ${port} lets in ${actual}; expected ${wanted}" fix
  else
    record PASS "${name}" "port ${port} only from ${actual}"
  fi
}

# From "ss -Htlnp" on stdin, prints each of Portainer's closed ports (HTTP, Edge tunnel) that one of its
# processes listens on outside loopback.
exposed_closed_ports() {
  awk -v closed=" ${PORTAINER_CLOSED_PORTS[*]} " '
    $0 !~ /"portainer"/ { next }
    {
      local_address = $4; port = local_address; sub(/.*:/, "", port)
      address = substr(local_address, 1, length(local_address) - length(port) - 1)
      gsub(/[][]/, "", address)
      if (address ~ /^127\./ || address == "::1") next
      if (index(closed, " " port " ") > 0 && !(port in seen)) { seen[port] = 1; print port }
    }'
}

# ---------------------------------------------------------------------------------------------
# The containers
# ---------------------------------------------------------------------------------------------

# Prints the server's "docker run" options, one per line. Host networking (ufw applies), the data folder,
# the secrets from the env file, no Docker socket.
server_options() {
  printf '%s\n' --restart=always --network=host --security-opt=no-new-privileges \
    "--env-file=${PORTAINER_ENV}" "--volume=${PORTAINER_DATA}:/data"
}

# Prints the server's own arguments, one per line: HTTPS only, the Edge tunnel on loopback.
server_command() {
  printf '%s\n' --http-disabled "--bind-https=:${PORTAINER_UI_PORT}" --tunnel-addr=127.0.0.1
}

# Prints the agent's "docker run" options, one per line, for private address <address>: it listens there
# only; it needs the Docker socket and the volumes folder to manage the node. (Host management, which
# mounts all of /, stays off.)
agent_options() {
  printf '%s\n' --restart=always --network=host --security-opt=no-new-privileges \
    "--env-file=${PORTAINER_ENV}" "--env=AGENT_HOST=$1" "--env=AGENT_PORT=${PORTAINER_AGENT_PORT}" \
    --volume=/var/run/docker.sock:/var/run/docker.sock \
    --volume=/var/lib/docker/volumes:/var/lib/docker/volumes
}

# Prints a short digest of a container's whole configuration (stdin), stored as a label so setup and
# doctor can tell when the running one is out of date.
config_digest() {
  sha256sum | cut -c1-12
}

# Prints "<options>\n--\n<image>\n<command>" for <role> (server or node), the input to config_digest
# and to docker run. Its last line is a digest of the secrets file, so changing a secret also counts as
# a change of settings (ensure_container stops reading at it).
container_spec() {
  if [[ $1 == "server" ]]; then
    server_options
    echo "--"
    echo "${PORTAINER_SERVER_IMAGE}"
    server_command
  else
    agent_options "$(config_get PRIVATE_IP)"
    echo "--"
    echo "${PORTAINER_AGENT_IMAGE}"
  fi
  printf 'secrets:%s\n' "$(sha256sum "${PORTAINER_ENV}" 2>/dev/null | cut -c1-12)"
}

# The container name and image for <role>.
container_name() { if [[ $1 == "server" ]]; then echo "${PORTAINER_SERVER_CONTAINER}"; else echo "${PORTAINER_AGENT_CONTAINER}"; fi; }
container_image() { if [[ $1 == "server" ]]; then echo "${PORTAINER_SERVER_IMAGE}"; else echo "${PORTAINER_AGENT_IMAGE}"; fi; }

# Prints "<state>\t<image id>\t<digest label>" for a container, or nothing when there is none.
container_facts() {
  docker inspect -f '{{.State.Status}}{{"\t"}}{{.Image}}{{"\t"}}{{index .Config.Labels "hostctl.config"}}' "$1" 2>/dev/null || true
}

# Starts (or replaces) the container for <role> so it runs the latest image of its tag with the current
# settings. Leaves a running, up-to-date one alone. Backs the server up before replacing it. Prints
# what it did.
ensure_container() {
  local role="$1" name image digest wanted state image_id label
  local -a spec options arguments
  name="$(container_name "${role}")"
  image="$(container_image "${role}")"
  mapfile -t spec < <(container_spec "${role}")
  digest="$(printf '%s\n' "${spec[@]}" | config_digest)"
  if ! docker pull -q "${image}" >/dev/null 2>&1; then
    docker image inspect "${image}" >/dev/null 2>&1 || die "couldn't download ${image}: is Docker Hub reachable?"
    note "couldn't reach Docker Hub; using the ${image} already here"
  fi
  wanted="$(docker image inspect -f '{{.Id}}' "${image}")"
  IFS=$'\t' read -r state image_id label <<<"$(container_facts "${name}")"
  if [[ ${state} == "running" && ${image_id} == "${wanted}" && ${label} == "${digest}" ]]; then
    note "${name}: up to date"
    return
  fi
  if [[ ${role} == "server" && -n ${state} ]]; then backup_server "" >/dev/null; fi
  docker rm -f "${name}" >/dev/null 2>&1 || true
  # The spec is "<options> -- <image> <command>".
  local i
  for i in "${!spec[@]}"; do [[ ${spec[i]} == "--" ]] && break; done
  options=("${spec[@]:0:i}")
  arguments=("${spec[@]:i+2}")
  unset 'arguments[-1]' # the secrets digest
  docker run -d --name "${name}" --label "hostctl.config=${digest}" "${options[@]}" "${image}" "${arguments[@]}" >/dev/null
  if [[ -z ${state} ]]; then note "${name}: started (${image})"; else note "${name}: replaced (${image}, ${wanted:7:12})"; fi
}

# Doctor row for <role>'s container.
check_container() {
  local role="$1" name digest state image_id label
  name="$(container_name "${role}")"
  digest="$(container_spec "${role}" | config_digest)"
  IFS=$'\t' read -r state image_id label <<<"$(container_facts "${name}")"
  if [[ -z ${state} ]]; then
    record FAIL "Portainer ${role}" "no ${name} container" fix
  elif [[ ${state} != "running" ]]; then
    record FAIL "Portainer ${role}" "${name} is ${state}: sudo docker logs ${name}" fix
  elif [[ ${label} != "${digest}" ]]; then
    record WARN "Portainer ${role}" "${name} runs with old settings" fix
  else
    record PASS "Portainer ${role}" "${name} running ($(container_image "${role}"), ${image_id:7:12})"
  fi
}

# ---------------------------------------------------------------------------------------------
# Backups (server)
# ---------------------------------------------------------------------------------------------

# Backs up the server's data and settings to <file> (default: a dated file in PORTAINER_BACKUP_DIR),
# stopping it for the few seconds that takes so the database is consistent. Keeps the newest
# PORTAINER_BACKUPS_KEPT dated files. Prints the file. The file holds the agent secret: root only.
backup_server() {
  local file="${1:-}" running="no" state
  install -d -m 0700 "${PORTAINER_BACKUP_DIR}"
  [[ -n ${file} ]] || file="${PORTAINER_BACKUP_DIR}/portainer-$(date -u +%Y%m%d-%H%M%S).tar.gz"
  [[ -d ${PORTAINER_DATA} ]] || die "${PORTAINER_DATA} doesn't exist: nothing to back up"
  IFS=$'\t' read -r state _ <<<"$(container_facts "${PORTAINER_SERVER_CONTAINER}")"
  if [[ ${state} == "running" ]]; then
    docker stop -t 30 "${PORTAINER_SERVER_CONTAINER}" >/dev/null
    running="yes"
  fi
  local result=0
  (umask 077 && tar -czf "${file}" -C / "${PORTAINER_DATA#/}" "${PORTAINER_CONFIG#/}" "${PORTAINER_ENV#/}") || result=$?
  if [[ ${running} == "yes" ]]; then docker start "${PORTAINER_SERVER_CONTAINER}" >/dev/null; fi
  ((result == 0)) || die "the backup failed (tar exited ${result})"
  chmod 0600 "${file}"
  find "${PORTAINER_BACKUP_DIR}" -maxdepth 1 -name 'portainer-*.tar.gz' -printf '%T@ %p\n' | sort -rn |
    tail -n +$((PORTAINER_BACKUPS_KEPT + 1)) | cut -d' ' -f2- | xargs -r rm -f
  echo "${file}"
}

# Prints the newest backup file, or nothing.
newest_backup() {
  find "${PORTAINER_BACKUP_DIR}" -maxdepth 1 -name 'portainer-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -n 1 | cut -d' ' -f2-
}

# From a backup's file list ("tar -tzf") on stdin: true when every entry is the data folder or the two
# settings files, so a restore can't write anywhere else.
backup_entries_ok() {
  local data="${PORTAINER_DATA#/}" config="${PORTAINER_CONFIG#/}" env="${PORTAINER_ENV#/}"
  awk -v data="${data}" -v config="${config}" -v env="${env}" '
    { entry = $0; sub(/\/$/, "", entry) }
    entry ~ /(^|\/)\.\.(\/|$)/ { bad = 1 }
    entry != data && index(entry, data "/") != 1 && entry != config && entry != env { bad = 1 }
    END { exit (NR == 0 || bad) }'
}

# Puts a backup's data in place of the server's (the current data is moved aside, not deleted) and takes
# its agent secret and allowed addresses. This VM keeps its own private address. The caller starts the
# server and applies the firewall.
restore_server() {
  local file="$1" folder secret allowed aside
  [[ -f ${file} ]] || die "no file ${file}"
  tar -tzf "${file}" | backup_entries_ok || die "${file} isn't a portainerctl backup (it has other files)"
  folder="$(mktemp -d)"
  tar -xzf "${file}" -C "${folder}"
  [[ -d ${folder}${PORTAINER_DATA} ]] || { rm -rf "${folder}"; die "${file} has no ${PORTAINER_DATA}"; }
  secret="$(config_get AGENT_SECRET "${folder}${PORTAINER_ENV}")"
  allowed="$(config_get ALLOWED_IPS "${folder}${PORTAINER_CONFIG}")"
  docker rm -f "${PORTAINER_SERVER_CONTAINER}" >/dev/null 2>&1 || true
  if [[ -d ${PORTAINER_DATA} && -n "$(ls -A "${PORTAINER_DATA}")" ]]; then
    aside="${PORTAINER_DATA}.before-restore-$(date -u +%Y%m%d-%H%M%S)"
    mv "${PORTAINER_DATA}" "${aside}"
    note "the data that was here is in ${aside}"
  fi
  rm -rf "${PORTAINER_DATA}"
  mv "${folder}${PORTAINER_DATA}" "${PORTAINER_DATA}"
  rm -rf "${folder}"
  if [[ -n ${secret} ]]; then config_set AGENT_SECRET "${secret}" "${PORTAINER_ENV}"; fi
  if [[ -n ${allowed} ]]; then config_set ALLOWED_IPS "${allowed}"; fi
  note "restored ${file}"
}

# ---------------------------------------------------------------------------------------------
# Portainer's API (server)
# ---------------------------------------------------------------------------------------------

# Prints curl settings for the API: the login token or the setup token, when there is one. Read by curl
# from a pipe (-K), so neither appears on a command line.
api_headers() {
  if [[ -n ${PORTAINER_JWT} ]]; then printf 'header = "Authorization: Bearer %s"\n' "${PORTAINER_JWT}"; fi
  if [[ -n ${PORTAINER_SETUP_TOKEN_HEADER} ]]; then printf 'header = "X-Setup-Token: %s"\n' "${PORTAINER_SETUP_TOKEN_HEADER}"; fi
}

# From an API error's body on stdin, prints Portainer's message.
api_error_message() {
  jq -r '[.message, .details] | map(select(. != null and . != "")) | join(": ")' 2>/dev/null || true
}

# Calls Portainer's API: <method> <path> [more curl arguments]. Prints the body; fails, saying what
# Portainer answered, on an error. The server's certificate is its own self-signed one, on loopback.
portainer_api() {
  local method="$1" path="$2" response status body
  shift 2
  response="$(curl -sk --max-time 60 -X "${method}" -K <(api_headers) -w '\n%{http_code}' \
    "${PORTAINER_API}${path}" "$@")" || {
    printf '\nERROR: Portainer isn'"'"'t answering at %s (portainerctl status)\n' "${PORTAINER_API}" >&2
    return 1
  }
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if ((status >= 400)); then
    printf '\nERROR: Portainer answered %s to %s %s: %s\n' "${status}" "${method}" "${path}" \
      "$(api_error_message <<<"${body}")" >&2
    return 1
  fi
  printf '%s' "${body}"
}

# Prints the HTTP status of a GET to <path> (000 when nothing answers).
api_status() {
  curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "${PORTAINER_API}$1" || true
}

# Waits up to a minute for the server to answer. Fails if it doesn't.
wait_for_server() {
  for _ in $(seq 30); do
    [[ "$(api_status /system/status)" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

# Prints the running server's version, or "unknown".
server_version() {
  curl -sk --max-time 10 "${PORTAINER_API}/system/status" 2>/dev/null | jq -r '.Version // "unknown"' 2>/dev/null ||
    echo "unknown"
}

# True when Portainer has its admin user.
admin_exists() {
  [[ "$(api_status /users/admin/check)" == "204" ]]
}

# Creates the admin user with a password asked for on the terminal. Portainer only accepts this for 5
# minutes after it starts, so the caller starts or restarts it first. The setup token (from the env
# file) proves the request comes from this machine; versions that don't use one ignore it.
init_admin() {
  local password
  PORTAINER_SETUP_TOKEN_HEADER="$(config_get PORTAINER_SETUP_TOKEN "${PORTAINER_ENV}")"
  password="$(ask_new_password)"
  printf '%s' "${password}" | jq -Rs --arg user "${PORTAINER_ADMIN}" '{Username: $user, Password: .}' |
    portainer_api POST /users/admin/init -H 'Content-Type: application/json' --data-binary @- >/dev/null || return 1
  PORTAINER_SETUP_TOKEN_HEADER=""
  note "admin user '${PORTAINER_ADMIN}' created"
}

# Logs in to the API as the admin, asking for the password; keeps the token in PORTAINER_JWT.
api_login() {
  local password response
  has_terminal || die "no terminal to ask the Portainer password on"
  printf '    Portainer password for %s: ' "${PORTAINER_ADMIN}" >/dev/tty
  read -r -s password </dev/tty
  printf '\n' >/dev/tty
  response="$(printf '%s' "${password}" | jq -Rs --arg user "${PORTAINER_ADMIN}" '{Username: $user, Password: .}' |
    portainer_api POST /auth -H 'Content-Type: application/json' --data-binary @-)" || die "couldn't log in"
  PORTAINER_JWT="$(jq -r '.jwt // empty' <<<"${response}")"
  [[ -n ${PORTAINER_JWT} ]] || die "Portainer's login answer had no token"
}

# From GET /endpoints on stdin, prints "<id>\t<name>\t<address>\t<state>" per environment.
parse_endpoints() {
  jq -r '.[] | [.Id, .Name, (.URL | sub("^tcp://"; "")), (if .Status == 1 then "up" elif .Status == 2 then "down" else "unknown" end)] | @tsv'
}

# Prints "up", "unreachable" or the HTTP status for the agent at <address>:9001 (it answers /ping).
agent_answer() {
  local status
  status="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$1:${PORTAINER_AGENT_PORT}/ping" || true)"
  case "${status}" in
    2??) echo "up" ;;
    000 | "") echo "unreachable" ;;
    *) echo "HTTP ${status}" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Shared by both components' setup
# ---------------------------------------------------------------------------------------------

# Stops if the other Portainer component is installed: one VM is either the server or a node.
refuse_both_roles() {
  if installed_components | grep -qx portainer-server && installed_components | grep -qx portainer-node; then
    unregister_components "$1"
    die "this VM is already a Portainer $([[ $1 == portainer-node ]] && echo server || echo node); one VM is either the server or a node"
  fi
}

# Doctor row: this VM has its private address.
check_private_network() {
  local address
  address="$(config_get PRIVATE_IP)"
  if [[ -z ${address} ]]; then
    record FAIL "Private network" "no private address set" fix
    return
  fi
  if wg_available "${address}"; then
    record PASS "Private network" "${address} on wg0"
  else
    record FAIL "Private network" "WireGuard tunnel unavailable" fix
  fi
}

# Links portainerctl into /usr/local/bin.
link_portainerctl() {
  ln -sfn "${TOOLS_DIR}/portainer/portainerctl.sh" /usr/local/bin/portainerctl
  ln -sfn "${TOOLS_DIR}/network/networkctl.sh" /usr/local/bin/networkctl
}

# Records this VM's role (<role>) where portainerctl status can read it without sudo.
record_role() {
  install -d -m 0755 "${STATE_DIR}"
  echo "$1" >"${PORTAINER_ROLE_FILE}"
  chmod 0644 "${PORTAINER_ROLE_FILE}"
}

# ---------------------------------------------------------------------------------------------
# portainer-server hooks
# ---------------------------------------------------------------------------------------------

# Asks who may reach the UI (Enter keeps the current list; at first, the address you're logged in from)
# and applies it.
configure_ui_access() {
  local allowed default
  default="$(config_get ALLOWED_IPS)"
  [[ -n ${default} ]] || default="${WG_ADMIN_ADDRESS}"
  allowed="${PORTAINER_HOME_IP:-}"
  if [[ -z ${allowed} ]]; then
    allowed="$(ask_value "WireGuard administrator IPs allowed to open Portainer (space-separated)" \
      "${default}" valid_source_list)" ||
      die "no terminal to ask who may reach the UI on: set PORTAINER_HOME_IP, e.g. 203.0.113.7"
  fi
  valid_source_list "${allowed}" || die "'${allowed}' isn't a list of IP addresses"
  config_set ALLOWED_IPS "${allowed}"
  # Restrict the Portainer UI to administrator peers on the authenticated VPN only.
  # shellcheck disable=SC2086 # one rule per address
  wg_set_port_sources "${PORTAINER_UI_PORT}" "Portainer UI" ${allowed}
  wg_check_port_sources "${PORTAINER_UI_PORT}" "Portainer UI" "${allowed}"
  [[ ${DOCTOR_FAILED:-0} == 0 ]] || die "Portainer UI firewall isolation check failed"
  note "the web UI lets in over wg0: ${allowed}"
}

# Makes the secrets the server needs, once: the agent secret and the setup token.
ensure_server_secrets() {
  if [[ -z "$(config_get AGENT_SECRET "${PORTAINER_ENV}")" ]]; then config_set AGENT_SECRET "$(new_secret)" "${PORTAINER_ENV}"; fi
  if [[ -z "$(config_get PORTAINER_SETUP_TOKEN "${PORTAINER_ENV}")" ]]; then config_set PORTAINER_SETUP_TOKEN "$(new_secret)" "${PORTAINER_ENV}"; fi
}

# Creates the admin user when there is none: restarts Portainer (it only accepts this for 5 minutes after
# starting) and asks for the password. Without a terminal, leaves it for "portainerctl init-admin".
ensure_admin() {
  if admin_exists; then
    note "admin user exists"
    return
  fi
  if ! has_terminal; then
    STILL_TO_DO+=("Portainer has no admin user yet: run 'sudo portainerctl init-admin'.")
    return
  fi
  docker restart "${PORTAINER_SERVER_CONTAINER}" >/dev/null
  wait_for_server || die "Portainer didn't start: sudo docker logs ${PORTAINER_SERVER_CONTAINER}"
  init_admin || die "couldn't create the admin user"
}

# Prints the SHA-256 fingerprint of the UI's certificate, so you can check it the first time a browser
# warns about it (it's self-signed).
ui_fingerprint() {
  openssl s_client -connect "127.0.0.1:${PORTAINER_UI_PORT}" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true
}

# hostctl hook: sets up the control plane. With PORTAINER_RESTORE=<backup> on a VM with no data yet,
# starts from that backup (moving the server to a new VM).
pserver_setup() {
  refuse_both_roles portainer-server
  record_role server
  ensure_private_ip server
  log "Portainer server"
  install -d -m 0700 "${PORTAINER_DATA}"
  if [[ -n ${PORTAINER_RESTORE:-} ]]; then
    [[ ${PORTAINER_RESTORE} == /* ]] || die "PORTAINER_RESTORE needs the backup's full path, e.g. /root/portainer-backup.tar.gz"
    if [[ -n "$(ls -A "${PORTAINER_DATA}")" ]]; then
      note "${PORTAINER_DATA} already has data, so PORTAINER_RESTORE is ignored (use: sudo portainerctl restore <file>)"
    else
      restore_server "${PORTAINER_RESTORE}"
    fi
  fi
  ensure_server_secrets
  configure_ui_access
  ensure_container server
  wait_for_server || die "Portainer didn't start: sudo docker logs ${PORTAINER_SERVER_CONTAINER}"
  note "Portainer $(server_version)"
  ensure_admin
}

pserver_install_commands() { link_portainerctl; }

# hostctl hook: what to do next.
pserver_notes() {
  local fingerprint
  fingerprint="$(ui_fingerprint)"
  note "Portainer: https://$(wg_private_ip):${PORTAINER_UI_PORT} (WireGuard administrators: $(config_get ALLOWED_IPS))"
  [[ -z ${fingerprint} ]] || note "Its certificate is self-signed; check the browser shows SHA-256 ${fingerprint}"
  note "Add a node: follow network/README.md (enroll its WireGuard public key first),"
  note "and the agent secret: sudo portainerctl secret), then here: sudo portainerctl add-node <name> <node's private IP>"
  note "Back up before changes: sudo portainerctl backup. Home IP changed? sudo portainerctl allow-ip <ip>"
}

# hostctl hook: the server's doctor checks.
pserver_checks() {
  if [[ ${EUID} -ne 0 ]]; then
    record PASS "Portainer server" "run with sudo to check it"
    return
  fi
  local exposed backup
  check_private_network
  check_container server
  wg_check_port_sources "${PORTAINER_UI_PORT}" "Portainer UI access" "$(config_get ALLOWED_IPS)"
  exposed="$(ss -Htlnp 2>/dev/null | exposed_closed_ports | paste -sd' ' -)"
  if [[ -n ${exposed} ]]; then
    record FAIL "Portainer HTTPS only" "Portainer listens on ${exposed} on the network" fix
  else
    record PASS "Portainer HTTPS only" "plain HTTP off; Edge tunnel on loopback"
  fi
  case "$(api_status /users/admin/check)" in
    204) record PASS "Portainer admin" "${PORTAINER_ADMIN} set up" ;;
    404) record FAIL "Portainer admin" "no admin user: sudo portainerctl init-admin" ;;
    *) record WARN "Portainer admin" "the server isn't answering" ;;
  esac
  backup="$(newest_backup)"
  if [[ -z ${backup} ]]; then
    record WARN "Portainer backup" "none yet: sudo portainerctl backup"
  elif (($(date +%s) - $(stat -c %Y "${backup}") > 8 * 86400)); then
    record WARN "Portainer backup" "newest is $(time_ago "$(stat -c %Y "${backup}")"): sudo portainerctl backup"
  else
    record PASS "Portainer backup" "newest $(time_ago "$(stat -c %Y "${backup}")")"
  fi
}

# hostctl hook (weekly update): moves the server to the newest image of its tag (backing it up first).
pserver_upgrade() {
  log "Portainer server"
  ensure_container server
  if wait_for_server; then note "Portainer $(server_version)"; else note "Portainer isn't answering yet"; fi
}

# hostctl hooks: production data never gets pruned; the UI port is Portainer's.
pserver_prune_level() { echo "images"; }
pserver_firewall_allowed() { echo "${PORTAINER_UI_PORT}/tcp"; }

# ---------------------------------------------------------------------------------------------
# portainer-node hooks
# ---------------------------------------------------------------------------------------------

# Asks for the server's private address (Enter keeps the current one) and lets only it reach the agent.
configure_agent_access() {
  local server
  server="${PORTAINER_SERVER_IP:-${WG_SERVER_ADDRESS}}"
  if [[ -z ${server} ]]; then
    server="$(ask_value "The Portainer server's private (vRack) address" "$(config_get SERVER_IP)" valid_ipv4)" ||
      die "no terminal to ask the server's address on: set PORTAINER_SERVER_IP, e.g. 10.0.0.1"
  fi
  valid_ipv4 "${server}" || die "'${server}' isn't an IPv4 address"
  config_set SERVER_IP "${server}"
  wg_set_port_sources "${PORTAINER_AGENT_PORT}" "Portainer agent" "${server}"
  wg_check_port_sources "${PORTAINER_AGENT_PORT}" "Portainer agent" "${server}"
  [[ ${DOCTOR_FAILED:-0} == 0 ]] || die "Portainer agent firewall isolation check failed"
  note "the agent lets in only ${server}"
}

# Asks for the agent secret (the server prints it: sudo portainerctl secret) unless there is one, or
# <ask> is "ask".
configure_agent_secret() {
  local secret="${PORTAINER_AGENT_SECRET:-}"
  if [[ -z ${secret} && -n "$(config_get AGENT_SECRET "${PORTAINER_ENV}")" && ${1:-} != "ask" ]]; then
    note "agent secret already set"
    return
  fi
  if [[ -z ${secret} ]]; then
    has_terminal || die "no terminal to ask the agent secret on: set PORTAINER_AGENT_SECRET"
    while true; do
      printf '    Agent secret (on the server: sudo portainerctl secret): ' >/dev/tty
      read -r -s secret </dev/tty
      printf '\n' >/dev/tty
      valid_secret "${secret}" && break
      printf '    That isn'"'"'t a secret the server makes; paste it again.\n' >/dev/tty
    done
  fi
  valid_secret "${secret}" || die "PORTAINER_AGENT_SECRET isn't a secret the server makes"
  config_set AGENT_SECRET "${secret}" "${PORTAINER_ENV}"
  note "agent secret saved (root only)"
}

# hostctl hook: sets up a node: its private address, who may reach the agent, the secret, the agent.
pnode_setup() {
  refuse_both_roles portainer-node
  record_role node
  ensure_private_ip node
  log "Portainer agent"
  configure_agent_access
  configure_agent_secret keep
  ensure_container node
  local answer="unreachable"
  for _ in $(seq 15); do
    answer="$(agent_answer "$(config_get PRIVATE_IP)")"
    [[ ${answer} == "up" ]] && break
    sleep 2
  done
  note "agent on $(config_get PRIVATE_IP):${PORTAINER_AGENT_PORT}: ${answer}"
}

pnode_install_commands() { link_portainerctl; }

# hostctl hook: what to do next.
pnode_notes() {
  note "On the server: sudo portainerctl add-node $(hostname -s) $(config_get PRIVATE_IP)"
  note "Apps publish their ports on 127.0.0.1 unless they say 0.0.0.0 (a reverse proxy's 80 and 443):"
  note "Docker opens published ports itself, past ufw, so publish only what the internet should reach."
}

# hostctl hook: the node's doctor checks.
pnode_checks() {
  if [[ ${EUID} -ne 0 ]]; then
    record PASS "Portainer node" "run with sudo to check it"
    return
  fi
  local answer
  check_private_network
  check_container node
  wg_check_port_sources "${PORTAINER_AGENT_PORT}" "Portainer agent access" "$(config_get SERVER_IP)"
  if [[ -z "$(config_get AGENT_SECRET "${PORTAINER_ENV}")" ]]; then
    record FAIL "Portainer agent secret" "none set: sudo portainerctl set-secret"
  fi
  answer="$(agent_answer "$(config_get PRIVATE_IP)")"
  if [[ ${answer} == "up" ]]; then
    record PASS "Portainer agent answers" "on $(config_get PRIVATE_IP):${PORTAINER_AGENT_PORT}"
  else
    record FAIL "Portainer agent answers" "${answer} on $(config_get PRIVATE_IP):${PORTAINER_AGENT_PORT}" fix
  fi
}

# hostctl hook (weekly update): moves the agent to the newest image of its tag. Apps keep running.
pnode_upgrade() {
  log "Portainer agent"
  ensure_container node
}

# hostctl hooks: production data never gets pruned; the agent port is Portainer's.
pnode_prune_level() { echo "images"; }
pnode_firewall_allowed() { echo "${PORTAINER_AGENT_PORT}/tcp"; }
