# utilities

Small scripts for setting up and running Sna-ke infrastructure. This repository is public, so nothing in it may hold
a secret: tokens and keys are passed in when a script runs and never committed.

| Folder | What it is |
| --- | --- |
| [`host/`](host/README.md) | What every VM gets: hardening, Docker, alerts, a daily audit, a weekly update, and `hostctl`. One-line install for any component |
| [`github-runner/`](github-runner/README.md) | Component: GitHub Actions self-hosted runners, and `ghrunner` to manage them |

Every shell script passes ShellCheck (`.github/workflows/shellcheck.yml`). The tests run in
`.github/workflows/github-runner-tests.yml`. What changed in each version: [`host/CHANGELOG.md`](host/CHANGELOG.md).
