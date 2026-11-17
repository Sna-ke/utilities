# shellcheck shell=bash
# Shared by setup-runner.sh and ghrunner.sh: settings, messages, machine facts, and the code that downloads,
# verifies, registers and unregisters runners. Sourced, never run on its own.
#
# Conventions both scripts rely on:
#   - runners live in /home/runner/<repo-lowercase>-<n>
#   - runner names are <hostname>-<repo-lowercase>-<n>
#   - labels are <repo>-ci, plus <repo>-stack on runner 1 when the machine has 6 GB of RAM or more
#   - each runner's .runner file holds gitHubUrl; its systemd unit is actions.runner.*
#   - each runner's .env file sets where tools install (runner_env_settings), because the setup actions
#     assume GitHub's own runner image, where system folders are writable
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
TOOL_CACHE_DIR="/opt/hostedtoolcache"

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
# Busy runners
# ---------------------------------------------------------------------------------------------

# Prints the actions.runner.* unit named in a /proc/<pid>/cgroup file read from stdin.
unit_from_cgroup() {
  grep -m 1 -oE 'actions\.runner\.[^/]*\.service'
}

# True when <unit> is one of the lines of <list> (e.g. the busy units).
unit_in_list() {
  [[ -n $1 ]] && grep -qxF -- "$1" <<<"$2"
}

# Prints the unit of every runner with a Runner.Worker process, i.e. a job in progress. The worker runs
# inside its runner's service, so its cgroup, which any user can read, names the runner.
busy_units() {
  local pid
  while read -r pid; do
    unit_from_cgroup 2>/dev/null <"/proc/${pid}/cgroup" || true
  done < <(pgrep -x Runner.Worker || true) | sort -u
}

# ---------------------------------------------------------------------------------------------
# Where jobs install tools (each runner's .env file)
# ---------------------------------------------------------------------------------------------

# Prints the settings every runner's .env file gets. The runner reads .env when it starts and passes the
# values to every job, so workflows need no changes.
#   DOTNET_INSTALL_DIR   actions/setup-dotnet installs to /usr/share/dotnet by default, which the runner
#                        user can't write. One folder per runner, so two jobs never install into the same one.
#   AGENT_TOOLSDIRECTORY, RUNNER_TOOL_CACHE
#                        the tool cache. GitHub's prebuilt Python (setup-python) and Ruby (setup-ruby) only
#                        work from /opt/hostedtoolcache, the path they were built in. Shared by all runners.
runner_env_settings() {
  printf 'DOTNET_INSTALL_DIR=%s/.dotnet\n' "$1"
  printf 'AGENT_TOOLSDIRECTORY=%s\n' "${TOOL_CACHE_DIR}"
  printf 'RUNNER_TOOL_CACHE=%s\n' "${TOOL_CACHE_DIR}"
}

# Merges KEY=value settings (the arguments) into .env text read from stdin: replaces lines with the same
# key, appends missing settings, and keeps every other line (config.sh writes LANG and similar there).
merge_env() {
  local line key
  local -A wanted=() written=()
  local -a keys=()
  for line in "$@"; do
    key="${line%%=*}"
    wanted["${key}"]="${line}"
    keys+=("${key}")
  done
  while IFS= read -r line || [[ -n ${line} ]]; do
    key="${line%%=*}"
    if [[ -z ${key} || -z ${wanted[${key}]+set} ]]; then
      printf '%s\n' "${line}"
    elif [[ -z ${written[${key}]+set} ]]; then
      printf '%s\n' "${wanted[${key}]}"
      written["${key}"]=1
    fi
  done
  for key in "${keys[@]}"; do
    if [[ -z ${written[${key}]+set} ]]; then printf '%s\n' "${wanted[${key}]}"; fi
  done
}

# Writes the settings into a runner's .env file, owned by the runner user. Succeeds only when the file
# changed, so callers know the runner needs a restart to read it.
write_runner_env() {
  local directory="$1" file="$1/.env" current="" updated
  local -a env_settings
  mapfile -t env_settings < <(runner_env_settings "${directory}")
  if [[ -f ${file} ]]; then current="$(<"${file}")"; fi
  updated="$(printf '%s' "${current}" | merge_env "${env_settings[@]}")"
  [[ ${updated} != "${current}" ]] || return 1
  printf '%s\n' "${updated}" >"${file}.new"
  chown "${RUNNER_USER}:${RUNNER_USER}" "${file}.new"
  mv "${file}.new" "${file}"
}

# Creates the shared tool cache, owned by the runner user. Safe to repeat.
prepare_tool_cache() {
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${TOOL_CACHE_DIR}"
}

# Brings every runner on this machine up to date with runner_env_settings, restarting a runner whose
# .env changed so it reads it. A runner in the middle of a job is left running (a restart would cancel
# the job), with the command to restart it later.
configure_runners() {
  local directory unit busy
  prepare_tool_cache
  busy="$(busy_units)"
  for directory in "${RUNNER_HOME}"/*/; do
    directory="${directory%/}"
    [[ -f ${directory}/.runner ]] || continue
    write_runner_env "${directory}" || continue
    unit=""
    if [[ -f ${directory}/.service ]]; then unit="$(<"${directory}/.service")"; fi
    if [[ -z ${unit} ]]; then
      note "${directory##*/}: settings updated"
    elif unit_in_list "${unit}" "${busy}"; then
      note "${directory##*/}: settings updated; it is running a job, so restart it afterwards: sudo systemctl restart ${unit}"
    else
      systemctl restart "${unit}"
      note "${directory##*/}: settings updated and runner restarted"
    fi
  done
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

# Installs, registers and starts runner number <index> for one repository ("owner/repo"), with its .env
# settings in place before it first starts. Skips a runner that is already registered, so running it
# again only adds what is missing.
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
  prepare_tool_cache
  write_runner_env "${directory}" || true
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
