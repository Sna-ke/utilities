#!/usr/bin/env bash
# One-line installer for hostctl and its components on Ubuntu 24.04. On the VM, as your admin user:
#
#   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/main/host/install.sh | sudo bash -s -- <component>...
#
# Components: github-runner. Several can share a host.
#
# 1. Finds the latest commit on main (or TOOLS_BRANCH).
# 2. Downloads host/ and the components' folders from that commit into a temporary runner-install
#    folder, and checks every script against the hash GitHub reports for it.
# 3. For the GitHub runner, asks for a GitHub token (hidden, kept in memory only; Enter to paste one per
#    runner instead).
# 4. Runs host/setup-host.sh, which hardens the host, asks for the SSH port and Pushover, and sets up
#    the components.
# 5. Deletes the folder.
#
# Running it again updates the host, the same as "hostctl self-update". To try a branch first:
#   curl -fsSL https://raw.githubusercontent.com/Sna-ke/utilities/<branch>/host/install.sh |
#     sudo TOOLS_BRANCH=<branch> bash -s -- <component>
#
# Until host-lib.sh is downloaded this file can't use its helpers, so it has its own copy of the two
# steps that come first: finding the commit, and checking host-lib.sh's hash.

set -Eeuo pipefail

REPO="${TOOLS_REPO:-Sna-ke/utilities}"
BRANCH="${TOOLS_BRANCH:-main}"

# Prints an error and stops.
fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# Installs curl and jq when a minimal image lacks them; both are needed before anything else.
ensure_tools() {
  command -v curl >/dev/null && command -v jq >/dev/null && return
  DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -yq ca-certificates curl jq >/dev/null
}

# Prints the latest commit on BRANCH.
latest_commit() {
  curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/commits?sha=${BRANCH}&per_page=1" | jq -r '.[0].sha'
}

# Prints a file's git blob hash (what GitHub reports for it). host-lib.sh has the same function; this
# copy checks host-lib.sh itself.
blob_sha() {
  { printf 'blob %d\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -d' ' -f1
}

# Downloads host/host-lib.sh at <commit> under the current folder and checks its hash.
fetch_library() {
  local commit="$1" expected
  expected="$(curl -fsSL --max-time 20 \
    "https://api.github.com/repos/${REPO}/contents/host/host-lib.sh?ref=${commit}" | jq -r '.sha')"
  mkdir -p host
  curl -fsSL --max-time 60 -o host/host-lib.sh "https://raw.githubusercontent.com/${REPO}/${commit}/host/host-lib.sh"
  [[ "$(blob_sha host/host-lib.sh)" == "${expected}" ]] || fail "host-lib.sh doesn't match GitHub's hash for ${commit}"
}

# Asks for a GitHub token unless GITHUB_TOKEN is already set. Prints it (empty for "paste per runner").
ask_token() {
  local token=""
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    echo "${GITHUB_TOKEN}"
    return
  fi
  printf '\nGitHub token, fine-grained with Administration: read and write on the runner repositories\n' >/dev/tty
  printf '(hidden; kept in memory only; press Enter to paste a registration token per runner instead): ' >/dev/tty
  read -r -s token </dev/tty
  printf '\n' >/dev/tty
  echo "${token}"
}

# Downloads, checks, asks for the token, runs setup-host.sh, and cleans up.
main() {
  local commit folder token="" blobs component
  local -a folders
  [[ ${EUID} -eq 0 ]] || fail "run it with sudo: curl -fsSL <this file's URL> | sudo bash -s -- <component>"
  (($# > 0)) || fail "say which component to install, e.g.: curl ... | sudo bash -s -- github-runner"
  ensure_tools

  commit="$(latest_commit)" || fail "couldn't reach GitHub"
  [[ ${commit} =~ ^[0-9a-f]{40}$ ]] || fail "GitHub's answer had no commit"
  folder="$(mktemp -d /tmp/runner-install.XXXXXX)"
  # shellcheck disable=SC2064 # expand now: remove this folder however the script ends
  trap "rm -rf '${folder}'" EXIT
  cd "${folder}"

  fetch_library "${commit}"
  # shellcheck source=SCRIPTDIR/host-lib.sh
  . ./host/host-lib.sh
  for component in "$@"; do component_field "${component}" folder >/dev/null || die "unknown component '${component}'"; done
  mapfile -t folders < <(tool_folders "$@")
  blobs="$(blobs_at "${commit}" "${folders[@]}")" || die "couldn't list the files at ${commit}"
  download_version "${commit}" "${folder}" "${blobs}"
  log "hostctl $(version_from_text <host/host-lib.sh) (commit ${commit:0:7}), downloaded and checked: ${folders[*]}"

  if [[ " $* " == *" github-runner "* ]]; then token="$(ask_token)"; fi
  GITHUB_TOKEN="${token}" TOOLS_COMMIT="${commit}" bash ./host/setup-host.sh "$@"
  cd /
  note "removed the download folder ${folder}"
}

# Everything runs from main(), so bash has read the whole file before anything happens (a cut-off
# download does nothing), and questions come from the terminal, not from the pipe this arrived on.
if ! { true </dev/tty; } 2>/dev/null; then
  fail "it asks questions, so run it from a terminal (an SSH session)"
fi
main "$@" </dev/tty
