#!/usr/bin/env bash
# Tests portainerctl's parsing and checks against sample input: settings files, addresses, ufw rules,
# network cards, listening sockets, container settings, backups' file lists, API answers, and the
# component plumbing in host-lib.sh. Needs no VM, root, Docker or Portainer; only bash, jq, GNU awk/sed.
#
#   bash portainer/tests/portainer-test.sh
#
# What only real VMs can test (Docker, ufw, netplan, Portainer's API, the agent) is listed in
# portainer/README.md under "Testing".

set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../portainerctl.sh
. "${TESTS_DIR}/../portainerctl.sh"
trap - ERR # failures are reported by the checks below, not by portainerctl's trap

SAMPLES="$(mktemp -d)"
trap 'rm -rf "${SAMPLES}"' EXIT
CONFIG_DIR="${SAMPLES}/etc"
STATE_DIR="${SAMPLES}/state"
COMPONENTS_FILE="${CONFIG_DIR}/components"
PORTAINER_CONFIG="${CONFIG_DIR}/portainer.conf"
PORTAINER_ENV="${CONFIG_DIR}/portainer.env"
PORTAINER_ROLE_FILE="${STATE_DIR}/portainer-role"
PASSED=0
FAILED=0

# Compares expected and actual output and records the result; prints both when they differ.
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ ${expected} == "${actual}" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n--- expected\n%s\n--- actual\n%s\n\n' "${name}" "${expected}" "${actual}"
  fi
}

# Records whether a command succeeded ("ok") or failed ("fails"). Runs it in a subshell, because a
# validation failure calls die, which exits.
outcome() {
  if ("$@") >/dev/null 2>&1; then echo "ok"; else echo "fails"; fi
}

# ---------------------------------------------------------------------------------------------
# Settings files
# ---------------------------------------------------------------------------------------------

check "setting: missing file" "" "$(config_get PRIVATE_IP)"
config_set PRIVATE_IP 10.0.0.1
config_set ALLOWED_IPS "203.0.113.7 198.51.100.0/24"
config_set PRIVATE_IP 10.0.0.2
check "settings: replaced, others kept" $'ALLOWED_IPS=203.0.113.7 198.51.100.0/24\nPRIVATE_IP=10.0.0.2' "$(cat "${PORTAINER_CONFIG}")"
check "setting: value with spaces" "203.0.113.7 198.51.100.0/24" "$(config_get ALLOWED_IPS)"
check "setting: a key that's a prefix of another isn't confused" "" "$(config_get PRIVATE)"
check "settings file is root-only" "600" "$(stat -c %a "${PORTAINER_CONFIG}")"
config_set AGENT_SECRET "abc=def" "${PORTAINER_ENV}"
check "setting: value with =" "abc=def" "$(config_get AGENT_SECRET "${PORTAINER_ENV}")"
check "setting: no line breaks" "fails" "$(outcome config_set X $'a\nb')"

# ---------------------------------------------------------------------------------------------
# Addresses, names and secrets
# ---------------------------------------------------------------------------------------------

check "ipv4" "ok" "$(outcome valid_ipv4 203.0.113.7)"
check "ipv4: octet too big" "fails" "$(outcome valid_ipv4 10.0.0.256)"
check "ipv4: leading zeros aren't octal" "ok" "$(outcome valid_ipv4 10.0.0.08)"
check "ipv4: too short" "fails" "$(outcome valid_ipv4 10.0.1)"
check "ipv4: with a prefix" "fails" "$(outcome valid_ipv4 10.0.0.1/24)"
check "source: ipv4" "ok" "$(outcome valid_source 203.0.113.7)"
check "source: ipv4 range" "ok" "$(outcome valid_source 198.51.100.0/24)"
check "source: prefix too big" "fails" "$(outcome valid_source 198.51.100.0/33)"
check "source: ipv6" "ok" "$(outcome valid_source 2001:db8::1)"
check "source: ipv6 range" "ok" "$(outcome valid_source 2001:db8::/48)"
check "source: a name" "fails" "$(outcome valid_source home.example.com)"
check "source: Anywhere" "fails" "$(outcome valid_source Anywhere)"
check "source list" "ok" "$(outcome valid_source_list "203.0.113.7 2001:db8::1")"
check "source list: one bad" "fails" "$(outcome valid_source_list "203.0.113.7 nope")"
check "private cidr" "ok" "$(outcome valid_private_cidr 10.0.0.1/24)"
check "private cidr: no prefix" "fails" "$(outcome valid_private_cidr 10.0.0.1)"
check "private cidr: /32" "fails" "$(outcome valid_private_cidr 10.0.0.1/32)"
check "node name" "ok" "$(outcome valid_node_name vps-app-1)"
check "node name: space" "fails" "$(outcome valid_node_name "vps app")"
check "node name: starts with a dash" "fails" "$(outcome valid_node_name -vps)"
check "secret: server-made" "ok" "$(outcome valid_secret "$(printf 'a1%.0s' {1..32})")"
check "secret: too short" "fails" "$(outcome valid_secret abc123)"
check "secret: a quote" "fails" "$(outcome valid_secret "$(printf 'a%.0s' {1..40})\"")"

# ---------------------------------------------------------------------------------------------
# Network cards
# ---------------------------------------------------------------------------------------------

LINKS='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT
2: ens3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT
3: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT
4: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT
5: veth12ab@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master docker0 state UP'
ADDRESSES='1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
2: ens3    inet 198.51.100.20/32 metric 100 scope global dynamic ens3\       valid_lft 85000sec preferred_lft 85000sec
4: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever'
check "free cards: the vRack one" "ens4" "$(unaddressed_interfaces "${LINKS}" "${ADDRESSES}")"
check "card with an address" "ens3" "$(interface_with_address 198.51.100.20 <<<"${ADDRESSES}")"
check "no card with an address" "" "$(interface_with_address 10.0.0.1 <<<"${ADDRESSES}")"
check "no partial address match" "" "$(interface_with_address 198.51.100.2 <<<"${ADDRESSES}")"
check "netplan file" "# Written by hostctl (Portainer): this VM's private (vRack) address.
network:
  version: 2
  ethernets:
    ens4:
      dhcp4: false
      addresses: [10.0.0.2/24]" "$(netplan_private ens4 10.0.0.2/24)"

# ---------------------------------------------------------------------------------------------
# Firewall rules
# ---------------------------------------------------------------------------------------------

UFW_STATUS='Status: active

To                         Action      From
--                         ------      ----
9452/tcp                   LIMIT       Anywhere                   # SSH
9443/tcp                   ALLOW       203.0.113.7                # Portainer UI
9443/tcp                   ALLOW       198.51.100.0/24            # Portainer UI
9001/tcp                   ALLOW       10.0.0.1                   # Portainer agent
9452/tcp (v6)              LIMIT       Anywhere (v6)              # SSH
9443/tcp (v6)              ALLOW       2001:db8:1234:5678:9abc:def0:1234:5678 # Portainer UI'
check "UI sources" $'203.0.113.7\n198.51.100.0/24\n2001:db8:1234:5678:9abc:def0:1234:5678' "$(port_sources 9443 <<<"${UFW_STATUS}")"
check "agent sources" "10.0.0.1" "$(port_sources 9001 <<<"${UFW_STATUS}")"
check "open port shows Anywhere once" "Anywhere" "$(port_sources 9452 <<<"${UFW_STATUS}")"
check "no rules for a port" "" "$(port_sources 8000 <<<"${UFW_STATUS}")"
check "a port without /tcp counts" "Anywhere" "$(port_sources 9443 <<<$'Status: active\n\nTo                         Action      From\n--                         ------      ----\n9443                       ALLOW       Anywhere')"

UFW_NUMBERED='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 9452/tcp                   LIMIT IN    Anywhere                   # SSH
[ 2] 9443/tcp                   ALLOW IN    203.0.113.7                # Portainer UI
[ 3] 9443/tcp                   ALLOW IN    Anywhere
[ 4] 9001/tcp                   ALLOW IN    10.0.0.1                   # Portainer agent
[10] 9443/tcp (v6)              ALLOW IN    Anywhere (v6)'
check "numbered rules for the UI" $'2\t203.0.113.7\n3\tAnywhere\n10\tAnywhere' "$(numbered_port_rules 9443 <<<"${UFW_NUMBERED}")"

# set_port_sources with ufw replaced: records the commands and answers "status numbered" from a sample.
UFW_LOG="${SAMPLES}/ufw.log"
# shellcheck disable=SC2317,SC2329 # called by the library
ufw() {
  echo "$*" >>"${UFW_LOG}"
  if [[ $* == "status numbered" ]]; then echo "${UFW_NUMBERED}"; fi
}
set_port_sources 9443 "Portainer UI" 203.0.113.7
check "UI rules: adds the address, deletes the others highest first" \
  "allow proto tcp from 203.0.113.7 to any port 9443 comment Portainer UI
status numbered
--force delete 10
--force delete 3" "$(cat "${UFW_LOG}")"
: >"${UFW_LOG}"
close_port 9001
check "closing a port deletes all its rules" $'status numbered\n--force delete 4' "$(cat "${UFW_LOG}")"
unset -f ufw

# check_port_sources with ufw status replaced.
# shellcheck disable=SC2317,SC2329 # called by the library
ufw() { echo "${UFW_STATUS}"; }
DOCTOR_ROWS=()
check_port_sources 9443 "UI" "198.51.100.0/24 203.0.113.7 2001:db8:1234:5678:9abc:def0:1234:5678"
check_port_sources 9443 "UI" "203.0.113.7"
check_port_sources 9001 "Agent" "10.0.0.1"
check_port_sources 9452 "SSH" "203.0.113.7"
check_port_sources 8000 "Tunnel" "10.0.0.1"
check "doctor rows for ports" "UI	PASS	port 9443 only from 198.51.100.0/24 2001:db8:1234:5678:9abc:def0:1234:5678 203.0.113.7
UI	WARN	port 9443 lets in 198.51.100.0/24 2001:db8:1234:5678:9abc:def0:1234:5678 203.0.113.7; expected 203.0.113.7
Agent	PASS	port 9001 only from 10.0.0.1
SSH	FAIL	port 9452 is open to anyone (should be: 203.0.113.7)
Tunnel	FAIL	no firewall rule lets 10.0.0.1 reach port 8000" "$(printf '%s\n' "${DOCTOR_ROWS[@]}")"
unset -f ufw

check "host firewall check accepts the components' ports" "" \
  "$(firewall_problems 9452 "9443/tcp 9001/tcp" <<<"${UFW_STATUS}")"
check "host firewall check without them" $'also lets in 9443/tcp\nalso lets in 9001/tcp' \
  "$(firewall_problems 9452 "" <<<"${UFW_STATUS}")"

# ---------------------------------------------------------------------------------------------
# Listening sockets
# ---------------------------------------------------------------------------------------------

SS='LISTEN 0      4096         0.0.0.0:9452       0.0.0.0:*    users:(("sshd",pid=900,fd=3))
LISTEN 0      4096               *:9443             *:*    users:(("portainer",pid=1201,fd=8))
LISTEN 0      4096       127.0.0.1:8000       0.0.0.0:*    users:(("portainer",pid=1201,fd=9))
LISTEN 0      4096       127.0.0.1:9000       0.0.0.0:*    users:(("python3",pid=77,fd=3))'
check "HTTPS only: nothing exposed" "" "$(exposed_closed_ports <<<"${SS}")"
check "HTTPS only: HTTP and tunnel on the network" $'9000\n8000' "$(exposed_closed_ports <<<'LISTEN 0 4096 *:9000 *:* users:(("portainer",pid=1,fd=7))
LISTEN 0 4096 [::]:8000 [::]:* users:(("portainer",pid=1,fd=9))
LISTEN 0 4096 [::]:9000 [::]:* users:(("portainer",pid=1,fd=7))')"
check "another program on 9000 isn't Portainer's" "" "$(exposed_closed_ports <<<'LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:* users:(("node",pid=5,fd=3))')"

# ---------------------------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------------------------

SERVER_SPEC="$(container_spec server)"
check "server: host network, data folder, secrets from the file" "ok" "$(outcome grep -qxF -- "--network=host" <<<"${SERVER_SPEC}")"
check "server: env file" "ok" "$(outcome grep -qxF -- "--env-file=${PORTAINER_ENV}" <<<"${SERVER_SPEC}")"
check "server: data is a folder, not a volume" "ok" "$(outcome grep -qxF -- "--volume=/var/lib/portainer:/data" <<<"${SERVER_SPEC}")"
check "server: no Docker socket" "fails" "$(outcome grep -q docker.sock <<<"${SERVER_SPEC}")"
check "server: no published ports" "fails" "$(outcome grep -qE -- '^(-p|--publish)' <<<"${SERVER_SPEC}")"
check "server: HTTPS only, tunnel on loopback" $'--http-disabled\n--bind-https=:9443\n--tunnel-addr=127.0.0.1' \
  "$(sed -n '/^--$/,$p' <<<"${SERVER_SPEC}" | tail -n +3 | sed '$d')"
check "spec ends with the secrets digest, not the secrets" "ok" "$(outcome grep -qE '^secrets:[0-9a-f]{12}$' <<<"$(tail -n 1 <<<"${SERVER_SPEC}")")"
check "server: no secret on the command line" "fails" "$(outcome grep -q AGENT_SECRET= <<<"${SERVER_SPEC}")"
NODE_SPEC="$(container_spec node)"
check "agent: listens on the private address only" "ok" "$(outcome grep -qxF -- "--env=AGENT_HOST=10.0.0.2" <<<"${NODE_SPEC}")"
check "agent: no host filesystem" "fails" "$(outcome grep -q ':/host' <<<"${NODE_SPEC}")"
check "agent: image" "portainer/agent:lts" "$(sed -n '/^--$/{n;p;}' <<<"${NODE_SPEC}")"
check "digest is stable" "$(container_spec node | config_digest)" "$(printf '%s\n' "${NODE_SPEC}" | config_digest)"
config_set PRIVATE_IP 10.0.0.3
check "digest changes with the settings" "fails" "$(outcome test "$(container_spec node | config_digest)" = "$(printf '%s\n' "${NODE_SPEC}" | config_digest)")"
config_set PRIVATE_IP 10.0.0.2
config_set AGENT_SECRET changed "${PORTAINER_ENV}"
check "digest changes with the secret" "fails" "$(outcome test "$(container_spec node | config_digest)" = "$(printf '%s\n' "${NODE_SPEC}" | config_digest)")"
config_set AGENT_SECRET abc=def "${PORTAINER_ENV}"

# ensure_container with Docker replaced: what it runs for a new server, and that it leaves an
# up-to-date one alone.
DOCKER_LOG="${SAMPLES}/docker.log"
CONTAINER_FACTS=""
# shellcheck disable=SC2317,SC2329 # called by the library
docker() {
  case "$1 ${2:-}" in
    "pull "*) return 0 ;;
    "image inspect") echo "sha256:0123456789abcdef" ;;
    "inspect "*) [[ -z ${CONTAINER_FACTS} ]] || echo "${CONTAINER_FACTS}" ;;
    *) echo "$*" >>"${DOCKER_LOG}" ;;
  esac
}
check "new server: started" "    portainer: started (portainer/portainer-ce:lts)" "$(ensure_container server)"
RUN_LINE="run -d --name portainer --label hostctl.config=$(container_spec server | config_digest) --restart=always"
RUN_LINE+=" --network=host --security-opt=no-new-privileges --env-file=${PORTAINER_ENV}"
RUN_LINE+=" --volume=/var/lib/portainer:/data portainer/portainer-ce:lts --http-disabled --bind-https=:9443 --tunnel-addr=127.0.0.1"
check "new server: the docker run" "rm -f portainer
${RUN_LINE}" "$(cat "${DOCKER_LOG}")"
: >"${DOCKER_LOG}"
CONTAINER_FACTS="running	sha256:0123456789abcdef	$(container_spec node | config_digest)"
check "up-to-date agent left alone" "    portainer_agent: up to date" "$(ensure_container node)"
check "up-to-date agent: nothing run" "" "$(cat "${DOCKER_LOG}")"
unset -f docker

# ---------------------------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------------------------

check "backup list: ours" "ok" "$(outcome backup_entries_ok <<<'var/lib/portainer/
var/lib/portainer/portainer.db
var/lib/portainer/certs/cert.pem
'"${PORTAINER_CONFIG#/}"'
'"${PORTAINER_ENV#/}")"
check "backup list: something else" "fails" "$(outcome backup_entries_ok <<<$'var/lib/portainer/portainer.db\netc/passwd')"
check "backup list: a look-alike folder" "fails" "$(outcome backup_entries_ok <<<'var/lib/portainer-evil/x')"
check "backup list: climbing out" "fails" "$(outcome backup_entries_ok <<<'var/lib/portainer/../../../etc/cron.d/x')"
check "backup list: empty" "fails" "$(outcome backup_entries_ok </dev/null)"

# A real backup and restore round trip, with Docker replaced: data, the secret and the UI addresses come
# back; this VM's private address stays.
# shellcheck disable=SC2317,SC2329 # called by the library
docker() { return 1; }
PORTAINER_DATA="${SAMPLES}/data"
PORTAINER_BACKUP_DIR="${SAMPLES}/backups"
mkdir -p "${PORTAINER_DATA}/certs"
echo "db v1" >"${PORTAINER_DATA}/portainer.db"
config_set AGENT_SECRET old-secret "${PORTAINER_ENV}"
config_set ALLOWED_IPS 203.0.113.7
BACKUP="$(backup_server "" 2>/dev/null)"
check "backup file is root-only" "600" "$(stat -c %a "${BACKUP}")"
check "backup file list passes the restore check" "ok" "$(tar -tzf "${BACKUP}" | outcome backup_entries_ok)"
echo "db v2" >"${PORTAINER_DATA}/portainer.db"
config_set AGENT_SECRET new-secret "${PORTAINER_ENV}"
config_set ALLOWED_IPS 198.51.100.9
config_set PRIVATE_IP 10.0.0.9
restore_server "${BACKUP}" >/dev/null
check "restore: data back" "db v1" "$(cat "${PORTAINER_DATA}/portainer.db")"
check "restore: old data moved aside" "db v2" "$(cat "${PORTAINER_DATA}".before-restore-*/portainer.db)"
check "restore: secret back" "old-secret" "$(config_get AGENT_SECRET "${PORTAINER_ENV}")"
check "restore: UI addresses back" "203.0.113.7" "$(config_get ALLOWED_IPS)"
check "restore: private address kept" "10.0.0.9" "$(config_get PRIVATE_IP)"
for _ in 1 2 3 4 5 6 7 8 9 10; do touch -d "-1 day" "${BACKUP}"; cp -p "${BACKUP}" "${PORTAINER_BACKUP_DIR}/portainer-old-${RANDOM}${RANDOM}.tar.gz"; done
backup_server "" >/dev/null 2>&1
check "backups: only the newest kept" "${PORTAINER_BACKUPS_KEPT}" "$(find "${PORTAINER_BACKUP_DIR}" -name 'portainer-*.tar.gz' | wc -l)"
check "newest backup is the one just made" "ok" "$(outcome test $(($(date +%s) - $(stat -c %Y "$(newest_backup)"))) -lt 60)"
unset -f docker
PORTAINER_DATA="/var/lib/portainer"

# ---------------------------------------------------------------------------------------------
# Portainer's API
# ---------------------------------------------------------------------------------------------

check "environments" $'1\tvps-app-1\t10.0.0.2:9001\tup\n3\tvps-app-2\t10.0.0.3:9001\tdown' "$(parse_endpoints <<<'[
  {"Id": 1, "Name": "vps-app-1", "URL": "tcp://10.0.0.2:9001", "Status": 1, "Type": 2},
  {"Id": 3, "Name": "vps-app-2", "URL": "tcp://10.0.0.3:9001", "Status": 2, "Type": 2}
]')"
check "API error message" "Invalid request payload: Invalid username" \
  "$(api_error_message <<<'{"message":"Invalid request payload","details":"Invalid username"}')"
check "API error message without details" "Unauthorized" "$(api_error_message <<<'{"message":"Unauthorized"}')"
check "API error that isn't JSON" "" "$(api_error_message <<<'<html>')"
check "headers: none" "" "$(api_headers)"
check "headers: login and setup token" $'header = "Authorization: Bearer abc.def"\nheader = "X-Setup-Token: 0123"' \
  "$(PORTAINER_JWT=abc.def PORTAINER_SETUP_TOKEN_HEADER=0123 api_headers)"
check "login body keeps quotes and backslashes in the password" '{"Username":"admin","Password":"p\"a\\ss word"}' \
  "$(printf '%s' 'p"a\ss word' | jq -cRs --arg user admin '{Username: $user, Password: .}')"

# ---------------------------------------------------------------------------------------------
# Components in host-lib.sh
# ---------------------------------------------------------------------------------------------

check "component fields" "portainer	portainer-lib.sh	pserver	pnode" \
  "$(printf '%s\t' "$(component_field portainer-server folder)" "$(component_field portainer-server library)" \
    "$(component_field portainer-server prefix)" "$(component_field portainer-node prefix)" | sed 's/\t$//')"
check "folders for the runner VM with the server" $'host\ngithub-runner\nportainer' "$(tool_folders github-runner portainer-server)"
mkdir -p "${CONFIG_DIR}"
printf 'github-runner\nportainer-server\n' >"${COMPONENTS_FILE}"
runner_prune_level() { echo full; } # runner-lib.sh isn't loaded here
check "prune levels with the runner" $'full\nimages' "$(call_hooks prune_level)"
check "ports the components open" $'9443/tcp' "$(call_hooks firewall_allowed)"
check "role from the components" "server" "$(this_role)"
printf 'portainer-node\n' >"${COMPONENTS_FILE}"
check "node: prune images only" "images" "$(call_hooks prune_level)"
check "node: agent port" "9001/tcp" "$(call_hooks firewall_allowed)"
check "role: node" "node" "$(this_role)"
printf 'portainer-node\nportainer-server\n' >"${COMPONENTS_FILE}"
check "server and node on one VM are refused" "fails" "$(outcome refuse_both_roles portainer-server)"
check "the refused one is taken off the list" "portainer-node" "$(cat "${COMPONENTS_FILE}")"
printf 'github-runner\nportainer-server\n' >"${COMPONENTS_FILE}"
unregister_components portainer-server >/dev/null
check "unregister keeps the others" "github-runner" "$(cat "${COMPONENTS_FILE}")"
unregister_components github-runner >/dev/null
check "unregister the last one" "" "$(cat "${COMPONENTS_FILE}")"

# The shared library is sourced once even with two components using it (a fake root with a library that
# counts its loads).
FAKE_ROOT="${SAMPLES}/root"
mkdir -p "${FAKE_ROOT}/portainer"
# shellcheck disable=SC2016 # written for the library to run
echo 'LOADS=$((LOADS + 1))' >"${FAKE_ROOT}/portainer/portainer-lib.sh"
LOADS=0
printf 'portainer-server\nportainer-node\n' >"${COMPONENTS_FILE}"
load_components "${FAKE_ROOT}"
check "shared library loaded once" "1" "${LOADS}"

# Without the component list (not root), the role comes from the role file.
chmod 000 "${COMPONENTS_FILE}"
if [[ ${EUID} -ne 0 ]]; then
  mkdir -p "${STATE_DIR}"
  echo node >"${PORTAINER_ROLE_FILE}"
  check "role without sudo" "node" "$(this_role)"
fi
chmod 600 "${COMPONENTS_FILE}"

# shellcheck disable=SC2016 # the inner script expands its own variables
check "usage lists every command" "ok" "$(outcome bash -c '
  for command in add-node remove-node nodes allow-ip secret backup restore init-admin set-server set-secret status upgrade remove; do
    grep -q "^  ${command}" <<<"$1" || exit 1
  done' _ "$(usage)")"
check "unknown command" "fails" "$(outcome main frobnicate)"

printf '%d passed, %d failed\n' "${PASSED}" "${FAILED}"
((FAILED == 0))
