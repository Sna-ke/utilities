# GitHub Actions runner host

`setup-runner.sh` turns a fresh Ubuntu 24.04 VM into a host for GitHub Actions self-hosted runners. Jobs on
self-hosted runners don't use a private repository's Actions minutes. Running the script again only adds what's
missing, so the same command rebuilds a host or moves it to a new VM.

## What it sets up

| Step | Result |
| --- | --- |
| System | Updated, automatic security updates on |
| SSH | Keys only (skipped if the VM has no authorized key, so it can't lock you out) |
| Firewall | ufw: SSH in, nothing else. Runners only call out to GitHub |
| Docker | Docker Engine and Compose from Docker's apt repository. Published ports bind to 127.0.0.1, because Docker's port rules bypass ufw. Container logs capped |
| Swap | 4 GB on machines under 10 GB of RAM |
| Clean-up | Weekly `docker system prune` (`/etc/cron.weekly/docker-prune`) |
| Runners | Latest release, SHA-256 checked, one systemd service each, as the `runner` user |

## Sizing

| Memory | Runners per repository | `<repo>-stack` label | Swap |
| --- | --- | --- | --- |
| Under 6 GB (e.g. OVH VPS-1) | 1 | No: the GroundCore stack job stays on GitHub's runners | 4 GB |
| 6 to 9 GB (e.g. VPS-2) | 1 | Yes | 4 GB |
| 10 GB or more (e.g. VPS-3) | 2 | Yes, on the first | None |

Override with `RUNNER_COUNT`, `STACK_LABEL=yes|no` and `SWAP_SIZE_GB`.

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
   curl -fsSLO https://raw.githubusercontent.com/Sna-ke/utilities/main/github-runner/setup-runner.sh
   less setup-runner.sh                      # read what you are about to run as root
   read -rsp "Token: " GITHUB_TOKEN && export GITHUB_TOKEN   # not echoed; skip to paste per runner
   sudo --preserve-env=GITHUB_TOKEN bash setup-runner.sh
   ```

   Serve more repositories with, for example, `RUNNER_REPOS=GroundCore,mealplan`.
4. If the script says a reboot is needed, run `sudo reboot`. The runners come back by themselves.
5. In each repository, set the Actions variables its CI reads. For GroundCore, see its `deploy/ci-runner.md`.

## Other commands

| Command | Does |
| --- | --- |
| `sudo bash setup-runner.sh status` | Lists the runner services |
| `sudo bash setup-runner.sh remove` | Unregisters every runner on this VM. Run it before deleting the VM, or GitHub keeps them listed as offline for 14 days |

## Moving to a new VM

1. Run the script on the new VM.
2. Run `remove` on the old one.
3. Delete the old VM.

Runner names include the VM's hostname, so old and new never clash.
