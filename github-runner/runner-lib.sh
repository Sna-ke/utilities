# shellcheck shell=bash
# The GitHub runner component: settings, the code that downloads, registers, resizes and unregisters
# runners, its doctor checks, and its hostctl hooks (prefix "runner", see host/host-lib.sh). Sourced by
# ghrunner.sh and by hostctl, after host/host-lib.sh; never run on its own.
#
# Conventions:
#   - runners live in /home/runner/<repo-lowercase>-<n>
#   - runner names are <hostname>-<repo-lowercase>-<n>
#   - labels are <repo>-ci, plus <repo>-stack on runner 1 when the machine has 6 GB of RAM or more
#   - each runner's .runner file holds gitHubUrl; its systemd unit is actions.runner.*
#   - each runner's .env file sets where tools install (runner_env_settings), because the setup actions
#     assume GitHub's own runner image, where system folders are writable
#
# Settings (environment variables, all optional):
#   RUNNER_REPOS        [GroundCore]  repositories to serve, comma-separated ("repo" or "owner/repo")
#   GITHUB_OWNER        [Sna-ke]      owner of repositories given without one
#   RUNNER_COUNT        [auto]        runners per repository; auto = one per 5 GB of RAM and 3 cores, at least 1
#   STACK_LABEL         [auto]        add <repo>-stack to runner 1; auto = yes with 6 GB of RAM or more
#   RUNNER_NAME_PREFIX  [hostname]    runner names are <prefix>-<repo>-<n>
#   GITHUB_TOKEN        [none]        fine-grained token (Administration: read and write) for registering;
#                                     never written to disk. Without it, setup asks you to paste tokens.

RUNNER_REPOS="${RUNNER_REPOS:-GroundCore}"
GITHUB_OWNER="${GITHUB_OWNER:-Sna-ke}"
RUNNER_COUNT="${RUNNER_COUNT:-auto}"
STACK_LABEL="${STACK_LABEL:-auto}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s)}"
RUNNER_USER="runner"
RUNNER_HOME="/home/${RUNNER_USER}"
DOWNLOAD_DIR="/var/cache/actions-runner"
TOOL_CACHE_DIR="/opt/hostedtoolcache"

# ---------------------------------------------------------------------------------------------
# Machine facts
# ---------------------------------------------------------------------------------------------

# The runner release's name for this CPU.
runner_architecture() {
  case "$(uname -m)" in
    x86_64) echo "x64" ;;
    aarch64) echo "arm64" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
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

# Turns GitHub's answer to GET /repos/<owner>/<repo> without a token (<HTTP status> and <body>) into
# "public", "private" or "unknown". Without a token GitHub hides private repositories, so 404 means private.
visibility_from_response() {
  case "$1" in
    200) jq -r 'if .private then "private" else "public" end' <<<"$2" 2>/dev/null || echo "unknown" ;;
    404) echo "private" ;;
    *) echo "unknown" ;;
  esac
}

# Prints "public", "private" or "unknown" (GitHub unreachable) for a repository ("owner/repo").
repository_visibility() {
  local response
  response="$(curl -sS --max-time 20 -w '\n%{http_code}' "https://api.github.com/repos/$1" 2>/dev/null)" || {
    echo "unknown"
    return
  }
  visibility_from_response "${response##*$'\n'}" "${response%$'\n'*}"
}

# Why runners are never registered for a public repository, for messages.
PUBLIC_REPOSITORY_WHY="it is a public repository: anyone can open a pull request there, and on a self-hosted \
runner its workflow would run as root on this VM. Use GitHub's hosted runners for it."

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
  [[ "$(repository_visibility "${full}")" != "public" ]] || die "not registering ${name}: ${PUBLIC_REPOSITORY_WHY}"
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
RUNNER_ARCHIVE=""

# True when registration and removal tokens can be had: GITHUB_TOKEN, or a terminal to paste them in.
token_available() {
  [[ -n ${GITHUB_TOKEN:-} ]] || has_terminal
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
  if [[ -n ${how} ]]; then STILL_TO_DO+=("${runner} (${change}): ${how}"); fi
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
  if [[ "$(repository_visibility "${full}")" == "public" ]]; then
    resize_result "${full}" "add, relabel or remove runners" "not done" "${PUBLIC_REPOSITORY_WHY} \
Remove any runners it has with 'sudo ghrunner delete ${full}'."
    return
  fi
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

# ---------------------------------------------------------------------------------------------
# Finding runners and reading their output
#
# Runner folders under /home/runner are only readable by root (Ubuntu makes home folders 0750), so the
# read-only commands find runners through systemd, which any user can query.
# ---------------------------------------------------------------------------------------------

# From "systemctl list-units --plain --no-legend" on stdin, prints "<unit>\t<active state>" for each
# runner unit. Skips the "●" systemd puts before failed units.
parse_unit_list() {
  awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /^actions\.runner\..*\.service$/) { print $i "\t" $(i + 2); next }
  }'
}

# Lists every runner unit systemd has loaded, running or not.
runner_units() {
  systemctl list-units --all --plain --no-legend --no-pager --type=service 'actions.runner.*' 2>/dev/null |
    parse_unit_list || true
}

# Undoes systemd's \xNN escaping in a unit name (the runner's svc.sh may escape "-" as \x2d).
decode_unit_name() {
  printf '%b' "$1"
}

# For a unit named by our conventions, actions.runner.<owner>-<repo>.<prefix>-<repo-lowercase>-<n>.service,
# prints "<runner name>\t<repo-lowercase>\t<n>". Fails for any other name (renamed or truncated units).
parse_unit_name() {
  local text lower match prefix slug index length
  text="$(decode_unit_name "$1")"
  text="${text#actions.runner.}"
  text="${text%.service}"
  lower="$(tr '[:upper:]' '[:lower:]' <<<"${text}")"
  # The repository appears twice: after the owner, and inside the runner name. \1 makes them agree.
  match="$(sed -nE 's/^[^.]*-(.+)\.([^.]*)-\1-([0-9]+)$/\2\t\1\t\3/p' <<<"${lower}")"
  [[ -n ${match} ]] || return 1
  IFS=$'\t' read -r prefix slug index <<<"${match}"
  length=$((${#prefix} + ${#slug} + ${#index} + 2))
  printf '%s\t%s\t%s\n' "${text: -length}" "${slug}" "${index}"
}

# Prints "<runner name>\t<repo-lowercase>\t<n>" for any runner unit: from its name when it follows the
# conventions, else from its folder (<repo-lowercase>-<n>), else the bare unit name for a removed runner.
unit_identity() {
  local unit="$1" parsed directory base
  parsed="$(parse_unit_name "${unit}")" || parsed=""
  if [[ -n ${parsed} ]]; then
    echo "${parsed}"
    return
  fi
  directory="$(systemctl show -p WorkingDirectory --value "${unit}" 2>/dev/null || true)"
  base="${directory##*/}"
  if [[ ${base} =~ ^(.+)-([0-9]+)$ ]]; then
    printf '%s\t%s\t%s\n' "${base}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return
  fi
  base="$(decode_unit_name "${unit}")"
  base="${base#actions.runner.}"
  printf '%s\tunknown\t-\n' "${base%.service}"
}

# Prints runner folders that have a .runner file but no installed service (only visible to root).
unserviced_runner_dirs() {
  local directory units
  units="$(runner_units | cut -f1)"
  for directory in "${RUNNER_HOME}"/*/; do
    directory="${directory%/}"
    [[ -f ${directory}/.runner ]] || continue
    if [[ -f ${directory}/.service ]] && unit_in_list "$(<"${directory}/.service")" "${units}"; then continue; fi
    echo "${directory}"
  done
}

# Prints the last <count> lines a runner unit wrote (message text only). Empty when the journal isn't
# readable for this user.
unit_journal() {
  journalctl -u "$1" -n "${2:-500}" -o cat --no-pager 2>/dev/null || true
}

# From runner output on stdin, prints the name of the most recently started job.
last_started_job() {
  sed -nE 's/^.*Running job: (.*)$/\1/p' | tail -n 1
}

# From runner output on stdin, prints the version the runner reported when it last started.
last_reported_version() {
  sed -nE "s/^.*Current runner version: '([^']+)'.*$/\1/p" | tail -n 1
}

# From "journalctl -o json" on stdin, prints "<epoch seconds>\t<unit>\t<message>" for each job start
# ("Running job: X") and end ("Job X completed with result: Y"). Not @tsv: it would double the
# backslashes in systemd-escaped unit names (\x2d), and they must match systemctl's spelling.
journal_json_to_events() {
  jq -r 'select((.MESSAGE | type) == "string")
    | select(.MESSAGE | test("Running job: |completed with result: "))
    | [(.__REALTIME_TIMESTAMP | tonumber / 1000000 | floor | tostring), (._SYSTEMD_UNIT // ""), .MESSAGE]
    | map(gsub("[\t\n\r]"; " ")) | join("\t")'
}

# Prints job start and end events of every runner, past and present, for the last <days> days.
job_events() {
  journalctl -u 'actions.runner.*' --since "$1 days ago" -o json --output-fields=MESSAGE,_SYSTEMD_UNIT \
    --no-pager 2>/dev/null | journal_json_to_events || true
}

# Reads "M\t<unit>\t<runner name>\t<repo>" lines (which runner and repository each unit is) followed by
# "E\t<epoch>\t<unit>\t<message>" events, and prints one row per runner or repository (by = runner |
# repository): started, completed, succeeded, failed, cancelled, other results, average duration.
# A job's duration is the time between its start and end lines on the same runner.
summarize_jobs() {
  awk -F'\t' -v by="$1" '
    function duration(s) {
      s = int(s + 0.5)
      if (s >= 3600) return sprintf("%dh %02dm", int(s / 3600), int((s % 3600) / 60))
      if (s >= 60) return sprintf("%dm %02ds", int(s / 60), s % 60)
      return s "s"
    }
    $1 == "M" { group[$2] = (by == "repository") ? $4 : $3; next }
    $1 != "E" { next }
    {
      unit = $3
      key = (unit in group) ? group[unit] : unit
      seen[key] = 1
      if ($4 ~ /Running job: /) {
        started[key]++
        start[unit] = $2
      } else if (match($4, /completed with result: [A-Za-z]+/)) {
        result = substr($4, RSTART + 23, RLENGTH - 23)
        completed[key]++
        if (result == "Succeeded") succeeded[key]++
        else if (result == "Failed") failed[key]++
        else if (result == "Canceled" || result == "Cancelled") cancelled[key]++
        else other[key]++
        if (unit in start) { total[key] += $2 - start[unit]; timed[key]++; delete start[unit] }
      }
    }
    END {
      for (key in seen) {
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", key, started[key], completed[key], succeeded[key],
          failed[key], cancelled[key], other[key], (timed[key] ? duration(total[key] / timed[key]) : "-")
      }
    }' | sort
}

# Prints the version a runner reports: from its journal, or by asking its binary when the folder is
# readable (root). "unknown" if neither works.
runner_version() {
  local unit="$1" version directory
  version="$(unit_journal "${unit}" 5000 | last_reported_version)"
  if [[ -z ${version} ]]; then
    directory="$(systemctl show -p WorkingDirectory --value "${unit}" 2>/dev/null || true)"
    if [[ -n ${directory} && -x ${directory}/bin/Runner.Listener ]]; then
      version="$(timeout 30 "${directory}/bin/Runner.Listener" --version 2>/dev/null | tr -d '[:space:]' || true)"
    fi
  fi
  echo "${version:-unknown}"
}

# Prints the latest runner release's version from GitHub, or "unknown" when GitHub can't be reached.
latest_runner_version() {
  curl -fsSL --max-time 20 https://api.github.com/repos/actions/runner/releases/latest 2>/dev/null |
    jq -r '.tag_name | ltrimstr("v")' 2>/dev/null || echo "unknown"
}

# Compares a runner's version with the latest release, in words for the update table.
version_status() {
  local version="$1" latest="$2"
  if [[ ${version} == "unknown" || ${latest} == "unknown" ]]; then
    echo "can't tell"
  elif [[ ${version} == "${latest}" ]]; then
    echo "up to date"
  elif [[ "$(printf '%s\n%s\n' "${version}" "${latest}" | sort -V | head -n 1)" == "${version}" ]]; then
    echo "older: it updates itself"
  else
    echo "newer than the latest release"
  fi
}

# Waits until no runner is running a job, checking every minute for up to <minutes>. Fails if they
# stay busy that long.
wait_until_idle() {
  local minutes="$1" waited=0
  while [[ -n "$(busy_units)" ]]; do
    ((waited < minutes)) || return 1
    sleep 60
    waited=$((waited + 1))
  done
}

PAUSED_UNITS=()

# Stops every running runner, so no job starts while packages (Docker among them) are upgraded.
pause_runners() {
  local unit active
  while IFS=$'\t' read -r unit active; do
    [[ ${active} == "active" ]] || continue
    systemctl stop "${unit}"
    PAUSED_UNITS+=("${unit}")
  done < <(runner_units)
}

# Starts the runners pause_runners stopped.
resume_runners() {
  local unit
  for unit in "${PAUSED_UNITS[@]}"; do systemctl start "${unit}" || true; done
  PAUSED_UNITS=()
}

# ---------------------------------------------------------------------------------------------
# Doctor checks
# ---------------------------------------------------------------------------------------------

# Runner services: a stopped service means GitHub shows the runner offline and jobs queue.
check_runner_services() {
  local units stopped
  units="$(runner_units)"
  if [[ -z ${units} ]]; then
    record WARN "Runner services" "no runners on this machine"
    return
  fi
  stopped="$(awk -F'\t' '$2 != "active" { print $1 }' <<<"${units}" | while read -r unit; do
    unit_identity "${unit}" | cut -f1
  done | paste -sd, -)"
  if [[ -n ${stopped} ]]; then
    record FAIL "Runner services" "not active: ${stopped}"
  else
    record PASS "Runner services" "$(wc -l <<<"${units}") active"
  fi
}

# Lists runner folders whose .env lacks any of runner_env_settings, comma-separated (root only).
runners_missing_settings() {
  local directory setting
  for directory in "${RUNNER_HOME}"/*/; do
    directory="${directory%/}"
    [[ -f ${directory}/.runner ]] || continue
    while read -r setting; do
      if ! grep -qxF -- "${setting}" "${directory}/.env" 2>/dev/null; then
        echo "${directory##*/}"
        break
      fi
    done < <(runner_env_settings "${directory}")
  done | paste -sd, -
}

# From runner unit identities ("<name>\t<repo>\t<n>") on stdin, prints "<repo> has <n>" for each
# repository whose runner count isn't <wanted>.
count_mismatches() {
  awk -F'\t' -v wanted="$1" '$2 != "unknown" { count[$2]++ }
    END { for (repo in count) if (count[repo] != wanted) printf "%s has %d\n", repo, count[repo] }' | sort
}

# Lists runners (root only: .labels is in their folders) whose recorded labels differ from the rule.
label_mismatches() {
  local full index directory
  while read -r full; do
    while IFS=$'\t' read -r index directory; do
      [[ -f ${directory}/.labels ]] || continue
      if [[ "$(sort_labels <"${directory}/.labels")" != "$(expected_labels "$(repository_slug "${full}")" "${index}" | sort_labels)" ]]; then
        echo "${directory##*/} labels"
      fi
    done < <(repository_runner_dirs "${full}")
  done < <(repositories_with_runners)
}

# Sizing: after the VM is resized, the runners and stack label no longer match what it fits.
check_sizing() {
  local units problems
  units="$(runner_units)"
  if [[ -z ${units} ]]; then
    record PASS "Sizing" "no runners"
    return
  fi
  resolve_runner_settings
  problems="$({
    while IFS=$'\t' read -r unit _; do unit_identity "${unit}"; done <<<"${units}" | count_mismatches "${RUNNER_COUNT}"
    if [[ ${EUID} -eq 0 ]]; then label_mismatches; fi
  } | paste -sd, - | sed 's/,/, /g')"
  if [[ -n ${problems} ]]; then
    record WARN "Sizing" "machine fits ${RUNNER_COUNT} per repository; ${problems}" fix
  else
    record PASS "Sizing" "${RUNNER_COUNT} runner(s) per repository fits $(memory_gb) GB, $(cpu_count) cores"
  fi
}

# Tool locations: without them, setup-dotnet, setup-python and setup-ruby fail with "Permission denied".
check_tool_settings() {
  local owner missing
  owner="$(stat -c %U "${TOOL_CACHE_DIR}" 2>/dev/null || true)"
  if [[ ${owner} != "${RUNNER_USER}" ]]; then
    record WARN "Tool locations" "${TOOL_CACHE_DIR} ${owner:+is owned by ${owner}}${owner:-missing}" fix
  elif [[ ${EUID} -ne 0 ]]; then
    record PASS "Tool locations" "${TOOL_CACHE_DIR} ready (run with sudo to check each runner's .env)"
  elif missing="$(runners_missing_settings)" && [[ -n ${missing} ]]; then
    record WARN "Tool locations" ".env settings missing for ${missing}" fix
  else
    record PASS "Tool locations" "${TOOL_CACHE_DIR} ready; every runner's .env set"
  fi
}

# Public repositories: a self-hosted runner lets anyone's pull request run as root here (root only:
# the repository names are in the runners' folders).
check_public_repositories() {
  [[ ${EUID} -eq 0 ]] || return 0
  local full public=""
  while read -r full; do
    [[ -n ${full} ]] || continue
    if [[ "$(repository_visibility "${full}")" == "public" ]]; then public="${public:+${public}, }${full}"; fi
  done < <(repositories_with_runners)
  if [[ -n ${public} ]]; then
    record FAIL "Private repositories" "public, remove their runners: ${public} (sudo ghrunner delete <repo>)"
  else
    record PASS "Private repositories" "every repository with runners here is private"
  fi
}

# ---------------------------------------------------------------------------------------------
# hostctl hooks
# ---------------------------------------------------------------------------------------------

# Docker group membership is already root-equivalent, and Playwright's --with-deps installs browser
# libraries with apt, so the runner user may sudo. That is why this VM must hold no secrets of its own.
create_runner_user() {
  log "Creating the ${RUNNER_USER} user"
  if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${RUNNER_USER}" >/dev/null
  fi
  usermod -aG docker "${RUNNER_USER}"
  local sudoers=/etc/sudoers.d/${RUNNER_USER}
  echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" >"${sudoers}.new"
  visudo -cqf "${sudoers}.new" || die "sudoers file failed its check"
  chmod 440 "${sudoers}.new"
  mv "${sudoers}.new" "${sudoers}"
}

# hostctl hook "setup": creates the runner user, sizes the runners for this machine (adds, relabels and
# removes them, for RUNNER_REPOS and every repository already here), and updates every runner's .env.
runner_setup() {
  local repository full
  local -a repositories requested=()
  create_runner_user
  resolve_runner_settings
  note "$(memory_gb) GB, $(cpu_count) cores: ${RUNNER_COUNT} runner(s) per repository, stack label ${STACK_LABEL}"
  IFS=',' read -r -a repositories <<<"${RUNNER_REPOS}"
  for repository in "${repositories[@]}"; do
    full="$(full_repository_name "${repository}")" || exit 1
    requested+=("${full}")
  done
  mapfile -t repositories < <({ printf '%s\n' "${requested[@]}"; repositories_with_runners; } | sort -fu)
  for full in "${repositories[@]}"; do
    resize_repository "${full}"
  done
  log "Runner settings (.env)"
  configure_runners
  note "all runners up to date"
}

# hostctl hook: the ghrunner command.
runner_install_commands() {
  ln -sfn "${TOOLS_DIR}/github-runner/ghrunner.sh" /usr/local/bin/ghrunner
}

# hostctl hook: what to do after setup.
runner_notes() {
  note "Next, in each repository: Settings > Secrets and variables > Actions > Variables."
  note "GroundCore: CI_RUNNER=groundcore-ci; CI_STACK_RUNNER=groundcore-stack only if a runner has that label."
  note "Runners: ghrunner status"
}

# hostctl hook: the runner's doctor checks.
runner_checks() {
  check_runner_services
  check_sizing
  check_public_repositories
  check_tool_settings
}

# hostctl hook: before the weekly update, waits up to 3 hours until no job is running, then stops the
# runners so none starts while Docker is upgraded. Fails (and the update is skipped) if they stay busy.
runner_pause() {
  log "Waiting until no job is running (up to 3 hours)"
  wait_until_idle 180 || return 1
  pause_runners
  note "paused ${#PAUSED_UNITS[@]} runner(s) for the upgrade"
}

# hostctl hook: starts the runners runner_pause stopped.
runner_resume() {
  if ((${#PAUSED_UNITS[@]} > 0)); then
    resume_runners
    note "runners started again"
  fi
}

# hostctl hook: after "hostctl update", each runner's version against the latest release (runners update
# themselves, so this only reports).
runner_update_report() {
  local latest unit name version
  log "Runner versions"
  latest="$(latest_runner_version)"
  {
    printf 'RUNNER\tVERSION\tLATEST\tSTATUS\n'
    while IFS=$'\t' read -r unit _; do
      IFS=$'\t' read -r name _ <<<"$(unit_identity "${unit}")"
      version="$(runner_version "${unit}")"
      printf '%s\t%s\t%s\t%s\n' "${name}" "${version}" "${latest}" "$(version_status "${version}" "${latest}")"
    done < <(runner_units)
  } | print_table
}

# hostctl hook: CI leaves images, build cache and volumes behind, so the weekly clean-up takes all three.
runner_prune_level() {
  echo "full"
}

# hostctl hook: the runner user must never log in over SSH.
runner_ssh_deny_users() {
  echo "${RUNNER_USER}"
}
