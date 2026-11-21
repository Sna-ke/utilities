# Portainer: control plane and nodes

Two components that set up [Portainer](https://www.portainer.io/) Community Edition on Ubuntu 24.04 VMs:

| Component | Install it on | What it runs |
| --- | --- | --- |
| `portainer-server` | The VM that hosts the control plane (for now, the GitHub runner VM) | Portainer's web UI and API |
| `portainer-node` | Each VM that runs your apps (MealPlan, GroundCore) | Portainer's agent, which lets the server manage that VM's Docker |

The hardening, Docker, alerts, audit, weekly update and `hostctl` come from the shared [host tools](../host/README.md);
this folder adds Portainer and `portainerctl`. A VM is either the server or a node, not both.

| File | What it is |
| --- | --- |
| `portainer-lib.sh` | Both components: the private network, firewall rules, containers, backups, Portainer's API, doctor checks, hooks |
| `portainerctl.sh` | The command, installed as `/usr/local/bin/portainerctl` on the server and on every node |
| `tests/portainer-test.sh` | Tests the parsing and decisions against sample input |

## Secure overlay on ordinary OVH VPS instances

**No vRack, private OVH network, or extra network card is needed.** The installer configures the
self-managed WireGuard `wg0` interface over each VPS's existing public IP connection.

- Server listens on UDP 51820 and exposes the Portainer UI on TCP 9443 **only to registered administrator
  WireGuard peers** (default administrator VPN address `10.70.0.10`).
- Every node creates its own WireGuard key pair. Portainer agent 9001 is authorized on `wg0` only
  from the server (default VPN address `10.70.0.1`).
- Node installation stops before starting Portainer until the server has enrolled the node and a real
  authenticated WireGuard handshake succeeds.
- All keys remain on their owning host. Enrollment needs a trusted exchange of **public keys** over
  your existing administrative SSH connection.

### Install server

```bash
curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/feature/wireguard-vps-management/host/install.sh |
  sudo TOOLS_BRANCH=feature/wireguard-vps-management bash -s -- portainer-server
```

The command prints the server public key and initializes WireGuard. To access the UI, enroll a WireGuard
client on your laptop at `10.70.0.10` using `sudo networkctl add-peer admin-mac 10.70.0.10 <laptop-public-key>`,
then open `https://10.70.0.1:9443` over the tunnel. There is **no public UI access** by default.

### Install node (two-stage, securely enrolled)

Run the same one-line installer with `portainer-node` on the node. It prints a new node public key
and stops until the server enrolls that key. On the server:

```bash
sudo networkctl add-peer groundcore 10.70.0.2 <node-public-key>
sudo networkctl public-key
```

Now rerun the node installer with `WG_PEER_ADDRESS=10.70.0.2`,
`WG_SERVER_ENDPOINT=<server-public-ip>:51820`, and `WG_SERVER_PUBLIC_KEY=<server-public-key>`
in the **sudo environment**. See [network/README.md](../network/README.md) for the exact example and security
details. Afterwards, on the server:

```bash
sudo portainerctl add-node groundcore 10.70.0.2
```

Node addresses must be unique. The WireGuard tunnel remains available when Portainer is removed, allowing
other utilities to reuse it.

## `portainerctl`

| Command | Runs on | What it does | sudo |
| --- | --- | --- | --- |
| `add-node <name> <private IP>` | Server | Checks the node's agent answers, then adds it to Portainer | Yes |
| `remove-node <name>` | Server | Removes a node from Portainer; its containers keep running | Yes |
| `nodes` | Server | Each node's address and whether Portainer can reach it | Yes |
| `allow-ip [address...]` | Server | Sets who may open the UI, replacing the list (your home IP changed). No address: asks | Yes |
| `secret` | Server | Prints the agent secret, to paste when installing a node | Yes |
| `backup [file]` | Server | Backs up Portainer's data and settings (see Backups) | Yes |
| `restore <file>` | Server | Replaces Portainer's data with a backup's; the current data is moved aside | Yes |
| `init-admin` | Server | Creates the admin user, if setup couldn't (no terminal) | Yes |
| `set-server [private IP]` | Node | The server moved to a new address: lets only the new one reach the agent | Yes |
| `set-secret` | Node | Replaces the agent secret and restarts the agent | Yes |
| `status` | Either | Container, version, addresses, who is let in | No (details: yes) |
| `upgrade` | Either | Newest image of the tag now; the weekly update does this too | Yes |
| `remove` | Either | Removes the container and its management firewall rules; preserves Portainer data, backups and the reusable WireGuard tunnel | Yes |

`doctor`, `audit`, `update`, `prune`, `version` and `self-update` run `hostctl`'s, for the whole host. The commands
that change the firewall check the audit first and accept their own change afterwards, so the daily audit doesn't
report them but still reports anything else.

Admin commands ask for the admin password each time; nothing stores it.

## What `hostctl doctor` checks

| Check | Server | Node | PASS when |
| --- | --- | --- | --- |
| Private network | Yes | Yes | The authenticated WireGuard `wg0` interface is active |
| Portainer server / node | Yes | Yes | The container runs the current settings |
| Portainer UI access | Yes | | Port 9443 accepts only administrator VPN peers on `wg0` |
| Portainer HTTPS only | Yes | | Neither plain HTTP (9000) nor the Edge tunnel (8000) listens on the network |
| Portainer admin | Yes | | The admin user exists |
| Portainer backup | Yes | | A backup from the last 8 days |
| Portainer agent access | | Yes | Port 9001 accepts only the server's VPN address on `wg0` |
| Portainer agent answers | | Yes | The agent answers on the private address |

`hostctl doctor --fix` runs setup again for what it fixes (a stopped or outdated container, firewall rules, the
private address and WireGuard firewall).

## Updates

| What | When | How |
| --- | --- | --- |
| Packages, Docker | Weekly (host tools) | Docker's live-restore keeps your apps running while it restarts |
| Portainer server and agents | Same weekly run | Each VM pulls the `lts` tag and replaces its container if the image changed. The server is backed up first. Server and agents follow the same tag, so they stay in step |
| These scripts | `sudo hostctl self-update` | See the [host tools](../host/README.md#updating) |

Replacing the agent doesn't touch your app containers. To stay on a fixed version instead of `lts`, set
`PORTAINER_SERVER_IMAGE` and `PORTAINER_AGENT_IMAGE` when running setup (e.g. `portainer/portainer-ce:2.33.3`).

## Backups

| What | Where |
| --- | --- |
| Portainer's data (users, settings, stacks, environments) and the two settings files | `/var/backups/portainer/portainer-<date>.tar.gz`, root only |
| When | `sudo portainerctl backup`, and automatically before every upgrade. The newest 8 are kept |
| Note | A backup holds the agent secret: keep copies private |

Portainer stops for a few seconds while it's backed up, so the database is consistent. Your apps on the nodes keep
running.

Copy backups off the VM now and then (`scp`), so losing the VM doesn't lose them.

## Moving the server to another VM

A WireGuard server move is **not** the same as moving a vRack address. Portainer's own database
can be restored with `sudo portainerctl backup`, but the WireGuard **server identity**, peer
configurations, and nodes' authenticated `Endpoint` values are outside that Portainer backup.
Do not run the old vRack migration commands.

For now, plan a managed migration: securely back up the server's root-only `/etc/wireguard/`
and `/etc/hostctl/wireguard.conf`, restore the Portainer data to the new VM, retain or
re-enroll each WireGuard peer, update nodes' public server endpoint if the public IP changes,
and verify authenticated handshakes and `sudo portainerctl nodes` before cutting over.
This feature branch does **not** automate management-plane migration.

## Your apps on the nodes

Docker on every host publishes ports on `127.0.0.1` unless a container says otherwise, because Docker's published
ports bypass ufw. For what the internet should reach, usually a reverse proxy's 80 and 443, publish on all addresses
explicitly (`0.0.0.0:443:443` in the stack). The daily audit then lists the new open port once: check it's yours,
then `sudo hostctl audit --accept`. Everything else talks over Docker networks inside the node.

## Security

| Protection | How |
| --- | --- |
| UI | HTTPS only; reachable from enrolled administrator addresses **over WireGuard**. Admin password at least 12 characters, never stored |
| First start | Portainer accepts its admin user only within 5 minutes of starting, and here only with a one-time setup token from a root-only file, so nobody can claim it before you |
| Agents | Bind to their assigned WireGuard address; UFW allows TCP 9001 from the server over `wg0` only. Requests must also use the agent secret |
| Secrets | The agent secret and setup token are in `/etc/hostctl/portainer.env` (root only), passed with `--env-file` so they're never on a command line |
| The server can't touch its own VM | It doesn't mount the Docker socket: it manages the nodes, not the VM it runs on |
| Data | `/var/lib/portainer`, a folder rather than a Docker volume, so no clean-up can delete it |
| Agents | No host management (it would mount the node's whole filesystem) |

**Limits.**

1. The agent gives the server full control of each node's Docker, which is root on that node: whoever controls the
   server, or knows the agent secret and reaches a node's private address, controls the nodes. Keep the admin
   password strong and the secret private.
2. On the runner VM, CI jobs can run Docker as root, so they can read the agent secret and control the server.
   Your repositories are private and only you push to them, so this is acceptable for now; moving the server to
   its own VM (above) removes it.
3. If the server VM is compromised, rebuild it (see the [host tools](../host/README.md#if-the-vm-is-compromised)),
   then restore an older backup you trust, or start fresh. Either way, set a new agent secret: edit
   `AGENT_SECRET` in `/etc/hostctl/portainer.env` (64 random hex characters: `openssl rand -hex 32`), run
   `sudo portainerctl upgrade` to restart Portainer with it, and run
   `sudo portainerctl set-secret` on each node.

## Settings

Setup asks for these; set them as environment variables to answer in advance (e.g. no terminal).

| Variable | Component | Meaning |
| --- | --- | --- |
| `WG_SERVER_CIDR`, `WG_PORT` | Server | Private management network and public UDP handshake port (defaults `10.70.0.1/24`, `51820`) |
| `WG_ADMIN_ADDRESS`, `PORTAINER_HOME_IP` | Server | WireGuard administrator address (default `10.70.0.10`); optional allowed administrator addresses on `wg0` |
| `PORTAINER_RESTORE` | Server | Full path of a backup to start from (only when there's no data yet) |
| `WG_PEER_ADDRESS`, `WG_SERVER_ENDPOINT`, `WG_SERVER_PUBLIC_KEY` | Node | Node VPN address, server public internet endpoint, and authenticated server public key; required on enrollment |
| `PORTAINER_AGENT_SECRET` | Node | The agent secret (pasting it when asked keeps it out of your shell history) |
| `PORTAINER_SERVER_IMAGE`, `PORTAINER_AGENT_IMAGE` | Server, node | Images; default the `lts` tag |

Answers are kept in `/etc/hostctl/portainer.conf` (root only); running setup again offers them as defaults.

## Testing

| What | Where it runs |
| --- | --- |
| ShellCheck | CI (`.github/workflows/shellcheck.yml`) |
| Settings files, addresses, UFW rules, listeners, containers, backups/restore, API responses and component plumbing | CI (`.github/workflows/portainer-tests.yml`), or `bash portainer/tests/portainer-test.sh` |
| WireGuard peer and firewall regression tests | CI (`.github/workflows/wireguard-tests.yml`) or `bash network/tests/wireguard-test.sh` |
| Docker, UFW, WireGuard tunnel, Portainer API and agent | Real-VM validation required before production use |
