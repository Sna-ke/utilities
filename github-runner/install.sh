#!/usr/bin/env bash
# Kept so the one-line install in older instructions keeps working. It now runs host/install.sh for the
# github-runner component:
#
#   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/github-runner/install.sh | sudo bash
#
# is the same as
#
#   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/host/install.sh | sudo bash -s -- github-runner

set -Eeuo pipefail

export TOOLS_REPO="${TOOLS_REPO:-${GHRUNNER_REPO:-Sna-ke/utilities}}"
export TOOLS_BRANCH="${TOOLS_BRANCH:-${GHRUNNER_BRANCH:-main}}"

installer="$(curl -fsSL --max-time 60 "https://raw.githubusercontent.com/${TOOLS_REPO}/${TOOLS_BRANCH}/host/install.sh")" || {
  printf '\nERROR: couldn'"'"'t download host/install.sh\n' >&2
  exit 1
}
exec bash -c "${installer}" install.sh github-runner "$@"
