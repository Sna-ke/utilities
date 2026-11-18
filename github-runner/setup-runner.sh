#!/usr/bin/env bash
# Sets up this VM as a GitHub Actions runner host. Since 2.0.0 the hardening, hostctl, the audit and the
# weekly update are shared with other components in host/, so "setup" runs host/setup-host.sh for the
# github-runner component; the runner's own steps are runner_setup in runner-lib.sh.
#
# Usage (as root):
#   setup-runner.sh            set up, or bring runners in line with this machine's size
#   setup-runner.sh status     list the runners (same as "ghrunner status")
#   setup-runner.sh remove     stop, uninstall and unregister every runner (before deleting the VM)
#
# The one-line install is simpler: see README.md. Settings: see runner-lib.sh and host/setup-host.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOST_DIR="$(dirname "${SCRIPT_DIR}")/host"

# Runs host/setup-host.sh for the runner. A 1.x "ghrunner self-update" downloads only this folder;
# then host/ isn't here, so this finishes the update with the one-line install, which fetches both.
setup() {
  if [[ -f ${HOST_DIR}/setup-host.sh ]]; then
    exec bash "${HOST_DIR}/setup-host.sh" github-runner
  fi
  printf '\n==> hostctl 2.0.0 moved the shared code to host/; finishing with the one-line install\n'
  local installer
  installer="$(curl -fsSL --max-time 60 "https://raw.githubusercontent.com/${TOOLS_REPO:-Sna-ke/utilities}/${TOOLS_BRANCH:-main}/host/install.sh")" || {
    printf '\nERROR: couldn'"'"'t download host/install.sh; run the one-line install from README.md\n' >&2
    exit 1
  }
  exec bash -c "${installer}" install.sh github-runner
}

# Stops, uninstalls and unregisters every runner on this machine, leaving their folders (the VM is about
# to go).
remove_all() {
  # shellcheck source=SCRIPTDIR/../host/host-lib.sh
  . "${HOST_DIR}/host-lib.sh"
  # shellcheck source=SCRIPTDIR/runner-lib.sh
  . "${SCRIPT_DIR}/runner-lib.sh"
  [[ ${EUID} -eq 0 ]] || die "run with sudo"
  local directory
  for directory in "${RUNNER_HOME}"/*/; do
    [[ -f ${directory}.runner ]] || continue
    log "Removing $(basename "${directory}") from $(runner_repository "${directory%/}")"
    unregister_runner "${directory}"
  done
}

# Sourced by the tests; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-setup}" in
    setup) setup ;;
    status) exec bash "${SCRIPT_DIR}/ghrunner.sh" status ;;
    remove) remove_all ;;
    *) printf 'unknown command %s (use setup, status or remove)\n' "$1" >&2 && exit 1 ;;
  esac
fi
