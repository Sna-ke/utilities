#!/usr/bin/env bash
# Inspect and maintain the private WireGuard overlay. Never prints private keys.
set -Eeuo pipefail
NET_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../host/host-lib.sh
. "${NET_DIR}/../host/host-lib.sh"
# shellcheck source=wireguard-lib.sh
. "${NET_DIR}/wireguard-lib.sh"
trap 'die "line ${LINENO}: ${BASH_COMMAND} failed"' ERR

usage() {
  cat <<'HELP'
networkctl public-key                    print this machine's WireGuard public key
networkctl status                        display overlay role, address and peers
networkctl add-peer <name> <ip> <key>     register a node or administrator on the server
networkctl remove-peer <name>            revoke an existing peer
HELP
}
main() {
  local command="${1:-help}"
  if (($#)); then shift; fi
  case "${command}" in
    help|-h|--help) usage ;;
    public-key) (($#==0)) || die "unexpected arguments"; wg_public_key ;;
    status)
      (($#==0)) || die "unexpected arguments"
      echo "Role: $(wg_role)"
      echo "VPN address: $(wg_private_ip)"
      if wg_available; then wg show "${WG_IFACE}"; else echo "WireGuard tunnel: unavailable"; fi
      ;;
    add-peer)
      [[ ${EUID} -eq 0 ]] || die "run with sudo"
      wg_add_peer "$@"
      ;;
    remove-peer)
      [[ ${EUID} -eq 0 ]] || die "run with sudo"
      wg_remove_peer "$@"
      ;;
    *) die "unknown command: ${command}" ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
