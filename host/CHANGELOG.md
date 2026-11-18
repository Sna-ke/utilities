# hostctl changelog

`hostctl version` shows the installed version, and `hostctl self-update` lists the lines below that are newer
than it. The version is `TOOLS_VERSION` in `host/host-lib.sh` (`GHRUNNER_VERSION` in `github-runner/runner-lib.sh`
before 2.0.0). It covers every script in `host/` and the component folders: every pull request that changes one
raises it and adds a line here, newest first; CI checks both.

| Version | Date | Changes |
| --- | --- | --- |
| 2.1.0 | 2026-11-17 | Portainer: components `portainer-server` (the control plane) and `portainer-node` (a Docker host with the agent), and `portainerctl`. The UI is HTTPS-only and lets in only the addresses you allow; each agent listens on its private (vRack) address and lets in only the server. Backups, restore and moving the server to another VM. A new `upgrade` hook: the weekly update brings Portainer to the newest image of its tag |
| 2.0.0 | 2026-11-17 | The hardening, audit, alerts, weekly update, `doctor` and `self-update` move from `github-runner/` to a shared `host/` layer with its own command, `hostctl`, so other components (Portainer next) can use them. The GitHub runner becomes a component; `ghrunner` keeps its commands and passes host-wide ones to `hostctl`. One installer for all components: `host/install.sh`. Docker keeps containers running through daemon restarts (live-restore). Hosts on 1.x move to the new layout on their next update |
| 1.5.0 | 2026-11-17 | `doctor` checks every lockdown item (SSH port, root and `runner` login, tries; firewall only SSH and rate-limited; kernel network settings; daily security updates; Docker on 127.0.0.1; alerts). `doctor --fix` runs the installed setup again for what it fixes. Alerts go to Pushover instead of a URL. Kernel settings the kernel lacks (IPv6 off) are skipped |
| 1.4.0 | 2026-11-17 | Hardening: SSH port asked each run (moved only after you confirm), root and `runner` can't log in, rate-limited firewall, kernel network settings. Weekly full update that waits for idle runners and warns about a waiting kernel. Daily audit against a baseline, shown at login, in `doctor` and as optional alerts; setup stops if it finds unaccepted changes. Public repositories refused. One-line installer (`install.sh`) |
| 1.3.0 | 2026-11-17 | Version numbers: `ghrunner version`, `self-update`, `doctor` and `help` show them, and `self-update` lists this changelog |
| 1.2.0 | 2026-11-17 | `ghrunner self-update` and `ghrunner version`. Removed the `/usr/share/dotnet` step, replaced by `DOTNET_INSTALL_DIR` in 1.1.0 |
| 1.1.0 | 2026-11-17 | Each runner's `.env` points `setup-dotnet`, `setup-python` and `setup-ruby` at writable folders. `ghrunner resize`; sizing counts cores |
| 1.0.0 | 2026-11-17 | The `ghrunner` command, and `runner-lib.sh` shared with `setup-runner.sh` |
