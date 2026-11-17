# GitHub Actions runner host

`setup-runner.sh` turns a fresh Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners. Jobs on
self-hosted runners don't use a private repository's Actions minutes. Running the script again only adds what's
missing, so the same command rebuilds a host or moves it to a new VM. It also installs `ghrunner`, a command for
running the host day to day.

| File | What it is |
| --- | --- |
| `install.sh` | The one-line installer: downloads and checks the other three, asks for a token, runs setup, cleans up |
| `setup-runner.sh` | Sets up the VM (run once, or again to repair or update) |
| `ghrunner.sh` | The management command, installed as `/usr/local/bin/ghrunner` |
| `runner-lib.sh` | Code both scripts share: download, SHA-256 check, register, unregister |
| `CHANGELOG.md` | What changed in each version |
| `tests/ghrunner-test.sh` | Tests `ghrunner`'s parsing against sample input |
| `tests/version-check.sh` | CI check: a change to the scripts raises the version and adds a changelog line |

## What it sets up

| Step | Result |
| --- | --- |
| System | Updated. Security updates daily; a full update weekly (see Security) |
| SSH | Keys only, on the port you choose (9452 suggested). Details under Security |
| Firewall | ufw: SSH in (rate-limited), nothing else. Runners only call out to GitHub |
| Kernel network settings | Ignores ICMP redirects and source routing, sends no redirects, hides kernel addresses |
| Audit | A baseline of the machine, checked daily (see Security) |
| Alerts | Optional: Pushover notifications to your phone |
| Docker | Docker Engine and Compose from Docker's apt repository. Published ports bind to 127.0.0.1, because Docker's port rules bypass ufw. Container logs capped |
| Swap | 4 GB on machines under 10 GB of RAM |
| Clean-up | Weekly `docker system prune` (`/etc/cron.weekly/docker-prune`), logged to the journal |
| Runners | Latest release, SHA-256 checked, one systemd service each, as the `runner` user |
| Tool locations | Each runner's `.env` tells setup actions where to install tools (see below). Existing runners get it too |
| `ghrunner` | `/usr/local/bin/ghrunner`. `/usr/local/lib/ghrunner/` holds copies of all three files and `VERSION`, the commit they came from |

## Sizing

Each runner gets at least 5 GB of memory and 3 cores, and there is always at least one per repository. The first
runner gets the `<repo>-stack` label from 6 GB, and machines under 10 GB get swap.

| Machine (OVH) | Cores, memory | Runners per repository | `<repo>-stack` label | Swap |
| --- | --- | --- | --- | --- |
| VPS-1 | 2, 4 GB | 1 | No: the GroundCore stack job stays on GitHub's runners | 4 GB |
| VPS-2 | 4, 8 GB | 1 | Yes | 4 GB |
| VPS-3 | 6, 12 GB | 2 | Yes, on the first | None |
| VPS-4 | 8, 24 GB | 2 (cores are the limit) | Yes, on the first | None |

Override with `RUNNER_COUNT`, `STACK_LABEL=yes|no` and `SWAP_SIZE_GB`.

## Resizing the VM

After changing the VM's size, run `sudo --preserve-env=GITHUB_TOKEN ghrunner resize`. `ghrunner doctor` warns when
the runners no longer match the machine. For every repository with runners here, `resize`:

1. Adds runners the machine now fits.
2. Gives runner 1 the `<repo>-stack` label, or takes it away, by registering it again in its own folder.
3. Removes runners above the count, highest number first.

Whatever it can't do, it lists under "Still to do" with the reason and how to finish, then exits 1:

| Reason | How to finish |
| --- | --- |
| The runner is running a job (removing or relabelling it would cancel the job) | Run `resize` again once `ghrunner status` shows it idle |
| No token: no `GITHUB_TOKEN` and no terminal to paste one into | Run it with `GITHUB_TOKEN` set, or from a terminal |
| GitHub refused to unregister it | The exact commands to remove it by hand, once it's gone from Settings > Actions > Runners |
| Its labels are unknown (registered before ghrunner recorded them in the runner's `.labels` file) | Run it with `GITHUB_TOKEN` set, so ghrunner reads them from GitHub |

`resize` applies the sizing rule to every repository, including one given a different count with
`ghrunner add <repo> <count>`. To keep a different count, set `RUNNER_COUNT` when running it. Running
`setup-runner.sh` again does the same as `resize`, for `RUNNER_REPOS` and every repository already on the machine.

## Run it

1. Create the VM (Ubuntu 24.04, with your SSH key). Use it for nothing else: runners run whatever code is pushed to a
   branch, with Docker and sudo, which are root.
2. Have a GitHub token ready, or plan to paste tokens as you go:
   1. **A token (recommended).** On GitHub: Settings > Developer settings > Fine-grained tokens. Choose only the
      repositories the runners serve, the permission Administration: Read and write, and a 7-day expiry. Delete the
      token when you're done.
   2. **Paste as you go.** Press Enter when asked for a token. For each runner, setup asks for a registration token
      from the repository's Settings > Actions > Runners > New self-hosted runner page. Each lasts an hour.
3. Log in to the VM as your admin user and run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/github-runner/install.sh | sudo bash
   ```

   It asks for:

   | Question | Answer |
   | --- | --- |
   | GitHub token | The token from step 2 (hidden, kept in memory only), or Enter |
   | SSH port | Enter for the suggested one (9452 on a new VM; afterwards, the current one) |
   | Did the new port work? | Open a second terminal, log in with the `ssh -p` command it shows, then answer. Port 22 closes only after a yes |
   | Pushover user key | From pushover.net once you log in, or Enter for no alerts |
   | Pushover application token | Create an application at pushover.net/apps/build (any name). Setup checks both with Pushover and sends a test alert |

   To serve more repositories: `curl ... | sudo RUNNER_REPOS=GroundCore,mealplan bash`. To read the scripts before
   running them, download `install.sh` and open it: it lists what it fetches.
4. If setup says a reboot is needed, run `sudo reboot`. The runners come back by themselves.
5. In each repository, set the Actions variables its CI reads. For GroundCore, see its `deploy/ci-runner.md`.
6. Check the host with `ghrunner doctor`.

To try a pull request's version on a VM before merging it, install from its branch:
`curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/<branch>/github-runner/install.sh | sudo GHRUNNER_BRANCH=<branch> bash`.

## Managing the host: `ghrunner`

| Command | What it does | sudo |
| --- | --- | --- |
| `ghrunner add <repo> [count]` | Registers runners 1 to `count` for a repository, with the usual folders, names and labels. `count` defaults to the Sizing rule above. Runners that exist are kept | Yes |
| `ghrunner delete <repo>` | Stops, uninstalls and unregisters that repository's runners, then deletes their folders | Yes |
| `ghrunner resize [repo]` | After a VM resize: adds, relabels and removes runners to match the Sizing rule. Lists anything it couldn't do, with why and how, and exits 1 (see Resizing the VM) | Yes |
| `ghrunner update [--scheduled]` | Upgrades every package (Docker's too), never reboots, and warns when a new kernel waits for one; compares each runner's version with the latest release (runners update themselves, so this only reports). `--scheduled` is the weekly timer: it waits until no job is running and pauses the runners during the upgrade | Yes |
| `ghrunner status` | Each runner: service state, idle or busy, and the job it is running | No |
| `ghrunner stats [days]` | From the journal, for the last 7 days or `days`: jobs started and completed, results and average time, per runner and per repository. Then disk use of `/` and Docker, memory, swap, the last clean-up and the last reboot | No |
| `ghrunner prune` | Runs the weekly clean-up now and shows the space freed | Yes |
| `ghrunner doctor [--fix]` | Checks the host (see below). Prints PASS/WARN/FAIL and exits 1 on any FAIL. `--fix` runs the installed setup again when a problem is one it fixes, then checks again | No (`--fix`: yes) |
| `ghrunner audit [--accept]` | Lists what changed since the audit baseline (see Security). `--accept` makes the current state the baseline, after you've checked the changes are yours | Yes |
| `ghrunner version` | The installed version and commit, the latest on `main`, and whether they match | No |
| `ghrunner self-update [--yes]` | Updates to the latest `main`, after listing what changed (see Updating) | Yes |
| `ghrunner help` | Lists the commands | No |

### What `doctor` checks

| Check | Passes when | `--fix` fixes it |
| --- | --- | --- |
| Disk free | 20% or more free on `/` (warns under 20%, fails under 10%) | No: `sudo ghrunner prune` |
| Docker | Running | No |
| Docker ports | Published ports bind to 127.0.0.1 | Yes |
| Runner services | All active | No |
| Sizing | Runners and labels fit the machine | Yes (runs `resize`) |
| Private repositories | No runner serves a public repository | No: `sudo ghrunner delete <repo>` |
| Tool locations | The tool cache exists, and every runner's `.env` is set | Yes |
| Scheduled jobs | Clean-up, weekly update and daily audit are on, and didn't fail last time | Yes |
| Security updates | Daily unattended upgrades on | Yes |
| Firewall | On, letting in only SSH, rate-limited | Yes |
| SSH | Keys only, one port and not 22, root and `runner` can't log in, 3 tries at most | Yes (asks for the port) |
| Kernel settings | The hardened network settings are in force | Yes |
| Alerts | Pushover set up | Yes (asks for the key and token) |
| Audit | Ran in the last 2 days with no unaccepted changes | No: `sudo ghrunner audit` |
| Kernel | Running the newest installed kernel | No: `sudo reboot` |
| Reboot pending | No reboot pending | No: `sudo reboot` |
| Swap | On, below 10 GB of memory | Yes |
| ghrunner version | Same as `main` | No: `sudo ghrunner self-update` |

Without sudo, the firewall rules, the alert settings and repository visibility aren't checked.

`<repo>` is a repository name (owner `GITHUB_OWNER`, default `Sna-ke`) or `owner/repo`. `add` and `delete` get
tokens the same way as `setup-runner.sh`: from `GITHUB_TOKEN`, or by asking you to paste one. For example:

```sh
sudo --preserve-env=GITHUB_TOKEN ghrunner add example-org/example-app 2
sudo ghrunner delete example-app
ghrunner stats 30
```

Without sudo, the read-only commands show what an ordinary user can see. Job names, runner versions and the last
clean-up come from the journal, which needs sudo or membership of the `adm` group (Ubuntu's default admin user
has it). Docker disk use needs sudo or the `docker` group.

## Updating

```sh
read -rsp "Token: " GITHUB_TOKEN && export GITHUB_TOKEN   # so nothing stops to ask for one
sudo --preserve-env=GITHUB_TOKEN ghrunner self-update
```

1. Finds the latest commit on `main` that changed `github-runner/`, and stops if the installed files already
   match it.
2. Lists the [changelog](CHANGELOG.md) lines newer than the installed version, and asks before going on. Use `--yes` to skip the question
   (for example, from cron).
3. Downloads all three files from that exact commit, so they always match each other, and checks each against
   the hash GitHub reports for it.
4. Runs that version's `setup-runner.sh`, the same as updating by hand: packages, `ghrunner`, runner settings and
   sizing. Its summary lists anything left to do.

`ghrunner doctor` warns when `main` has a newer version.

**Changing the scripts:** raise `GHRUNNER_VERSION` in `runner-lib.sh` (1.3.0 to 1.3.1 for a fix, 1.4.0 for a new
feature) and add a line to `CHANGELOG.md`. CI fails a pull request that changes `setup-runner.sh`, `runner-lib.sh`
or `ghrunner.sh` without both. A host installed before `self-update` existed updates with
the one-line install (Run it, step 3).

## Other commands

| Command | Does |
| --- | --- |
| `sudo bash setup-runner.sh status` | Same as `ghrunner status` |
| `sudo bash setup-runner.sh remove` | Unregisters every runner on this VM. Run it before deleting the VM, or GitHub keeps them listed as offline for 14 days |

## Moving to a new VM

1. Run the script on the new VM.
2. Run `remove` on the old one.
3. Delete the old VM.

Runner names include the VM's hostname, so old and new never clash.

## Security

| Protection | How |
| --- | --- |
| SSH | Keys only. Port of your choice. Root can't log in when another admin user has a key. The `runner` user can't log in. 3 tries per connection, 30 seconds to log in. No X11 or agent forwarding |
| Moving the SSH port safely | Setup listens on both ports, asks you to log in on the new one from a second terminal, and closes the old one only after you say it worked. Without a terminal, it never changes the port |
| Firewall | ufw allows only the SSH port, and blocks an address after 6 connection attempts in 30 seconds. Docker publishes ports on 127.0.0.1 only, because its rules bypass ufw |
| Updates | Ubuntu's security updates daily. A full update (Docker included) weekly, Sunday 11:00 UTC (`UPDATE_SCHEDULE`): it waits until no job runs, pauses the runners, upgrades, and starts them again. It never reboots: a waiting kernel shows at login, in `doctor`, and as an alert |
| Public repositories | Refused. On a public repository anyone can open a pull request, and its workflow would run as root here |
| Audit | Setup records a baseline: accounts, SSH keys, sudo rules, SSH settings, firewall rules, ports open to the outside, cron jobs, services that start at boot, setuid programs, ghrunner's own files, and where SSH logins come from. A timer compares the machine with it daily |
| Hearing about it | Audit findings and a waiting kernel show at every SSH login and in `ghrunner doctor`, and go to Pushover if you set it up (once per new set of findings, not daily). Audit alerts are high priority, so they sound even in quiet hours. The key and token are kept in `/etc/ghrunner/pushover`, readable by root only |
| Updates can't bless a compromise | Setup, and so `self-update`, checks the audit first and stops if anything changed that nobody accepted |

**Limits.** CI jobs run as root (Docker and sudo), which is why only private repositories you alone push to belong
here. Someone with root on the VM can also hide from the audit; it catches mistakes and careless intruders, not a
careful one. That is why a compromised VM is rebuilt rather than cleaned.

**After a change you made** (a new SSH key, a package that adds a service), the next audit lists it: check it's
yours, then run `sudo ghrunner audit --accept`. A login from a new address (your home IP changed, a phone hotspot)
shows up the same way.

## If the VM is compromised

Signs: an audit finding you didn't make (a new key, user, sudo rule, open port, cron job or service), ghrunner's files
changed, or anything else you can't explain. Don't try to clean it:

1. Stop using it. Don't type passwords or tokens into it.
2. In the OVH control panel, reinstall the VPS with Ubuntu 24.04 and your SSH key. This wipes the disk.
3. Assume anything jobs could read was taken, and replace it:
   1. Each repository's Actions secrets (Settings > Secrets and variables > Actions), and whatever they unlock.
   2. The GitHub token, if you used one on that VM.
4. Check each repository for things you didn't do: commits, workflow files, releases, deploy keys and webhooks.
5. Run the one-line install (Run it, step 3). The runners register under their old names, which replaces the old
   registrations; remove any that stay offline in Settings > Actions > Runners.
6. Run `ghrunner doctor`.

## Where jobs install tools

Setup actions are written for GitHub's own runners, where system folders are writable. On this host they run as
the `runner` user, so each runner's `.env` file (read by the runner when it starts, passed to every job) points
them somewhere writable. Workflows need no changes.

| Setting | Value | Why |
| --- | --- | --- |
| `DOTNET_INSTALL_DIR` | `/home/runner/<runner>/.dotnet` | `actions/setup-dotnet` installs to `/usr/share/dotnet` by default. One folder per runner, so two jobs never install into the same one |
| `AGENT_TOOLSDIRECTORY`, `RUNNER_TOOL_CACHE` | `/opt/hostedtoolcache`, owned by `runner` | GitHub's prebuilt Python (`setup-python`) and Ruby (`setup-ruby`) only work from this path. Shared by all runners; `setup-node`, `setup-java` and `setup-go` use it too |

`setup-runner.sh` and `ghrunner add` apply these to every runner and restart the ones whose settings changed. A
runner in the middle of a job is left alone, with the command to restart it afterwards. `ghrunner doctor` reports
any runner without them.

| Other setup actions | On this host |
| --- | --- |
| `shivammathur/setup-php` | Installs PHP system-wide with apt and sudo, which the `runner` user has. Two jobs wanting different PHP versions at the same time would clash |
| Anything else | If a job fails with "Permission denied", look in the action's README for an install-folder setting, and add it to `runner_env_settings` in `runner-lib.sh` |

## Testing

| What | Where it runs |
| --- | --- |
| ShellCheck on every script | CI (`.github/workflows/shellcheck.yml`) |
| `ghrunner`'s parsing: unit names, cgroups, `.runner` files, runner output, journal JSON, job statistics, sshd settings, tables | CI (`.github/workflows/github-runner-tests.yml`), or anywhere with `bash github-runner/tests/ghrunner-test.sh` |

Only a real runner host can test the rest:

1. Registering, re-registering and unregistering with GitHub (`add`, `delete`, `resize`, `setup-runner.sh remove`),
   and reading a runner's labels from GitHub.
2. systemd: unit names as the runner's `svc.sh` writes them, service states, `Runner.Worker` cgroups (`status`).
3. journald: the runner's real output lines and the clean-up job's log line (`status`, `stats`, `update`).
4. Docker, apt, ufw, sshd and cron as they behave on Ubuntu 24.04 (`prune`, `update`, `doctor`).
5. Moving the SSH port (ssh.socket taking the port from sshd's settings), the timers, the login message, Pushover
   (this repository's tests can't reach it), `doctor --fix`, and a full audit snapshot (`ss`, `ssh-keygen`, `find`,
   `sshd -T`).
6. The one-line installer end to end. Its download and hash checks were tested against this repository on GitHub.
7. A full `self-update` (it runs `setup-runner.sh`). Its version check, hashes and download were tested against
   this repository on GitHub.

A first run on a new host: `ghrunner doctor`, `ghrunner status` while a job runs, `sudo ghrunner prune`, then
`ghrunner stats` after a few jobs.
