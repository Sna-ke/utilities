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

# The version of these scripts. Every pull request that changes setup-runner.sh, runner-lib.sh or
# ghrunner.sh raises it and adds a line to CHANGELOG.md; CI checks both (tests/version-check.sh).
# shellcheck disable=SC2034 # read by the scripts that source this file
GHRUNNER_VERSION="1.3.0"

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
# Where "ghrunner self-update" gets new versions, and the files that make up one.
# shellcheck disable=SC2034 # read by the scripts that source this file
GHRUNNER_REPO="${GHRUNNER_REPO:-Sna-ke/utilities}"
# shellcheck disable=SC2034 # read by the scripts that source this file
GHRUNNER_FILES=(setup-runner.sh runner-lib.sh ghrunner.sh)
TOOL_CACHE_DIR="/opt/hostedtoolcache"

# From a runner-lib.sh on stdin, prints its GHRUNNER_VERSION, or nothing for a copy older than 1.3.0.
version_from_text() {
  sed -nE 's/^GHRUNNER_VERSION="([^"]+)".*/\1/p' | head -n 1
}

# True when version <a> is newer than <b> (numeric order: 1.10.0 is newer than 1.9.0).
version_newer() {
  [[ $1 != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

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

# Number of CPU cores.
cpu_count() {
  nproc
}

# Runners per repository for <memory GB> and <cores>: each runner gets at least 5 GB and 3 cores, and
# there is always one. On OVH's range: VPS-1 (2 cores, 4 GB) and VPS-2 (4, 8) get 1; VPS-3 (6, 12) and
# VPS-4 (8, 24) get 2. The memory half is the original rule (2 runners from 10 GB); the core half stops
# two .NET builds sharing 4 cores.
auto_runner_count() {
  local by_memory=$(($1 / 5)) by_cores=$(($2 / 3)) count
  count=$((by_memory < by_cores ? by_memory : by_cores))
  echo $((count < 1 ? 1 : count))
}

# Resolves RUNNER_COUNT and STACK_LABEL when they are "auto", from the machine's memory and cores, so the
# same rules size runners whether setup-runner.sh or ghrunner registers them.
resolve_runner_settings() {
  local memory
  memory="$(memory_gb)"
  if [[ ${RUNNER_COUNT} == "auto" ]]; then
    RUNNER_COUNT="$(auto_runner_count "${memory}" "$(cpu_count)")"
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

# True when a runner's "owner/repo" is the repository the user named: compares the whole name when
# they gave an owner, else just the repository part. GitHub names ignore case.
repository_matches() {
  local wanted runner
  wanted="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  runner="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  if [[ ${wanted} == */* ]]; then [[ ${runner} == "${wanted}" ]]; else [[ ${runner##*/} == "${wanted}" ]]; fi
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

# Prints "<n>\t<folder>" for each runner of a repository ("owner/repo") on this machine, lowest number first:
# folders whose .runner names the repository and whose name is <repo-lowercase>-<n>.
repository_runner_dirs() {
  local full="$1" slug directory base index
  slug="$(repository_slug "${full}")"
  for directory in "${RUNNER_HOME}"/*/; do
    directory="${directory%/}"
    [[ -f ${directory}/.runner ]] || continue
    repository_matches "${full}" "$(runner_repository "${directory}" || true)" || continue
    base="${directory##*/}"
    index="${base#"${slug}"-}"
    [[ ${index} != "${base}" && ${index} =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "${index}" "${directory}"
  done | sort -n
}

# Prints "owner/repo" of every repository with runners on this machine, once each.
repositories_with_runners() {
  local directory
  for directory in "${RUNNER_HOME}"/*/; do
    [[ -f ${directory}.runner ]] || continue
    runner_repository "${directory%/}" || true
  done | sort -fu
}

# ---------------------------------------------------------------------------------------------
# Labels
#
# The runner keeps no local copy of its labels, so registration records them in <folder>/.labels.
# ---------------------------------------------------------------------------------------------

# The labels runner <index> of a repository should have: <slug>-ci, plus <slug>-stack on runner 1 when
# STACK_LABEL is on.
expected_labels() {
  local slug="$1" index="$2" labels="$1-ci"
  if [[ ${index} -eq 1 && ${STACK_LABEL} == "yes" ]]; then labels="${labels},${slug}-stack"; fi
  echo "${labels}"
}

# Puts a comma-separated label list (stdin) in a fixed order, so two lists can be compared.
sort_labels() {
  tr ',' '\n' | sed '/^$/d' | sort | paste -sd, -
}

# Prints a runner's labels, sorted: from .labels, or, for a runner registered before .labels existed,
# from GitHub when GITHUB_TOKEN is set (then recorded). Prints nothing when neither is available.
recorded_labels() {
  local directory="$1" full id labels
  if [[ -f ${directory}/.labels ]]; then
    sort_labels <"${directory}/.labels"
    return
  fi
  [[ -n ${GITHUB_TOKEN:-} ]] || return 0
  full="$(runner_repository "${directory}")" || return 0
  id="$(runner_config_value "${directory}/.runner" agentId)"
  labels="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${full}/actions/runners/${id}" |
    jq -r '[.labels[] | select(.type == "custom") | .name] | join(",")' || true)"
  [[ -n ${labels} ]] || return 0
  echo "${labels}" >"${directory}/.labels"
  sort_labels <<<"${labels}"
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

# True when the runner in <directory> is running a job right now (stopping it would cancel the job).
runner_is_busy() {
  local unit=""
  if [[ -f $1/.service ]]; then unit="$(<"$1/.service")"; fi
  unit_in_list "${unit}" "$(busy_units)"
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
  local slug directory name labels
  slug="$(repository_slug "${full}")"
  directory="${RUNNER_HOME}/${slug}-${index}"
  name="${RUNNER_NAME_PREFIX}-${slug}-${index}"
  labels="$(expected_labels "${slug}" "${index}")"

  log "Runner ${name} (labels: ${labels})"
  if [[ -f ${directory}/.runner ]]; then
    note "already registered"
    return
  fi
  install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${directory}"
  tar -xzf "${archive}" -C "${directory}"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${directory}"
  "${directory}/bin/installdependencies.sh" >/dev/null
  register_runner "${directory}" "${full}" "${name}" "${labels}"
  note "registered and running"
}

# Registers the runner in <directory> with GitHub under <name> and <labels>, records the labels, puts its
# .env in place, then installs and starts its service.
register_runner() {
  local directory="$1" full="$2" name="$3" labels="$4" token
  token="$(runner_token "${full}" registration-token)"
  (cd "${directory}" && sudo -u "${RUNNER_USER}" ./config.sh --unattended --replace \
    --url "https://github.com/${full}" --token "${token}" \
    --name "${name}" --labels "${labels}" --work _work)
  echo "${labels}" >"${directory}/.labels"
  chown "${RUNNER_USER}:${RUNNER_USER}" "${directory}/.labels"
  prepare_tool_cache
  write_runner_env "${directory}" || true
  (cd "${directory}" && ./svc.sh install "${RUNNER_USER}" >/dev/null && ./svc.sh start >/dev/null)
}

# Changes a runner's labels by unregistering and registering it again in the same folder, which keeps
# its work folder and installed tools. Only safe while it is idle.
reregister_runner() {
  local directory="$1" labels="$2" full name
  full="$(runner_repository "${directory}")" || die "no gitHubUrl in ${directory}/.runner"
  name="$(runner_config_value "${directory}/.runner" agentName)"
  unregister_runner "${directory}"
  register_runner "${directory}" "${full}" "${name}" "${labels}"
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

# Unregisters the runner in <directory> and deletes its folder.
remove_runner() {
  unregister_runner "$1"
  rm -rf -- "${1%/}"
}

# ---------------------------------------------------------------------------------------------
# Resizing: matching a repository's runners to what the machine fits
# ---------------------------------------------------------------------------------------------

RESIZE_ROWS=()
RESIZE_TODO=()
RUNNER_ARCHIVE=""

# True when registration and removal tokens can be had: GITHUB_TOKEN, or a terminal to paste them in.
token_available() {
  [[ -n ${GITHUB_TOKEN:-} ]] || { true </dev/tty; } 2>/dev/null
}

# The how-to for a step that needed a token and had none.
NO_TOKEN_HOW="needs a GitHub token, and there was neither GITHUB_TOKEN nor a terminal to paste one into. Run \
'sudo --preserve-env=GITHUB_TOKEN ghrunner resize' with GITHUB_TOKEN set, or run it from a terminal."

# Records one resize step: prints it, adds it to the summary, and when it wasn't done (a <why and how>
# is given) adds it to the to-do list.
resize_result() {
  local runner="$1" change="$2" result="$3" how="${4:-}"
  note "${runner}: ${change}: ${result}"
  RESIZE_ROWS+=("${runner}"$'\t'"${change}"$'\t'"${result}")
  if [[ -n ${how} ]]; then RESIZE_TODO+=("${runner} (${change}): ${how}"); fi
}

# Adds runner <index> of a repository: downloads the release once per run, then installs it.
resize_add() {
  local full="$1" index="$2" name="$3"
  if ! token_available; then
    resize_result "${name}" "add" "not done" "${NO_TOKEN_HOW}"
    return
  fi
  if [[ -z ${RUNNER_ARCHIVE} ]]; then RUNNER_ARCHIVE="$(download_runner)" || exit 1; fi
  if (install_runner "${full}" "${index}" "${RUNNER_ARCHIVE}"); then
    resize_result "${name}" "add" "done"
  else
    resize_result "${name}" "add" "failed" "the error is shown above. Fix it, then run 'sudo ghrunner resize' again."
  fi
}

# Removes a runner the machine no longer fits, unless it is busy or there is no token; then reports why
# and how to finish.
resize_remove() {
  local directory="$1" name="$2" change="remove (machine fits ${RUNNER_COUNT})"
  if runner_is_busy "${directory}"; then
    resize_result "${name}" "${change}" "not done" "it is running a job, and removing it now would cancel the job. \
Run 'sudo ghrunner resize' again once 'ghrunner status' shows it idle."
  elif ! token_available; then
    resize_result "${name}" "${change}" "not done" "${NO_TOKEN_HOW}"
  elif (remove_runner "${directory}"); then
    resize_result "${name}" "${change}" "done"
  else
    resize_result "${name}" "${change}" "failed" "GitHub didn't unregister it (error above). If it no longer appears \
under the repository's Settings > Actions > Runners, remove it here with: cd ${directory} && sudo ./svc.sh uninstall \
&& cd / && sudo rm -rf ${directory}"
  fi
}

# Gives a runner the labels it should have, re-registering it when they differ; reports when that can't
# be done now.
resize_labels() {
  local directory="$1" name="$2" want="$3" have
  have="$(recorded_labels "${directory}")"
  if [[ -z ${have} ]]; then
    resize_result "${name}" "check labels" "unknown" "it was registered before labels were recorded on this \
machine. Run 'sudo --preserve-env=GITHUB_TOKEN ghrunner resize' with GITHUB_TOKEN set, so ghrunner can read them from GitHub."
  elif [[ ${have} == "$(sort_labels <<<"${want}")" ]]; then
    resize_result "${name}" "keep" "labels ${want}"
  elif runner_is_busy "${directory}"; then
    resize_result "${name}" "labels ${have} -> ${want}" "not done" "it is running a job, and re-registering it \
now would cancel the job. Run 'sudo ghrunner resize' again once 'ghrunner status' shows it idle."
  elif ! token_available; then
    resize_result "${name}" "labels ${have} -> ${want}" "not done" "${NO_TOKEN_HOW}"
  elif (reregister_runner "${directory}" "${want}"); then
    resize_result "${name}" "labels ${have} -> ${want}" "done"
  else
    resize_result "${name}" "labels ${have} -> ${want}" "failed" "the error is shown above. Fix it, then run \
'sudo ghrunner resize' again."
  fi
}

# Matches one repository's runners to RUNNER_COUNT and STACK_LABEL (call resolve_runner_settings first):
# adds missing runners, fixes labels, and removes runners above the count, highest number first.
resize_repository() {
  local full="$1" slug index directory name
  local -A present=()
  slug="$(repository_slug "${full}")"
  log "${full}: ${RUNNER_COUNT} runner(s), stack label ${STACK_LABEL}"
  while IFS=$'\t' read -r index directory; do
    present["${index}"]="${directory}"
  done < <(repository_runner_dirs "${full}")

  for ((index = 1; index <= RUNNER_COUNT; index++)); do
    name="${RUNNER_NAME_PREFIX}-${slug}-${index}"
    if [[ -n ${present[${index}]+set} ]]; then
      directory="${present[${index}]}"
      name="$(runner_config_value "${directory}/.runner" agentName)"
      resize_labels "${directory}" "${name}" "$(expected_labels "${slug}" "${index}")"
    else
      resize_add "${full}" "${index}" "${name}"
    fi
  done
  while read -r index; do
    ((index > RUNNER_COUNT)) || continue
    directory="${present[${index}]}"
    resize_remove "${directory}" "$(runner_config_value "${directory}/.runner" agentName)"
  done < <(printf '%s\n' "${!present[@]}" | sort -rn)
}
