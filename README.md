# utilities

Small scripts for setting up and running Sna-ke infrastructure. This repository is public, so nothing in it may hold
a secret: tokens and keys are passed in when a script runs and never committed.

| Folder | What it is |
| --- | --- |
| [`github-runner/`](github-runner/README.md) | Sets up an Ubuntu VM as a host for GitHub Actions self-hosted runners, and `ghrunner` to manage it |

Every shell script passes ShellCheck (`.github/workflows/shellcheck.yml`). `ghrunner`'s tests run in
`.github/workflows/github-runner-tests.yml`.
