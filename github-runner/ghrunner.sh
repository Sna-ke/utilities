#!/usr/bin/env bash
# ghrunner: manages the GitHub Actions self-hosted runners on this host (the github-runner component).
# Installed as /usr/local/bin/ghrunner, a link to /usr/local/lib/hostctl/github-runner/ghrunner.sh.
#
# Usage: ghrunner <command> [arguments]   (run "ghrunner help" for the list)
#
# status, stats and help only read, and work without root (some details need the adm group or sudo to
# read the journal and runner folders). add, delete and resize need sudo. doctor, audit, update, prune,
# version and self-update are hostctl's, for the whole host: ghrunner passes them on.
#
# Secrets: none. Registration and removal tokens come from GITHUB_TOKEN (a fine-grained token, never
# written to disk) or are pasted when asked.

set -Eeuo pipefail

RUNNER_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOST_DIR="$(dirname "${RUNNER_DIR}")/host"
if [[ ! -f ${HOST_DIR}/host-lib.sh ]]; then
  printf '\nERROR: %s/host-lib.sh not found. Reinstall with the one-line install.\n' "${HOST_DIR}" >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/../host/host-lib.sh
. "${HOST_DIR}/host-lib.sh"
# shellcheck source=SCRIPTDIR/runner-lib.sh
. "${RUNNER_DIR}/runner-lib.sh"
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR
PROGRAM="ghrunner"

# ---------------------------------------------------------------------------------------------
# add / delete
# ---------------------------------------------------------------------------------------------

# ghrunner add <repo> [count]: registers runners 1..count for a repository, with the same folders,
# names and labels as setup-runner.sh. Existing runners are kept, so this also tops a repository up.
add() {
  require_root
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: ghrunner add <repo> [count]"
  local full archive index
  full="$(full_repository_name "$1")" || exit 1
  RUNNER_COUNT="${2:-${RUNNER_COUNT}}"
  [[ ${RUNNER_COUNT} =~ ^([1-9]|auto)$ ]] || die "count must be 1 to 9"
  id "${RUNNER_USER}" >/dev/null 2>&1 || die "there is no ${RUNNER_USER} user: run setup-runner.sh first"
  resolve_runner_settings

  log "Downloading the runner"
  archive="$(download_runner)" || exit 1
  note "verified $(basename "${archive}")"
  for ((index = 1; index <= RUNNER_COUNT; index++)); do
    install_runner "${full}" "${index}" "${archive}"
  done
  log "Runner settings (.env)"
  configure_runners
  note "all runners up to date"
  status
}

# ghrunner delete <repo>: stops, uninstalls and unregisters every runner of a repository, then deletes
# their folders. Runners are found by the gitHubUrl in their .runner file, not by folder name.
delete() {
  require_root
  [[ $# -eq 1 ]] || die "usage: ghrunner delete <repo>"
  local full directory runner_full busy deleted=0
  full="$(full_repository_name "$1")" || exit 1
  busy="$(busy_units)"
  for directory in "${RUNNER_HOME}"/*/; do
    directory="${directory%/}"
    [[ -f ${directory}/.runner ]] || continue
    runner_full="$(runner_repository "${directory}")" || continue
    repository_matches "$1" "${runner_full}" || continue
    log "Deleting $(basename "${directory}") (${runner_full})"
    if [[ -f ${directory}/.service ]] && unit_in_list "$(<"${directory}/.service")" "${busy}"; then
      note "it is running a job; stopping it cancels the job"
    fi
    remove_runner "${directory}"
    note "unregistered and its folder removed"
    deleted=$((deleted + 1))
  done
  ((deleted > 0)) || die "no runners for ${full} on this machine"
}

# ---------------------------------------------------------------------------------------------
# resize
# ---------------------------------------------------------------------------------------------

# Prints the summary of a resize and, if anything couldn't be done, a numbered list saying why and how
# to finish. Fails in that case, so resize exits 1.
resize_report() {
  local item number=0
  log "Summary"
  { printf 'RUNNER\tCHANGE\tRESULT\n'; printf '%s\n' "${RESIZE_ROWS[@]}"; } | print_table
  ((${#STILL_TO_DO[@]} > 0)) || return 0
  log "Still to do"
  for item in "${STILL_TO_DO[@]}"; do
    number=$((number + 1))
    printf '%d. %s\n' "${number}" "${item}"
  done
  return 1
}

# ghrunner resize [repo]: after the VM changes size, matches every repository's runners (or one
# repository's) to what the machine fits now: adds runners, fixes the stack label, and removes runners
# above the count. Whatever it can't do is listed with why and how, and it exits 1.
resize() {
  require_root
  [[ $# -le 1 ]] || die "usage: ghrunner resize [repo]"
  local full
  local -a repositories=()
  id "${RUNNER_USER}" >/dev/null 2>&1 || die "there is no ${RUNNER_USER} user: run setup-runner.sh first"
  if [[ $# -eq 1 ]]; then
    full="$(full_repository_name "$1")" || exit 1
    repositories=("${full}")
  else
    mapfile -t repositories < <(repositories_with_runners)
  fi
  if ((${#repositories[@]} == 0)); then
    note "No runners on this machine. Add some with: sudo ghrunner add <repo>"
    return
  fi
  resolve_runner_settings
  log "This machine: $(memory_gb) GB, $(cpu_count) cores"
  note "fits ${RUNNER_COUNT} runner(s) per repository; stack label ${STACK_LABEL}"
  for full in "${repositories[@]}"; do
    resize_repository "${full}"
  done
  log "Runner settings (.env)"
  configure_runners
  resize_report || exit 1
}

# ---------------------------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------------------------

# Prints one status row per runner unit: name, repository, service state, idle/busy, current job.
status_rows() {
  local busy unit active name slug state job
  busy="$(busy_units)"
  while IFS=$'\t' read -r unit active; do
    IFS=$'\t' read -r name slug _ <<<"$(unit_identity "${unit}")"
    job="-"
    if [[ ${active} != "active" ]]; then
      state="stopped"
    elif unit_in_list "${unit}" "${busy}"; then
      state="busy"
      job="$(unit_journal "${unit}" 500 | last_started_job)"
      job="${job:-?}"
    else
      state="idle"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${slug}" "${active}" "${state}" "${job}"
  done < <(runner_units)
}

# Prints a row for each runner folder whose service isn't installed (root only: folders are private).
unserviced_rows() {
  local directory base
  while read -r directory; do
    base="${directory##*/}"
    printf '%s\t%s\tnot installed\tstopped\t-\n' "${base}" "${base%-*}"
  done < <(unserviced_runner_dirs)
}

# ghrunner status: each runner with its service state, idle or busy, and the job it is running.
status() {
  no_arguments "$@"
  local rows
  rows="$(status_rows; unserviced_rows)"
  if [[ -z ${rows} ]]; then
    note "No runners on this machine. Add some with: sudo ghrunner add <repo>"
    return
  fi
  { printf 'RUNNER\tREPOSITORY\tSERVICE\tSTATE\tJOB\n'; printf '%s\n' "${rows}"; } | print_table
  if grep -q $'\t?$' <<<"${rows}" && ! can_read_journal; then
    note "Job names come from the journal: run with sudo, or join the adm group, to see them."
  fi
}

# ---------------------------------------------------------------------------------------------
# stats
# ---------------------------------------------------------------------------------------------

# Prints the "M" lines summarize_jobs needs: which runner and repository each unit in the events is.
unit_map() {
  local unit name slug
  while read -r unit; do
    [[ -n ${unit} ]] || continue
    IFS=$'\t' read -r name slug _ <<<"$(unit_identity "${unit}")"
    printf 'M\t%s\t%s\t%s\n' "${unit}" "${name}" "${slug}"
  done < <(cut -f2 <<<"$1" | sort -u)
}

# Prints the job table for events grouped by runner or repository.
job_table() {
  local by="$1" events="$2" map="$3" header
  header="$(tr '[:lower:]' '[:upper:]' <<<"${by}")"
  {
    printf '%s\tSTARTED\tCOMPLETED\tSUCCEEDED\tFAILED\tCANCELLED\tOTHER\tAVERAGE TIME\n' "${header}"
    { printf '%s\n' "${map}"; awk '{ print "E\t" $0 }' <<<"${events}"; } | summarize_jobs "${by}"
  } | print_table
}

# Prints disk, memory, swap, last clean-up and last reboot as a two-column table.
machine_table() {
  local size used available memory_total memory_available swap_total swap_free prune
  read -r size used available <<<"$(disk_bytes /)"
  memory_total="$(meminfo_bytes MemTotal)"
  memory_available="$(meminfo_bytes MemAvailable)"
  swap_total="$(meminfo_bytes SwapTotal)"
  swap_free="$(meminfo_bytes SwapFree)"
  prune="$(last_prune_epoch)"
  if [[ -n ${prune} ]]; then
    prune="$(when_was "${prune}")"
  elif can_read_journal; then
    prune="none logged yet"
  else
    prune="unknown: run with sudo to read the journal"
  fi
  {
    printf 'ITEM\tVALUE\n'
    printf 'Disk /\t%s used of %s (%s%% free)\n' "$(human_bytes "${used}")" "$(human_bytes "${size}")" \
      "$((available * 100 / size))"
    printf 'Memory\t%s used of %s\n' "$(human_bytes $((memory_total - memory_available)))" "$(human_bytes "${memory_total}")"
    if ((swap_total > 0)); then
      printf 'Swap\t%s used of %s\n' "$(human_bytes $((swap_total - swap_free)))" "$(human_bytes "${swap_total}")"
    else
      printf 'Swap\toff\n'
    fi
    printf 'Last clean-up\t%s\n' "${prune}"
    printf 'Last reboot\t%s\n' "$(when_was "$(boot_epoch)")"
  } | print_table
}

# ghrunner stats [days]: jobs per runner and per repository from the journal, then disk, Docker,
# memory, swap, the last clean-up and the last reboot.
stats() {
  [[ $# -le 1 ]] || die "usage: ghrunner stats [days]"
  local days="${1:-7}" events map
  [[ ${days} =~ ^[1-9][0-9]{0,3}$ ]] || die "days must be a whole number from 1 to 9999"
  events="$(job_events "${days}")"
  map="$(unit_map "${events}")"

  log "Jobs in the last ${days} day(s), per runner"
  if [[ -z ${events} ]]; then
    note "No jobs in the journal for this period."
    can_read_journal || note "The journal isn't readable for you: run with sudo, or join the adm group."
  else
    job_table runner "${events}" "${map}"
    log "Jobs in the last ${days} day(s), per repository"
    job_table repository "${events}" "${map}"
  fi

  log "Machine"
  machine_table

  log "Docker disk use"
  if docker_reachable; then docker system df; else note "Docker isn't reachable for you: run with sudo."; fi
}

# ---------------------------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------------------------

# ghrunner help: the command list.
usage() {
  printf 'ghrunner (hostctl %s)\n\n' "${TOOLS_VERSION}"
  # "|| true": a reader that stops early (ghrunner help | head) is not an error.
  cat <<'EOF' || true
Usage: ghrunner <command> [arguments]

Commands              What it does                                                     Needs sudo
  add <repo> [count]  register runners 1..count for a repository (count: auto)         yes
  delete <repo>       stop, unregister and remove a repository's runners               yes
  resize [repo]       after a VM resize: add, relabel or remove runners to fit         yes
  status              each runner: service, idle or busy, current job                  no
  stats [days]        jobs, results and durations (default 7 days), disk, memory       no
  help                this text                                                        no

For the whole host (these run hostctl): doctor [--fix], audit [--accept], update, prune, version,
self-update.

<repo> is "repo" (owner: GITHUB_OWNER, default Sna-ke) or "owner/repo", e.g. example-org/example-app.
add, delete and resize get tokens from GITHUB_TOKEN (fine-grained, Administration: read and write;
never stored) or ask you to paste one:  sudo --preserve-env=GITHUB_TOKEN ghrunner add example-app
EOF
}

# Runs the command named on the command line; the host-wide ones go to hostctl.
main() {
  COMMAND_LINE="$*"
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "${command}" in
    add) add "$@" ;;
    delete) delete "$@" ;;
    resize) resize "$@" ;;
    status) status "$@" ;;
    stats) stats "$@" ;;
    doctor | audit | update | prune | version | --version | self-update) exec bash "${HOST_DIR}/hostctl.sh" "${command}" "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2 && die "unknown command '${command}'" ;;
  esac
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
