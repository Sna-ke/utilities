#!/usr/bin/env bash
# Fails a pull request that changes a script in host/ or a component folder (tests aside) without raising
# TOOLS_VERSION in host/host-lib.sh, or without a host/CHANGELOG.md line for the new version. Without this,
# "hostctl version" and "self-update" would report two different sets of files as the same version.
#
#   bash github-runner/tests/version-check.sh origin/main     (the branch the pull request goes into)

set -Eeuo pipefail

# The scripts a version is made of: those directly in host/ and the component folders (":(glob)" keeps
# "*" from matching the tests/ folders).
SCRIPTS=(":(glob)host/*.sh" ":(glob)github-runner/*.sh" ":(glob)portainer/*.sh")
# shellcheck source=SCRIPTDIR/../../host/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../host/host-lib.sh"

# Prints the version at <git revision>: TOOLS_VERSION in host/host-lib.sh, or GHRUNNER_VERSION in
# github-runner/runner-lib.sh before 2.0.0, or 0.
version_at_revision() {
  local version
  version="$(git show "$1:host/host-lib.sh" 2>/dev/null | version_from_text || true)"
  if [[ -z ${version} ]]; then
    version="$(git show "$1:github-runner/runner-lib.sh" 2>/dev/null | version_from_text || true)"
  fi
  echo "${version:-0}"
}

# Checks the current commit against <base>.
main() {
  local base="$1" old new
  if git diff --quiet "${base}...HEAD" -- "${SCRIPTS[@]}"; then
    echo "No script changes: nothing to check."
    return
  fi
  old="$(version_at_revision "${base}")"
  new="$(version_from_text <host/host-lib.sh)"
  version_newer "${new:-0}" "${old}" ||
    die "the scripts changed but TOOLS_VERSION didn't go up (${old} -> ${new:-none}): raise it in host/host-lib.sh"
  grep -qE "^\| *${new//./\\.} *\|" host/CHANGELOG.md ||
    die "host/CHANGELOG.md has no line for ${new}: add one"
  echo "Version ${old} -> ${new}, with a changelog line."
}

main "${1:?usage: version-check.sh <base revision, e.g. origin/main>}"
