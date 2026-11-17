# shellcheck shell=bash
# Shared by setup-runner.sh and ghrunner.sh: settings, messages, machine facts, and the code that downloads,
# verifies, registers and unregisters runners. Sourced, never run on its own.
#
# Conventions both scripts rely on:
#   - runners live in /home/runner/<repo-lowercase>-<n>
#   - runner names are <hostname>-<repo-lowercase>-<n>
#   - labels are <repo>-ci, plus <repo>-stack on runner 1 when the machine has 6 GB of RAM or more
#   - each runner's .runner file holds gitHubUrl; its systemd unit is actions.runner.*
#
# Secrets: none. GITHUB_TOKEN is read from the environment and never written to disk.

GITHUB_OWNER="${GITHUB_OWNER:-Sna-ke}"
# shellcheck disable=SC2034 # read by the scripts that source this file
RUNNER_COUNT="${RUNNER_COUNT:-auto}"
STACK_LABEL="${STACK_LABEL:-auto}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s)}"
RUNNER_USER="runner"
RUNNER_HOME="/home/${RUNNER_USER}"
DOWNLOAD_DIR="/var/cache/actions-runner"
# shellcheck disable=SC2034 # read by the scripts that source this file
PRUNE_SCRIPT="/etc/cron.weekly/docker-prune"
# shellcheck disable=SC2034 # read by the scripts that source this file
GHRUNNER_LIB_DIR="/usr/local/lib/ghrunner"

# Prints a step heading, so long runs show where they are.
log() { printf '\n==> %s\n' "$*"; }
# Prints an indented detail line under the current step.
note() { printf '    %s\n' "$*"; }
# Prints an error and stops; every failure goes through here so messages look the same.
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Machine facts
# ---------------------------------------------------------------------------------------------

# Total memory in whole gigabytes, rounded to the nearest (a "4 GB" VPS reports about 3.8).
memory_gb() {
  awk '/MemTotal/ { printf "%d", ($2 / 1024 / 1024) + 0.5 }' /proc/meminfo
}

# The runner release's name for this CPU.
runner_architecture() {
  case "$(uname -m)" in
    x86_64) echo "x64" ;;
    aarch64) echo "arm64" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# Resolves RUNNER_COUNT and STACK_LABEL when they are "auto", from the machine's memory, so the same
# rules size runners whether setup-runner.sh or "ghrunner add" registers them.
resolve_runner_settings() {
  local memory
  memory="$(memory_gb)"
  if [[ ${RUNNER_COUNT} == "auto" ]]; then
    if ((memory >= 10)); then RUNNER_COUNT=2; else RUNNER_COUNT=1; fi
  fi
  if [[ ${STACK_LABEL} == "auto" ]]; then
    # The GroundCore stack job needs about 3-4 GB on its own; below 6 GB it stays on GitHub's runners.
    if ((memory >= 6)); then STACK_LABEL="yes"; else STACK_LABEL="no"; fi
  fi
}

# ---------------------------------------------------------------------------------------------
# Repository names and runner folders
# ---------------------------------------------------------------------------------------------

# Turns "repo" or "owner/repo" into "owner/repo" (owner defaults to GITHUB_OWNER). Rejects anything
# that isn't a plain GitHub name, because the result becomes part of folder names and URLs.
full_repository_name() {
  local input="$1" owner repository
  if [[ ${input} == */* ]]; then
    owner="${input%%/*}"
    repository="${input#*/}"
  else
    owner="${GITHUB_OWNER}"
    repository="${input}"
  fi
  [[ ${owner} =~ ^[A-Za-z0-9-]+$ ]] || die "not a GitHub account name: '${owner}'"
  [[ ${repository} =~ ^[A-Za-z0-9._-]+$ && ${repository} != "." && ${repository} != ".." ]] ||
    die "not a GitHub repository name: '${repository}'"
  echo "${owner}/${repository}"
}

# The lower-case repository name used in folder names, runner names and labels ("Sna-ke/GroundCore"
# gives "groundcore").
repository_slug() {
  local full="$1"
  tr '[:upper:]' '[:lower:]' <<<"${full##*/}"
}

# Prints one value from a runner's .runner file (JSON written by config.sh), or nothing if absent.
runner_config_value() {
  local file="$1" key="$2"
  jq -r --arg key "${key}" '.[$key] // empty' "${file}"
}

# Prints "owner/repo" for the runner in <directory>, from the gitHubUrl in its .runner file.
runner_repository() {
  local url
  url="$(runner_config_value "$1/.runner" gitHubUrl)"
  url="${url%/}"
  [[ ${url} == *://*/*/* ]] || return 1
  url="${url#*://*/}"
  echo "${url}"
}

# ---------------------------------------------------------------------------------------------
# Download, register, unregister
# ---------------------------------------------------------------------------------------------

# Downloads the latest runner release once and checks it against GitHub's published SHA-256:
# the release asset's digest, or the checksum GitHub lists in the release notes.
# Prints the path of the verified archive.
download_runner() {
  local architecture release version asset expected archive actual
  architecture="$(runner_architecture)"
  release="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
  version="$(jq -r '.tag_name | ltrimstr("v")' <<<"${release}")"
  asset="actions-runner-linux-${architecture}-${version}.tar.gz"
  archive="${DOWNLOAD_DIR}/${asset}"

  expected="$(jq -r --arg name "${asset}" '.assets[] | select(.name == $name) | .digest // empty' <<<"${release}")"
  expected="${expected#sha256:}"
  if [[ -z ${expected} ]]; then
    expected="$(jq -r '.body' <<<"${release}" |
      grep -oE "BEGIN SHA linux-${architecture} -->[0-9a-f]{64}" | grep -oE '[0-9a-f]{64}$' || true)"
  fi
  [[ ${expected} =~ ^[0-9a-f]{64}$ ]] || die "no published SHA-256 found for ${asset}"

  mkdir -p "${DOWNLOAD_DIR}"
  if [[ ! -f ${archive} ]]; then
    curl -fsSL -o "${archive}.part" \
      "https://github.com/actions/runner/releases/download/v${version}/${asset}"
    mv "${archive}.part" "${archive}"
  fi
  actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
  if [[ ${actual} != "${expected}" ]]; then
    rm -f "${archive}"
    die "SHA-256 mismatch for ${asset}: expected ${expected}, got ${actual}"
  fi
  echo "${archive}"
}

# Asks GitHub for a short-lived registration or removal token for one repository ("owner/repo").
# kind: registration-token | remove-token
runner_token() {
  local full="$1" kind="$2" token
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    token="$(curl -fsSL -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${full}/actions/runners/${kind}" | jq -r '.token')"
  else
    local action="New self-hosted runner"
    [[ ${kind} == "remove-token" ]] && action="the runner's Remove button"
    printf '    Paste a token for %s (Settings > Actions > Runners > %s): ' "${full}" "${action}" >/dev/tty
    read -r -s token </dev/tty
    printf '\n' >/dev/tty
  fi
  [[ -n ${token} && ${token} != "null" ]] || die "no ${kind} for ${full}"
  echo "${token}"
}

# Installs, registers and starts runner number <index> for one repository ("owner/repo"). Skips a runner
# that is already registered, so running it again only adds what is missing.
install_runner() {
  local full="$1" index="$2" archive="$3"
  local slug directory name labels token
  slug="$(repository_slug "${full}")"
  directory="${RUNNER_HOME}/${slug}-${index}"
  name="${RUNNER_NAME_PREFIX}-${slug}-${index}"
  labels="${slug}-ci"
  if [[ ${index} -eq 1 && ${STACK_LABEL} == "yes" ]]; then labels="${labels},${slug}-stack"; fi

  log "Runner ${name} (labels: ${labels})"
  if [[ -f ${directory}/.runner ]]; then
    note "already registered"
    return
  fi
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${directory}"
  tar -xzf "${archive}" -C "${directory}"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${directory}"
  "${directory}/bin/installdependencies.sh" >/dev/null

  token="$(runner_token "${full}" registration-token)"
  (cd "${directory}" && sudo -u "${RUNNER_USER}" ./config.sh --unattended --replace \
    --url "https://github.com/${full}" --token "${token}" \
    --name "${name}" --labels "${labels}" --work _work)
  (cd "${directory}" && ./svc.sh install "${RUNNER_USER}" >/dev/null && ./svc.sh start >/dev/null)
  note "registered and running"
}

# Stops and uninstalls the runner's service, then unregisters it from GitHub, so GitHub doesn't keep
# listing an offline runner. Leaves the folder in place; the caller decides whether to delete it.
unregister_runner() {
  local directory="${1%/}" full token
  full="$(runner_repository "${directory}")" || die "no gitHubUrl in ${directory}/.runner"
  (cd "${directory}" && ./svc.sh stop >/dev/null && ./svc.sh uninstall >/dev/null) || true
  token="$(runner_token "${full}" remove-token)"
  (cd "${directory}" && sudo -u "${RUNNER_USER}" ./config.sh remove --token "${token}")
}
