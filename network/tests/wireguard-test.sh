#!/usr/bin/env bash
# WireGuard overlay regression tests; no root, network, or WireGuard interface required.
set -Eeuo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../host/host-lib.sh
. "${TEST_DIR}/../../host/host-lib.sh"
# shellcheck source=../wireguard-lib.sh
. "${TEST_DIR}/../wireguard-lib.sh"
SAMPLES="$(mktemp -d)"
trap 'rm -rf "${SAMPLES}"' EXIT
WG_DIR="${SAMPLES}/wireguard"
WG_FILE="${WG_DIR}/wg0.conf"
WG_KEY_FILE="${WG_DIR}/hostctl.key"
WG_META="${SAMPLES}/meta"
mkdir -p "${WG_DIR}"
PASSED=0
FAILED=0

check() {
  if [[ "$2" == "$3" ]]; then PASSED=$((PASSED+1))
  else
    FAILED=$((FAILED+1))
    printf 'FAIL %s: expected <%s>, actual <%s>\n' "$1" "$2" "$3"
  fi
}
outcome() {
  if ("$@") >/dev/null 2>&1; then echo ok; else echo fails; fi
}
check "valid address" ok "$(outcome wg_valid_ip 10.70.0.2)"
check "invalid address" fails "$(outcome wg_valid_ip 10.70.0.300)"
check "invalid prefix string" fails "$(outcome wg_valid_ip 10.70.0.2/24)"
check "peer name" ok "$(outcome wg_valid_name admin-mac)"
check "peer name path" fails "$(outcome wg_valid_name '../admin')"
check "node key" ok "$(outcome wg_valid_key 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')"
check "short key" fails "$(outcome wg_valid_key bad)"
check "endpoint" ok "$(outcome wg_valid_endpoint vps.example.net:51820)"
check "endpoint injection" fails "$(outcome wg_valid_endpoint 'vps.example.net;id:51820')"
printf 'ROLE=server\nADDRESS=10.70.0.1\n' >"${WG_META}"
check "role" server "$(wg_role)"
check "address" 10.70.0.1 "$(wg_private_ip)"

# Fake UFW output includes legacy public allows and a correctly scoped tunnel rule.
UFW_LOG="${SAMPLES}/ufw.log"
NUMBERED='Status: active
[ 1] 9443/tcp                   ALLOW IN    Anywhere
[ 2] 9001/tcp on wg0            ALLOW IN    10.70.0.1
[ 3] 9443/tcp on wg0            ALLOW IN    10.70.0.10'
# shellcheck disable=SC2317,SC2329 # fake replaces a host command
ufw() {
  if [[ $* == "status numbered" ]]; then printf '%s\n' "${NUMBERED}"
  elif [[ $* == "status" ]]; then printf '%s\n' "${STATUS}"
  else printf '%s\n' "$*" >>"${UFW_LOG}"
  fi
}
wg_set_port_sources 9443 "Portainer UI" 10.70.0.10
check "firewall deletes public and old VPN rule before allowing VPN"   $'--force delete 3\n--force delete 1\nallow in on wg0 proto tcp from 10.70.0.10 to any port 9443 comment Portainer UI'   "$(cat "${UFW_LOG}")"
STATUS='Status: active
To                         Action      From
--                         ------      ----
9443/tcp on wg0             ALLOW IN    10.70.0.10'
DOCTOR_ROWS=()
DOCTOR_FAILED=0
wg_check_port_sources 9443 "UI" "10.70.0.10"
check "VPN firewall rule passes" 0 "${DOCTOR_FAILED}"
STATUS="${STATUS}"$'\n9443/tcp                   ALLOW IN    Anywhere'
DOCTOR_ROWS=()
DOCTOR_FAILED=0
wg_check_port_sources 9443 "UI" "10.70.0.10"
check "public allow cannot hide behind VPN rule" 1 "${DOCTOR_FAILED}"
unset -f ufw

printf '# Managed by hostctl\n[Interface]\nAddress = 10.70.0.1/24\nPrivateKey = test\n' >"${WG_FILE}"
# shellcheck disable=SC2317,SC2329 # fake replaces a host command
wg() {
  if [[ $1 == syncconf ]]; then cp "${WG_FILE}" "${SAMPLES}/last-sync"; fi
}
# shellcheck disable=SC2317,SC2329 # fake replaces a host command
wg-quick() {
  if [[ $1 == strip ]]; then
    [[ -f ${2:-} ]] && cat "$2" || cat "${WG_FILE}"
  fi
}
# shellcheck disable=SC2317,SC2329 # fake key provided by test
wg_public_key() { echo 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='; }
wg_add_peer groundcore 10.70.0.2 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >/dev/null
check "peer appended" 1 "$(grep -Fc '# Peer: groundcore' "${WG_FILE}")"
check "duplicate peer rejected" fails "$(outcome wg_add_peer groundcore 10.70.0.3 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=')"
wg_remove_peer groundcore >/dev/null
check "peer revoked" 0 "$(grep -Fc '# Peer: groundcore' "${WG_FILE}" || true)"
unset -f wg wg-quick wg_public_key

printf '%d passed, %d failed\n' "${PASSED}" "${FAILED}"
((FAILED == 0))
