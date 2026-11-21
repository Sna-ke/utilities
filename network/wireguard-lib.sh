# shellcheck shell=bash
# Reusable, host-managed WireGuard overlay for OVH VPS instances (no vRack or second NIC).
# Source after host/host-lib.sh. Configuration and keys are owned by root.
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_FILE="${WG_DIR}/${WG_IFACE}.conf"
WG_KEY_FILE="${WG_DIR}/hostctl.key"
WG_META="${CONFIG_DIR}/wireguard.conf"
WG_PORT="${WG_PORT:-51820}"
WG_SERVER_CIDR="${WG_SERVER_CIDR:-10.70.0.1/24}"
WG_SERVER_ADDRESS="${WG_SERVER_ADDRESS:-10.70.0.1}"
WG_PEER_ADDRESS="${WG_PEER_ADDRESS:-}"
WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"
WG_SERVER_PUBLIC_KEY="${WG_SERVER_PUBLIC_KEY:-}"

wg_field() {
  [[ -r ${WG_META} ]] || return 0
  sed -n "s/^$1=//p" "${WG_META}" | head -n 1
}

wg_valid_ip() {
  local address="$1" octet
  local -a octets
  [[ ${address} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"${address}"
  for octet in "${octets[@]}"; do ((10#${octet} <= 255)) || return 1; done
}

# Represent an IPv4 address as an unsigned 32-bit integer, for overlay boundary checks.
wg_ip_number() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d} ))
}

wg_overlay_ip() {
  wg_valid_ip "$1" || return 1
  local network="${WG_SERVER_CIDR%/*}" prefix="${WG_SERVER_CIDR#*/}" mask
  wg_valid_ip "${network}" || return 1
  [[ ${prefix} =~ ^[0-9]+$ ]] || return 1
  ((10#${prefix} >= 8 && 10#${prefix} <= 30)) || return 1
  mask=$(( (0xffffffff << (32 - 10#${prefix})) & 0xffffffff ))
  (( ($(wg_ip_number "$1") & mask) == ($(wg_ip_number "${network}") & mask) ))
}

wg_valid_key() {
  [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

wg_valid_name() {
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$ ]]
}

wg_valid_endpoint() {
  # An IPv4 address or DNS name, optionally with a non-default UDP port.
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$ ]] || return 1
  local port="${1##*:}"
  ((10#${port} >= 1 && 10#${port} <= 65535))
}

wg_managed() {
  [[ -f ${WG_FILE} ]] && grep -q '^# Managed by hostctl' "${WG_FILE}"
}

wg_prepare() {
  command -v apt-get >/dev/null || die "WireGuard requires an Ubuntu host"
  DEBIAN_FRONTEND=noninteractive apt-get install -yq wireguard-tools iproute2 iputils-ping >/dev/null
  install -d -m 0700 "${WG_DIR}" "${CONFIG_DIR}"
  if [[ -f ${WG_FILE} ]] && ! wg_managed; then
    die "${WG_FILE} exists but was not created by hostctl; refusing to overwrite it"
  fi
  if [[ ! -f ${WG_KEY_FILE} ]]; then
    (umask 077; wg genkey >"${WG_KEY_FILE}")
  fi
  chmod 0600 "${WG_KEY_FILE}"
  # Docker's host-networked Portainer processes rely on a default-deny host firewall.
  # hostctl has already installed and allow-listed SSH before calling component setup.
  ufw --force enable >/dev/null
  ufw default deny incoming >/dev/null
  grep -q 'Default: deny (incoming)' <(ufw status verbose) ||
    die "ufw incoming policy is not deny; refusing to run Portainer"
}

wg_public_key() {
  [[ -r ${WG_KEY_FILE} ]] || die "no WireGuard key yet; initialize this host first"
  wg pubkey <"${WG_KEY_FILE}"
}

wg_private_ip() {
  wg_field ADDRESS
}

wg_role() {
  wg_field ROLE
}

wg_available() {
  local address="${1:-$(wg_private_ip)}"
  [[ -n ${address} ]] || return 1
  ip -o -4 addr show dev "${WG_IFACE}" 2>/dev/null | grep -Fq "inet ${address}/" &&
    wg show "${WG_IFACE}" >/dev/null 2>&1
}

wg_enable() {
  systemctl enable --now "wg-quick@${WG_IFACE}" >/dev/null ||
    die "WireGuard didn't start: journalctl -u wg-quick@${WG_IFACE}"
  wg_available || die "WireGuard interface ${WG_IFACE} is not ready"
}

wg_save_meta() {
  local role="$1" address="$2"
  (umask 077; printf 'ROLE=%s\nADDRESS=%s\n' "${role}" "${address}" >"${WG_META}.new")
  mv "${WG_META}.new" "${WG_META}"
}

wg_init_server() {
  [[ ${WG_PORT} =~ ^[0-9]+$ ]] && ((10#${WG_PORT} >= 1 && 10#${WG_PORT} <= 65535)) ||
    die "WG_PORT must be a UDP port from 1 to 65535"
  wg_prepare
  if [[ -f ${WG_FILE} ]]; then
    [[ $(wg_role) == server ]] || die "WireGuard is already configured for another role"
  else
    local address="${WG_SERVER_CIDR%/*}"
    wg_valid_ip "${address}" || die "invalid server address"
    [[ ${WG_SERVER_CIDR#*/} =~ ^[0-9]+$ ]] || die "invalid server prefix"
    ((10#${WG_SERVER_CIDR#*/} >= 8 && 10#${WG_SERVER_CIDR#*/} <= 30)) ||
      die "server prefix must be between /8 and /30"
    {
      printf '# Managed by hostctl; do not edit by hand.\n[Interface]\nAddress = %s\n' "${WG_SERVER_CIDR}"
      printf 'ListenPort = %s\nPrivateKey = %s\n' "${WG_PORT}" "$(<"${WG_KEY_FILE}")"
    } >"${WG_FILE}"
    chmod 0600 "${WG_FILE}"
    wg_save_meta server "${address}"
  fi
  # Limit publicly reachable management traffic to the WireGuard handshake.
  ufw allow "${WG_PORT}/udp" comment "WireGuard management tunnel" >/dev/null
  wg_enable
  note "WireGuard server $(wg_private_ip) (UDP ${WG_PORT}); public key: $(wg_public_key)"
}

wg_init_node() {
  wg_prepare
  if [[ -f ${WG_FILE} ]]; then
    [[ $(wg_role) == node ]] || die "WireGuard is already configured for another role"
  else
    note "This node's WireGuard public key: $(wg_public_key)"
    if [[ -z ${WG_PEER_ADDRESS} || -z ${WG_SERVER_ENDPOINT} || -z ${WG_SERVER_PUBLIC_KEY} ]]; then
      die "enroll this public key on the server with 'sudo networkctl add-peer <name> <address> <public-key>', then rerun with WG_PEER_ADDRESS, WG_SERVER_ENDPOINT and WG_SERVER_PUBLIC_KEY (see network/README.md)"
    fi
    wg_overlay_ip "${WG_PEER_ADDRESS}" || die "WG_PEER_ADDRESS must be within ${WG_SERVER_CIDR}"
    [[ ${WG_PEER_ADDRESS} != "${WG_SERVER_ADDRESS}" ]] || die "node and server addresses must differ"
    wg_valid_endpoint "${WG_SERVER_ENDPOINT}" || die "invalid WG_SERVER_ENDPOINT (use public-ip:51820)"
    wg_valid_key "${WG_SERVER_PUBLIC_KEY}" || die "invalid WG_SERVER_PUBLIC_KEY"
    wg_valid_ip "${WG_SERVER_ADDRESS}" || die "invalid WG_SERVER_ADDRESS"
    {
      printf '# Managed by hostctl; do not edit by hand.\n[Interface]\nAddress = %s/32\n' "${WG_PEER_ADDRESS}"
      printf 'PrivateKey = %s\n\n[Peer]\nPublicKey = %s\n' "$(<"${WG_KEY_FILE}")" "${WG_SERVER_PUBLIC_KEY}"
      printf 'AllowedIPs = %s/32\nEndpoint = %s\nPersistentKeepalive = 25\n' "${WG_SERVER_ADDRESS}" "${WG_SERVER_ENDPOINT}"
    } >"${WG_FILE}"
    chmod 0600 "${WG_FILE}"
    wg_save_meta node "${WG_PEER_ADDRESS}"
  fi
  wg_enable
  # A configured interface is not enough: require a genuine, recent authenticated handshake.
  local handshake tries
  for ((tries=0;tries<10;tries++)); do
    # Send traffic to initiate the first tunnel handshake; an idle tunnel has none.
    ping -n -c 1 -W 1 "${WG_SERVER_ADDRESS}" >/dev/null 2>&1 || true
    handshake="$(wg show "${WG_IFACE}" latest-handshakes | awk 'NR==1 { print $2 }')"
    if [[ ${handshake} =~ ^[0-9]+$ ]] && ((handshake > 0 && $(date +%s) - handshake < 180)); then
      note "WireGuard node $(wg_private_ip): authenticated tunnel established"
      return 0
    fi
    sleep 2
  done
  die "no WireGuard handshake with server; verify its peer registration and UDP ${WG_PORT} reachability. Portainer agent was not started"
}

wg_add_peer() {
  [[ $(wg_role) == server ]] || die "add-peer only runs on the WireGuard server"
  [[ $# -eq 3 ]] || die "usage: networkctl add-peer <name> <VPN-address> <public-key>"
  local name="$1" address="$2" key="$3"
  wg_valid_name "${name}" || die "invalid peer name"
  wg_overlay_ip "${address}" || die "peer address must be within ${WG_SERVER_CIDR}"
  wg_valid_key "${key}" || die "invalid WireGuard public key"
  [[ ${address} != "$(wg_private_ip)" ]] || die "peer address conflicts with server"
  if grep -Fqx "# Peer: ${name}" "${WG_FILE}" ||
    grep -Fqx "AllowedIPs = ${address}/32" "${WG_FILE}" ||
    grep -Fqx "PublicKey = ${key}" "${WG_FILE}"; then
    die "peer name, address or key already registered"
  fi
  local backup
  backup="$(mktemp)"
  cp -p "${WG_FILE}" "${backup}"
  {
    printf '\n# Peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "${name}" "${key}" "${address}"
  } >>"${WG_FILE}"
  if ! wg syncconf "${WG_IFACE}" <(wg-quick strip "${WG_IFACE}"); then
    cp -p "${backup}" "${WG_FILE}"
    rm -f "${backup}"
    die "could not apply peer; configuration restored"
  fi
  rm -f "${backup}"
  note "registered ${name} at ${address}"
  note "node inputs: WG_PEER_ADDRESS=${address} WG_SERVER_ENDPOINT=<this-server-public-ip>:${WG_PORT} WG_SERVER_PUBLIC_KEY=$(wg_public_key)"
}

wg_remove_peer() {
  [[ $(wg_role) == server ]] || die "remove-peer only runs on the server"
  if [[ $# -ne 1 ]] || ! wg_valid_name "$1"; then
    die "usage: networkctl remove-peer <name>"
  fi
  grep -Fqx "# Peer: $1" "${WG_FILE}" || die "peer not found"
  local tmp
  tmp="$(mktemp --suffix=.conf)"
  awk -v target="# Peer: $1" '
    /^# Peer: / { drop=($0==target) }
    !drop { print }
  ' "${WG_FILE}" >"${tmp}"
  chmod 0600 "${tmp}"
  if ! wg syncconf "${WG_IFACE}" <(wg-quick strip "${tmp}"); then
    rm -f "${tmp}"
    die "could not revoke peer"
  fi
  cat "${tmp}" >"${WG_FILE}"
  rm -f "${tmp}"
  note "revoked $1"
}

wg_check() {
  if ! grep -q 'Default: deny (incoming)' <(ufw status verbose); then
    record FAIL "WireGuard firewall" "ufw incoming policy is not default-deny" fix
  else
    record PASS "WireGuard firewall" "default deny incoming"
  fi
  if wg_available; then
    record PASS "WireGuard" "${WG_IFACE} $(wg_private_ip)"
  else
    record FAIL "WireGuard" "private management tunnel unavailable" fix
  fi
}

# Replace all rules for this management port, including old public/vRack rules, with VPN-only
# rules. Delete before adding to avoid a window when broad public access is still possible.
wg_set_port_sources() {
  local port="$1" comment="$2" number source
  shift 2
  local rules
  rules="$(ufw status numbered | awk -v port="${port}" '
    index($0, "[") == 1 && index($0, "]") > 0 {
      close_pos=index($0, "]")
      n=substr($0, 2, close_pos - 2); gsub(/ /, "", n)
      line=substr($0, close_pos + 1); sub(/^[[:space:]]+/, "", line)
      if ((index(line, port "/tcp ") == 1 || index(line, port " ") == 1) &&
          index(line, "ALLOW") > 0) print n
    }' | sort -rn)"
  while IFS= read -r number; do
    [[ -z ${number} ]] || ufw --force delete "${number}" >/dev/null
  done <<<"${rules}"
  for source in "$@"; do
    wg_valid_ip "${source}" || die "expected an individual WireGuard IPv4 source, got '${source}'"
    ufw allow in on "${WG_IFACE}" proto tcp from "${source}" to any port "${port}" comment "${comment}" >/dev/null
  done
}

wg_check_port_sources() {
  local port="$1" name="$2" expected="$3" source line actual=""
  local matched=0 bad=0
  local status
  status="$(ufw status)"
  while IFS= read -r line; do
    [[ ${line} =~ ^${port}(/tcp)?[[:space:]] ]] || continue
    [[ ${line} == *"ALLOW"* ]] || continue
    if [[ ${line} == *" on ${WG_IFACE}"* && ${line} != *"Anywhere"* ]]; then
      source="$(awk -F '  +' '{print $3}' <<<"${line}" | sed 's/[[:space:]]*#.*//')"
      if [[ -n ${source} ]]; then
        actual="${actual:+${actual} }${source}"
        matched=$((matched+1))
      else
        bad=$((bad+1))
      fi
    else
      bad=$((bad+1))
    fi
  done <<<"${status}"
  if ((bad>0 || matched==0)) || [[ "$(tr ' ' '\\n' <<<"${expected}" | sort -u)" != "$(tr ' ' '\\n' <<<"${actual}" | sort -u)" ]]; then
    record FAIL "${name}" "unsafe or incorrect TCP ${port} rules; require only ${expected} on ${WG_IFACE}" fix
  else
    record PASS "${name}" "only ${expected} on ${WG_IFACE}"
  fi
}
