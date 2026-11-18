# GitHub Actions runner host

The `github-runner` component turns an Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners. Jobs on
self-hosted runners don't use a private repository's Actions minutes. The hardening, alerts, audit, weekly update
and `hostctl` come from the shared [host tools](../host/README.md); this folder adds the runners and `ghrunner`.

| File | What it is |
| --- | --- |
| `runner-lib.sh` | The runner component: download, SHA-256 check, register, resize, unregister, doctor checks, hooks |
| `ghrunner.sh` | The runner command, installed as `/usr/local/bin/ghrunner` |
| `setup-runner.sh` | Runs the host setup for this component; `status` and `remove` |
| `install.sh` | Kept so the old one-line install URL still works; runs `host/install.sh github-runner` |
| `tests/ghrunner-test.sh` | Tests the host tools' and the runner's parsing and decisions against sample input |
| `tests/version-check.sh` | CI check: a change to the scripts raises the version and adds a changelog line |

## What it adds to the host

| Step | Result |
| --- | --- |
| Runners | Latest release, SHA-256 checked, one systemd service each, as the `runner` user (which can't log in over SSH) |
| Sizing | Runners and labels to fit the machine (see Sizing) |
| Tool locations | Each runner's `.env` tells setup actions where to install tools (see below). Existing runners get it too |
| Clean-up | CI leaves volumes behind, so this host's weekly clean-up removes unused volumes too |
| Weekly update | Waits until no job is running and pauses the runners while packages are upgraded |
| `ghrunner` | `/usr/local/bin/ghrunner` |

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

After changing the VM's size, run `sudo --preserve-env=GITHUB_TOKEN ghrunner resize`. `hostctl doctor` warns when
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

1. Create the VM (Ubuntu 24.04, with your SSH key). Use it for nothing else you'd mind CI code reaching: runners
   run whatever is pushed to a branch, with Docker and sudo, which are root.
2. Have a GitHub token ready, or plan to paste tokens as you go:
   1. **A token (recommended).** On GitHub: Settings > Developer settings > Fine-grained tokens. Choose only the
      repositories the runners serve, the permission Administration: Read and write, and a 7-day expiry. Delete the
      token when you're done.
   2. **Paste as you go.** Press Enter when asked for a token. For each runner, setup asks for a registration token
      from the repository's Settings > Actions > Runners > New self-hosted runner page. Each lasts an hour.
3. Log in to the VM as your admin user and run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/host/install.sh | sudo bash -s -- github-runner
   ```

   It asks for the token, then the host questions (SSH port, Pushover; see the [host tools](../host/README.md#install)).
   To serve more repositories: `curl ... | sudo RUNNER_REPOS=GroundCore,mealplan bash -s -- github-runner`.
4. If setup says a reboot is needed, run `sudo reboot`. The runners come back by themselves.
5. In each repository, set the Actions variables its CI reads. For GroundCore, see its `deploy/ci-runner.md`.
6. Check the host with `hostctl doctor` and the runners with `ghrunner status`.

## `ghrunner`

| Command | What it does | sudo |
| --- | --- | --- |
| `ghrunner add <repo> [count]` | Registers runners 1 to `count` for a repository, with the usual folders, names and labels. `count` defaults to the Sizing rule above. Runners that exist are kept | Yes |
| `ghrunner delete <repo>` | Stops, uninstalls and unregisters that repository's runners, then deletes their folders | Yes |
| `ghrunner resize [repo]` | After a VM resize: adds, relabels and removes runners to match the Sizing rule. Lists anything it couldn't do, with why and how, and exits 1 (see Resizing the VM) | Yes |
| `ghrunner status` | Each runner: service state, idle or busy, and the job it is running | No |
| `ghrunner stats [days]` | From the journal, for the last 7 days or `days`: jobs started and completed, results and average time, per runner and per repository. Then disk use of `/` and Docker, memory, swap, the last clean-up and the last reboot | No |
| `ghrunner help` | Lists the commands | No |

`ghrunner doctor`, `audit`, `update`, `prune`, `version` and `self-update` still work: they run `hostctl`'s, which
cover the whole host (see the [host tools](../host/README.md#hostctl)).

`<repo>` is a repository name (owner `GITHUB_OWNER`, default `Sna-ke`) or `owner/repo`. `add`, `delete` and
`resize` get tokens from `GITHUB_TOKEN`, or ask you to paste one. For example:

```sh
sudo --preserve-env=GITHUB_TOKEN ghrunner add example-org/example-app 2
sudo ghrunner delete example-app
ghrunner stats 30
```

Without sudo, the read-only commands show what an ordinary user can see. Job names and runner versions come from
the journal, which needs sudo or membership of the `adm` group (Ubuntu's default admin user has it).

### The runner's `doctor` checks

`hostctl doctor` adds these rows on a runner host:

| Check | Passes when | `--fix` fixes it |
| --- | --- | --- |
| Runner services | All active | No |
| Sizing | Runners and labels fit the machine | Yes (runs `resize`) |
| Private repositories | No runner serves a public repository (a pull request there would run as root here) | No: `sudo ghrunner delete <repo>` |
| Tool locations | The tool cache exists, and every runner's `.env` is set | Yes |

## Other commands

| Command | Does |
| --- | --- |
| `sudo bash /usr/local/lib/hostctl/github-runner/setup-runner.sh status` | Same as `ghrunner status` |
| `sudo bash /usr/local/lib/hostctl/github-runner/setup-runner.sh remove` | Unregisters every runner on this VM. Run it before deleting the VM, or GitHub keeps them listed as offline for 14 days |

## Moving to a new VM

1. Run the one-line install on the new VM.
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
runner in the middle of a job is left alone, with the command to restart it afterwards. `hostctl doctor` reports
any runner without them.

| Other setup actions | On this host |
| --- | --- |
| `shivammathur/setup-php` | Installs PHP system-wide with apt and sudo, which the `runner` user has. Two jobs wanting different PHP versions at the same time would clash |
| Anything else | If a job fails with "Permission denied", look in the action's README for an install-folder setting, and add it to `runner_env_settings` in `runner-lib.sh` |

## Testing

`tests/ghrunner-test.sh` checks unit names, cgroups, `.runner` files, runner output, journal JSON, job statistics,
resize decisions, `.env` settings and tables against sample input, alongside the host tools' checks. It runs in CI
and anywhere with `bash github-runner/tests/ghrunner-test.sh`.

Only a real runner host can test registering, re-registering and unregistering with GitHub, the unit names the
runner's `svc.sh` writes, `Runner.Worker` cgroups, and the runner's real journal output.
