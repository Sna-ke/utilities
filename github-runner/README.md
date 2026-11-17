# GitHub Actions runner host

`setup-runner.sh` turns a fresh Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners. Jobs on
self-hosted runners don't use a private repository's Actions minutes. Running the script again only adds what's
missing, so the same command rebuilds a host or moves it to a new VM. It also installs `ghrunner`, a command for
running the host day to day.

| File | What it is |
| --- | --- |
| `setup-runner.sh` | Sets up the VM (run once, or again to repair or update) |
| `ghrunner.sh` | The management command, installed as `/usr/local/bin/ghrunner` |
| `runner-lib.sh` | Code both scripts share: download, SHA-256 check, register, unregister |
| `tests/ghrunner-test.sh` | Tests `ghrunner`'s parsing against sample input |

## What it sets up

| Step | Result |
| --- | --- |
| System | Updated, automatic security updates on |
| SSH | Keys only (skipped if the VM has no authorized key, so it can't lock you out) |
| Firewall | ufw: SSH in, nothing else. Runners only call out to GitHub |
| Docker | Docker Engine and Compose from Docker's apt repository. Published ports bind to 127.0.0.1, because Docker's port rules bypass ufw. Container logs capped |
| Swap | 4 GB on machines under 10 GB of RAM |
| Clean-up | Weekly `docker system prune` (`/etc/cron.weekly/docker-prune`), logged to the journal |
| Runners | Latest release, SHA-256 checked, one systemd service each, as the `runner` user |
| Tool locations | Each runner's `.env` tells setup actions where to install tools (see below). Existing runners get it too |
| `ghrunner` | `/usr/local/bin/ghrunner`, with its shared code in `/usr/local/lib/ghrunner/` |

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
   branch, with Docker, which is root-equivalent.
2. Get registration tokens in one of two ways:
   1. **A token for the script (recommended).** On GitHub: Settings > Developer settings > Fine-grained tokens. Choose
      only the repositories the runners serve, the permission Administration: Read and write, and a 7-day expiry.
      Delete the token when you're done.
   2. **Paste as you go.** Leave `GITHUB_TOKEN` unset. For each runner, the script asks for a registration token from
      the repository's Settings > Actions > Runners > New self-hosted runner page. Each token lasts an hour.
3. On the VM:

   ```sh
   mkdir runner-setup && cd runner-setup
   for file in setup-runner.sh runner-lib.sh ghrunner.sh; do
     curl -fsSLO "https://raw.githubusercontent.com/Sna-ke/utilities/main/github-runner/${file}"
   done
   less setup-runner.sh runner-lib.sh ghrunner.sh   # read what you are about to run as root
   read -rsp "Token: " GITHUB_TOKEN && export GITHUB_TOKEN   # not echoed; skip to paste per runner
   sudo --preserve-env=GITHUB_TOKEN bash setup-runner.sh
   ```

   The three files must sit in the same folder. Once setup is done, the folder can be deleted.

   Serve more repositories with, for example, `RUNNER_REPOS=GroundCore,mealplan`.
4. If the script says a reboot is needed, run `sudo reboot`. The runners come back by themselves.
5. In each repository, set the Actions variables its CI reads. For GroundCore, see its `deploy/ci-runner.md`.
6. Check the host with `ghrunner doctor`.

A host set up before `ghrunner` existed gets it, and the clean-up job's journal logging, by running the new
`setup-runner.sh` once more.

## Managing the host: `ghrunner`

| Command | What it does | sudo |
| --- | --- | --- |
| `ghrunner add <repo> [count]` | Registers runners 1 to `count` for a repository, with the usual folders, names and labels. `count` defaults to the Sizing rule above. Runners that exist are kept | Yes |
| `ghrunner delete <repo>` | Stops, uninstalls and unregisters that repository's runners, then deletes their folders | Yes |
| `ghrunner resize [repo]` | After a VM resize: adds, relabels and removes runners to match the Sizing rule. Lists anything it couldn't do, with why and how, and exits 1 (see Resizing the VM) | Yes |
| `ghrunner update` | Upgrades system packages and says whether a reboot is needed; compares each runner's version with the latest release (runners update themselves, so this only reports) | Yes |
| `ghrunner status` | Each runner: service state, idle or busy, and the job it is running | No |
| `ghrunner stats [days]` | From the journal, for the last 7 days or `days`: jobs started and completed, results and average time, per runner and per repository. Then disk use of `/` and Docker, memory, swap, the last clean-up and the last reboot | No |
| `ghrunner prune` | Runs the weekly clean-up now and shows the space freed | Yes |
| `ghrunner doctor` | Checks disk (warn under 20% free, fail under 10%), Docker, every runner service, sizing, tool locations, the clean-up job, the firewall, SSH keys only, a pending reboot and swap. Prints PASS/WARN/FAIL and exits 1 on any FAIL | No |
| `ghrunner help` | Lists the commands | No |

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

A first run on a new host: `ghrunner doctor`, `ghrunner status` while a job runs, `sudo ghrunner prune`, then
`ghrunner stats` after a few jobs.
