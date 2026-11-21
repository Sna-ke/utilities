# Private management overlay (WireGuard; no OVH vRack)

Every ordinary OVH VPS retains its **public** NIC. This component creates an encrypted, authenticated
management network on `wg0`. No second NIC, vRack subscription, or OVH Public Cloud instance is necessary.

- Server: `10.70.0.1/24`, listens for WireGuard handshakes on UDP 51820.
- Nodes: unique key pairs and addresses, e.g. `10.70.0.2/32`. Only a route to the server is added;
  application internet traffic continues through its regular public interface.
- Portainer HTTPS 9443 is reachable only over `wg0`; agent TCP 9001 only from the server over `wg0`.
  Docker management ports are not published on public addresses.
- An administrator's laptop may join the same VPN with its own WireGuard identity; enroll it as a peer
  like an application node. No administrator private key should be copied to the VPS.

## Enrolling a node (two-stage, authenticated)

A newly installed node **stops before starting the Portainer agent** until enrollment succeeds.

1. Run the regular `portainer-node` installer on the node. It generates a local key pair and prints
   the **public** key; the installer stops safely with enrollment instructions.
2. On the server: `sudo networkctl add-peer groundcore 10.70.0.2 <node-public-key>`.
3. On the server: `sudo networkctl public-key`. Record the server's actual public IP and WireGuard
   public key **through your existing SSH session**, not via an untrusted message.
4. On the node, rerun the original installer with these environment variables **passed to sudo bash**
   (substitute actual values). They are not secrets:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/feature/wireguard-vps-management/host/install.sh |
     sudo TOOLS_BRANCH=feature/wireguard-vps-management \
       WG_PEER_ADDRESS=10.70.0.2 WG_SERVER_ENDPOINT=203.0.113.10:51820 \
       WG_SERVER_PUBLIC_KEY=<server-public-key> bash -s -- portainer-node
   ```
   The node requires a recent authenticated WireGuard handshake before installing Portainer.
5. On the server: `sudo portainerctl add-node groundcore 10.70.0.2`.

Use `sudo networkctl status` to inspect the tunnel, and `sudo networkctl remove-peer groundcore` to
revoke a peer. **Do not install unreviewed or unauthenticated configuration files or pass a WireGuard
private key over the command line.**

## Administrator access

Enroll an administrator-owned WireGuard key pair (generated on their own device) as an additional
server peer, e.g. `sudo networkctl add-peer admin-mac 10.70.0.10 <laptop-public-key>`.
Configure that device's WireGuard tunnel with `AllowedIPs = 10.70.0.1/32`, the authenticated
server public key, the server's public IP/51820 and its own private key. Open the Portainer UI
at `https://10.70.0.1:9443` after connecting the VPN. The self-signed certificate still requires
fingerprint verification. Use unique addresses for every peer.

## Recovery and constraints

- WireGuard keys and `wg0.conf` are root-only under `/etc/wireguard`. They survive Portainer updates.
- The VPN is **not** an OVH private NIC. Only UDP 51820 crosses the public internet for management.
- A Portainer node that cannot establish a WireGuard handshake fails closed, rather than exposing
  its agent over the public interface.
- Existing vRack-configured Portainer servers require a planned migration. This change does not
  automatically import vRack configuration or preserve existing node IP assignments.
- Protect external SSH using your existing hostctl policies and OVH cloud firewall. Backup the server's
  WireGuard configuration securely alongside Portainer's state.
