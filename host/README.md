# Host tools: hardening, audit, updates and `hostctl`

Everything a VM here gets, whatever it runs: SSH and firewall hardening, Docker, Pushover alerts, a daily audit, a
weekly update, and `hostctl` to look after it all. Components add what the VM is for:

| Component | Folder | What it adds |
| --- | --- | --- |
| `github-runner` | [`github-runner/`](../github-runner/README.md) | GitHub Actions self-hosted runners, and `ghrunner` |
| `portainer-server` | [`portainer/`](../portainer/README.md) | The Portainer control plane (web UI), and `portainerctl` |
| `portainer-node` | [`portainer/`](../portainer/README.md) | A Docker host Portainer manages through its agent, and `portainerctl` |

| File | What it is |
| --- | --- |
| `install.sh` | The one-line installer: downloads and checks the scripts, asks for a token if a component needs one, runs setup, cleans up |
| `setup-host.sh` | Sets up the host, then the components (run again to repair or update; every step is safe to repeat) |
| `hostctl.sh` | The command, installed as `/usr/local/bin/hostctl` |
| `host-lib.sh` | Code every script shares, including the hooks components plug into |
| `CHANGELOG.md` | What changed in each version |

## Install

On a fresh Ubuntu 24.04 VM with your SSH key, logged in as your admin user:

```sh
curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/host/install.sh | sudo bash -s -- <component>
```

| Question | Answer |
| --- | --- |
| GitHub token (github-runner only) | See the runner's README, or Enter to paste tokens as you go |
| SSH port | Enter for the suggested one (9452 on a new VM; afterwards, the current one) |
| Did the new port work? | Open a second terminal, log in with the `ssh -p` command it shows, then answer. Port 22 closes only after a yes |
| Pushover user key | From pushover.net once you log in, or Enter for no alerts |
| Pushover application token | Create an application at pushover.net/apps/build (any name). Setup checks both with Pushover and sends a test alert |

Several components can share a host: run the line again with another component, or name several at once (but a VM is
either the Portainer server or a node, not both). To try a
branch before merging it: `curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/<branch>/host/install.sh | sudo TOOLS_BRANCH=<branch> bash -s -- <component>`.

## What setup does

| Step | Result |
| --- | --- |
| Audit first | On a host set up before, stops if anything changed that nobody accepted, so an update can't bless a tampered machine |
| System | Updated. Security updates daily; a full update weekly (see Security) |
| SSH | Keys only, on the port you choose (9452 suggested) |
| Firewall | ufw: SSH in (rate-limited), plus only the ports a component needs |
| Kernel network settings | Ignores ICMP redirects and source routing, sends no redirects, hides kernel addresses |
| Alerts | Optional: Pushover notifications to your phone |
| Swap | 4 GB on machines under 10 GB of RAM (`SWAP_SIZE_GB`) |
| Docker | Docker Engine and Compose from Docker's apt repository. Published ports bind to 127.0.0.1, because Docker's port rules bypass ufw. Containers keep running when Docker restarts (live-restore). Logs capped |
| Clean-up | Weekly, logged to the journal. On a CI host: images, build cache and volumes. Otherwise: old images and build cache only, **never volumes**, which hold data |
| `hostctl` | `/usr/local/lib/hostctl/` holds the scripts (same layout as this repository) and `VERSION`, the commit they came from |
| Components | Each component's own steps |
| Baseline | What the machine looks like now, for the daily audit |

## `hostctl`

| Command | What it does | sudo |
| --- | --- | --- |
| `hostctl doctor [--fix]` | Checks the host and its components. Prints PASS/WARN/FAIL and exits 1 on any FAIL. `--fix` runs the installed setup again when a problem is one it fixes, then checks again | No (`--fix`: yes) |
| `hostctl audit [--accept]` | Lists what changed since the audit baseline (see Security). `--accept` makes the current state the baseline, after you've checked the changes are yours | Yes |
| `hostctl update [--scheduled]` | Upgrades every package (Docker's too), never reboots, and warns when a new kernel waits for one; then each component upgrades its own software (Portainer: the newest image of its tag) and reports. `--scheduled` is the weekly timer: components pause their work first | Yes |
| `hostctl prune` | Runs the weekly clean-up now and shows the space freed | Yes |
| `hostctl version` | The installed version and commit, the components, the latest on `main`, and whether they match | No |
| `hostctl self-update [--yes]` | Updates to the latest `main`, after listing what changed (see Updating) | Yes |
| `hostctl help` | Lists the commands | No |

### What `doctor` checks

| Check | Passes when | `--fix` fixes it |
| --- | --- | --- |
| Disk free | 20% or more free on `/` (warns under 20%, fails under 10%) | No: `sudo hostctl prune` |
| Docker | Running | No |
| Docker ports | Published ports bind to 127.0.0.1 | Yes |
| Scheduled jobs | Clean-up, weekly update and daily audit are on, and didn't fail last time | Yes |
| Security updates | Daily unattended upgrades on | Yes |
| Firewall | On, letting in only SSH (rate-limited) and the components' ports | Yes |
| SSH | Keys only, one port and not 22, root and the components' service accounts can't log in, 3 tries at most | Yes (asks for the port) |
| Kernel settings | The hardened network settings are in force | Yes |
| Alerts | Pushover set up | Yes (asks for the key and token) |
| Audit | Ran in the last 2 days with no unaccepted changes | No: `sudo hostctl audit` |
| Kernel | Running the newest installed kernel | No: `sudo reboot` |
| Reboot pending | No reboot pending | No: `sudo reboot` |
| Swap | On, below 10 GB of memory | Yes |
| Each component's checks | See the component's README | Varies |
| hostctl version | Same as `main` | No: `sudo hostctl self-update` |

Without sudo, the firewall rules and the alert settings aren't checked.

## Security

| Protection | How |
| --- | --- |
| SSH | Keys only. Port of your choice. Root can't log in when another admin user has a key. The `runner` user can't log in. 3 tries per connection, 30 seconds to log in. No X11 or agent forwarding |
| Moving the SSH port safely | Setup listens on both ports, asks you to log in on the new one from a second terminal, and closes the old one only after you say it worked. Without a terminal, it never changes the port |
| Firewall | ufw allows only the SSH port, and blocks an address after 6 connection attempts in 30 seconds. Docker publishes ports on 127.0.0.1 only, because its rules bypass ufw |
| Updates | Ubuntu's security updates daily. A full update (Docker included) weekly, Sunday 11:00 UTC (`UPDATE_SCHEDULE`): components pause their work first (the runner waits until no job runs), and Docker's live-restore keeps containers running while it restarts. It never reboots: a waiting kernel shows at login, in `doctor`, and as an alert |
| Audit | Setup records a baseline: accounts, SSH keys, sudo rules, SSH settings, firewall rules, ports open to the outside, cron jobs, services that start at boot, setuid programs, hostctl's own files, and where SSH logins come from. A timer compares the machine with it daily |
| Hearing about it | Audit findings and a waiting kernel show at every SSH login and in `hostctl doctor`, and go to Pushover if you set it up (once per new set of findings, not daily). Audit alerts are high priority, so they sound even in quiet hours. The key and token are kept in `/etc/hostctl/pushover`, readable by root only |
| Updates can't bless a compromise | Setup, and so `self-update`, checks the audit first and stops if anything changed that nobody accepted |

**Limits.** Someone with root on the VM can hide from the audit; it catches mistakes and careless intruders, not a
careful one. That is why a compromised VM is rebuilt rather than cleaned. On a GitHub runner host, CI jobs run as
root (Docker and sudo): anything else on that VM, such as a Portainer control plane, is only as safe as the code
those jobs run.

**After a change you made** (a new SSH key, a package that adds a service), the next audit lists it: check it's
yours, then run `sudo hostctl audit --accept`. A login from a new address (your home IP changed, a phone hotspot)
shows up the same way.

## If the VM is compromised

Signs: an audit finding you didn't make (a new key, user, sudo rule, open port, cron job or service), hostctl's files
changed, or anything else you can't explain. Don't try to clean it:

1. Stop using it. Don't type passwords or tokens into it.
2. In the OVH control panel, reinstall the VPS with Ubuntu 24.04 and your SSH key. This wipes the disk.
3. Assume anything jobs could read was taken, and replace it:
   1. Each repository's Actions secrets (Settings > Secrets and variables > Actions), and whatever they unlock.
   2. The GitHub token, if you used one on that VM.
   3. Portainer's admin password and agent secret, if the VM ran the control plane.
4. Check each repository for things you didn't do: commits, workflow files, releases, deploy keys and webhooks.
5. Run the one-line install for the same components (Install, below). Each component's README says what else to
   check: GitHub runners re-register under their old names; Portainer nodes need the control plane's agent secret.
6. Run `hostctl doctor`.

## Updating

```sh
read -rsp "Token: " GITHUB_TOKEN && export GITHUB_TOKEN   # runner hosts: so nothing stops to ask for one
sudo --preserve-env=GITHUB_TOKEN hostctl self-update
```

1. Finds the latest commit on `main`, and stops if the installed scripts already match it.
2. Lists the [changelog](CHANGELOG.md) lines newer than the installed version, and asks before going on. Use
   `--yes` to skip the question.
3. Downloads `host/` and every installed component's folder from that exact commit, so they always match each
   other, and checks each script against the hash GitHub reports for it.
4. Runs that version's `setup-host.sh` for the installed components, the same as the one-line install. Its summary
   lists anything left to do.

`hostctl doctor` warns when `main` has a newer version. A host on 1.x (`ghrunner` before the shared layer) updates
with `sudo ghrunner self-update` as before: it moves itself to the new layout, keeping its audit baseline, alerts
and runners.

**Changing the scripts:** raise `TOOLS_VERSION` in `host-lib.sh` (2.0.0 to 2.0.1 for a fix, 2.1.0 for a new
feature) and add a line to `CHANGELOG.md`. CI fails a pull request that changes a script in `host/` or a component
folder without both.

**Adding a component:** a folder with a library defining hooks (`<prefix>_setup`, `<prefix>_checks`, ...; the list
is at the top of `host-lib.sh`), an entry in `TOOLS_COMPONENTS`, and a row in the table above.

## Testing

| What | Where it runs |
| --- | --- |
| ShellCheck on every script | CI (`.github/workflows/shellcheck.yml`) |
| Parsing and decisions: SSH settings, firewall rules, audit, alerts, versions, plus the runner's (see its README) | CI (`.github/workflows/github-runner-tests.yml`), or `bash github-runner/tests/ghrunner-test.sh` |
| Portainer's parsing and decisions (see its README) | CI (`.github/workflows/portainer-tests.yml`), or `bash portainer/tests/portainer-test.sh` |

Only a real VM can test systemd, journald, Docker, apt, ufw, sshd and cron as they behave on Ubuntu 24.04, moving
the SSH port, Pushover, and the installer, `self-update` and `doctor --fix` running setup end to end.
