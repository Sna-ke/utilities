#!/usr/bin/env bash
# Fails a pull request that changes setup-runner.sh, runner-lib.sh or ghrunner.sh without raising
# GHRUNNER_VERSION, or without a CHANGELOG.md line for the new version. Without this, "ghrunner version"
# and "self-update" would report two different sets of files as the same version.
#
#   bash github-runner/tests/version-check.sh origin/main     (the branch the pull request goes into)

set -Eeuo pipefail

FOLDER="github-runner"
# shellcheck source=SCRIPTDIR/../runner-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../runner-lib.sh"

# Prints the GHRUNNER_VERSION in runner-lib.sh at <git revision>, or 0 when it had none.
version_at_revision() {
  local version
  version="$(git show "$1:${FOLDER}/runner-lib.sh" 2>/dev/null | version_from_text || true)"
  echo "${version:-0}"
}

# Checks the current commit against <base>.
main() {
  local base="$1" old new
  if git diff --quiet "${base}...HEAD" -- "${FOLDER}/setup-runner.sh" "${FOLDER}/runner-lib.sh" "${FOLDER}/ghrunner.sh"; then
    echo "No script changes: nothing to check."
    return
  fi
  old="$(version_at_revision "${base}")"
  new="$(version_from_text <"${FOLDER}/runner-lib.sh")"
  version_newer "${new:-0}" "${old}" ||
    die "the scripts changed but GHRUNNER_VERSION didn't go up (${old} -> ${new:-none}): raise it in ${FOLDER}/runner-lib.sh"
  grep -qE "^\| *${new//./\\.} *\|" "${FOLDER}/CHANGELOG.md" ||
    die "${FOLDER}/CHANGELOG.md has no line for ${new}: add one"
  echo "Version ${old} -> ${new}, with a changelog line."
}

main "${1:?usage: version-check.sh <base revision, e.g. origin/main>}"
