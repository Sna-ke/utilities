# github-runner changelog

`ghrunner version` shows the installed version, and `ghrunner self-update` lists the lines below that are newer
than it. The version is `GHRUNNER_VERSION` in `runner-lib.sh`. Every pull request that changes
`setup-runner.sh`, `runner-lib.sh` or `ghrunner.sh` raises it and adds a line here, newest first; CI checks both.

| Version | Date | Changes |
| --- | --- | --- |
| 1.5.0 | 2026-11-17 | `doctor` checks every lockdown item (SSH port, root and `runner` login, tries; firewall only SSH and rate-limited; kernel network settings; daily security updates; Docker on 127.0.0.1; alerts). `doctor --fix` runs the installed setup again for what it fixes. Alerts go to Pushover instead of a URL. Kernel settings the kernel lacks (IPv6 off) are skipped |
| 1.4.0 | 2026-11-17 | Hardening: SSH port asked each run (moved only after you confirm), root and `runner` can't log in, rate-limited firewall, kernel network settings. Weekly full update that waits for idle runners and warns about a waiting kernel. Daily audit against a baseline, shown at login, in `doctor` and as optional alerts; setup stops if it finds unaccepted changes. Public repositories refused. One-line installer (`install.sh`) |
| 1.3.0 | 2026-11-17 | Version numbers: `ghrunner version`, `self-update`, `doctor` and `help` show them, and `self-update` lists this changelog |
| 1.2.0 | 2026-11-17 | `ghrunner self-update` and `ghrunner version`. Removed the `/usr/share/dotnet` step, replaced by `DOTNET_INSTALL_DIR` in 1.1.0 |
| 1.1.0 | 2026-11-17 | Each runner's `.env` points `setup-dotnet`, `setup-python` and `setup-ruby` at writable folders. `ghrunner resize`; sizing counts cores |
| 1.0.0 | 2026-11-17 | The `ghrunner` command, and `runner-lib.sh` shared with `setup-runner.sh` |
