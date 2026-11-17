#!/usr/bin/env bash
# ghrunner: manages the GitHub Actions self-hosted runners that setup-runner.sh put on this machine.
#
# Usage: ghrunner <command> [arguments]   (run "ghrunner help" for the list)
#
# setup-runner.sh installs this file as /usr/local/bin/ghrunner and runner-lib.sh, which both scripts
# share, as /usr/local/lib/ghrunner/runner-lib.sh. Run from a checkout, it uses the runner-lib.sh next to it.
#
# status, stats, doctor and help only read, and work without root (some details need the adm group or
# sudo to read the journal and runner folders). add, delete, update and prune change the machine and need sudo.
#
# Secrets: none. Registration and removal tokens come from GITHUB_TOKEN (a fine-grained token, never
# written to disk) or are pasted when asked, exactly as in setup-runner.sh.

set -Eeuo pipefail

GHRUNNER_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for GHRUNNER_LIB in "${GHRUNNER_SELF_DIR}/runner-lib.sh" /usr/local/lib/ghrunner/runner-lib.sh; do
  [[ -f ${GHRUNNER_LIB} ]] && break
done
if [[ ! -f ${GHRUNNER_LIB} ]]; then
  printf '\nERROR: runner-lib.sh not found. Run setup-runner.sh again to reinstall ghrunner.\n' >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/runner-lib.sh
. "${GHRUNNER_LIB}"
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR

GHRUNNER_COMMAND_LINE=""

# ---------------------------------------------------------------------------------------------
# Output and permissions
# ---------------------------------------------------------------------------------------------

# Prints tab-separated lines from stdin as an aligned table; the first line is the header. Empty cells
# show as "-", so columns never shift.
print_table() {
  awk -F'\t' '
    {
      rows = NR
      if (NF > columns) columns = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = ($i == "") ? "-" : $i
        if (length(cell[NR, i]) > width[i]) width[i] = length(cell[NR, i])
      }
    }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        for (i = 1; i <= columns; i++) {
          value = ((r, i) in cell) ? cell[r, i] : "-"
          line = line ((i < columns) ? sprintf("%-" width[i] "s  ", value) : value)
        }
        print line
      }
    }'
}

# Stops with "run with sudo" unless root, for the commands that change the machine.
require_root() {
  [[ ${EUID} -eq 0 ]] || die "run with sudo: sudo ghrunner ${GHRUNNER_COMMAND_LINE}"
}

# Stops if a command that takes no arguments was given some, so typos don't pass silently.
no_arguments() {
  [[ $# -eq 0 ]] || die "unexpected argument '$1' (see: ghrunner help)"
}

# True when this user can read every service's journal entries: root, or the adm or systemd-journal
# group. Otherwise journalctl quietly shows nothing, and the output says why.
can_read_journal() {
  [[ ${EUID} -eq 0 || " $(id -nG) " =~ \ (adm|systemd-journal|wheel)\  ]]
}

# Formats a byte count for people (1.5G), so tables stay narrow.
human_bytes() {
  numfmt --to=iec-i --suffix=B -- "$1"
}

# Formats how long ago an epoch time was ("3d 4h ago"), so dates in tables are easy to judge.
time_ago() {
  local now seconds
  now="$(date +%s)"
  seconds=$((now - $1))
  if ((seconds >= 86400)); then
    printf '%dd %dh ago' $((seconds / 86400)) $((seconds % 86400 / 3600))
  elif ((seconds >= 3600)); then
    printf '%dh %dm ago' $((seconds / 3600)) $((seconds % 3600 / 60))
  else
    printf '%dm ago' $((seconds / 60))
  fi
}

# Formats an epoch time as local date and time plus how long ago it was.
when_was() {
  printf '%s (%s)' "$(date -d "@$1" '+%Y-%m-%d %H:%M')" "$(time_ago "$1")"
}

# ---------------------------------------------------------------------------------------------
# Finding runners
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

# ---------------------------------------------------------------------------------------------
# Reading runner output from the journal
# ---------------------------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------------------------
# Machine facts for stats and doctor
# ---------------------------------------------------------------------------------------------

# Prints one /proc/meminfo value in bytes (file is a parameter so tests can pass a sample).
meminfo_bytes() {
  awk -v key="$1:" '$1 == key { printf "%d", $2 * 1024 }' "${2:-/proc/meminfo}"
}

# Prints "<size> <used> <available>" in bytes for the filesystem holding <path>.
disk_bytes() {
  df -P -B1 "$1" | awk 'NR == 2 { print $2, $3, $4 }'
}

# Prints the whole-number percentage of free space on the filesystem holding <path>.
disk_free_percent() {
  df -P -B1 "$1" | awk 'NR == 2 { printf "%d", $4 * 100 / $2 }'
}

# Prints the epoch time the weekly clean-up last logged that it finished, or nothing.
last_prune_epoch() {
  journalctl -t docker-prune -n 1 -o short-unix -q --no-pager 2>/dev/null |
    awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ { printf "%d\n", $1 }' | tail -n 1 || true
}

# Prints the epoch time this machine last booted.
boot_epoch() {
  date -d "$(uptime -s)" +%s
}

# Prints "<type>\t<size>" for each kind of Docker data (images, containers, volumes, build cache).
docker_usage() {
  docker system df --format '{{.Type}}\t{{.Size}}'
}

# True when this user can talk to Docker (root, or the docker group).
docker_reachable() {
  docker info >/dev/null 2>&1
}

# ---------------------------------------------------------------------------------------------
# add / delete
# ---------------------------------------------------------------------------------------------

# True when a runner's "owner/repo" is the repository the user named: compares the whole name when
# they gave an owner, else just the repository part. GitHub names ignore case.
repository_matches() {
  local wanted runner
  wanted="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  runner="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  if [[ ${wanted} == */* ]]; then [[ ${runner} == "${wanted}" ]]; else [[ ${runner##*/} == "${wanted}" ]]; fi
}

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
    unregister_runner "${directory}"
    rm -rf -- "${directory}"
    note "unregistered and its folder removed"
    deleted=$((deleted + 1))
  done
  ((deleted > 0)) || die "no runners for ${full} on this machine"
}

# ---------------------------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------------------------

# Upgrades system packages the way setup-runner.sh does, and prints apt's one-line summary.
upgrade_packages() {
  local output
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null
  output="$(apt-get -o DPkg::Lock::Timeout=300 full-upgrade -yq)"
  grep -E '^[0-9]+ upgraded' <<<"${output}" || echo "done"
}

# Prints whether a reboot is pending and which packages asked for it.
reboot_state() {
  if [[ -f /var/run/reboot-required ]]; then
    local packages=""
    [[ -f /var/run/reboot-required.pkgs ]] && packages="$(sort -u /var/run/reboot-required.pkgs | paste -sd, -)"
    echo "needed: run 'sudo reboot' (runners restart by themselves)${packages:+; for ${packages}}"
  else
    echo "not needed"
  fi
}

# ghrunner update: system packages, reboot check, and each runner's version against the latest release.
# Runners update themselves, so they are only reported.
update() {
  require_root
  no_arguments "$@"
  local packages latest unit name version
  log "Updating system packages"
  packages="$(upgrade_packages)"
  { printf 'ITEM\tRESULT\n'; printf 'Packages\t%s\n' "${packages}"; printf 'Reboot\t%s\n' "$(reboot_state)"; } |
    print_table

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
# prune
# ---------------------------------------------------------------------------------------------

# ghrunner prune: runs the weekly clean-up script now (the same file cron runs), then shows Docker's
# disk use before and after and the space freed on Docker's filesystem.
prune() {
  require_root
  no_arguments "$@"
  [[ -x ${PRUNE_SCRIPT} ]] || die "${PRUNE_SCRIPT} is missing or not executable: run setup-runner.sh again"
  docker_reachable || die "Docker isn't running"
  local root before after free_before free_after freed
  root="$(docker info --format '{{.DockerRootDir}}')"
  before="$(docker_usage)"
  free_before="$(disk_bytes "${root}" | cut -d' ' -f3)"

  log "Running ${PRUNE_SCRIPT}"
  "${PRUNE_SCRIPT}"

  after="$(docker_usage)"
  free_after="$(disk_bytes "${root}" | cut -d' ' -f3)"
  freed=$((free_after - free_before))
  {
    printf 'WHAT\tBEFORE\tAFTER\n'
    paste <(printf '%s\n' "${before}") <(cut -f2 <<<"${after}")
    printf 'Free disk (%s)\t%s\t%s\n' "${root}" "$(human_bytes "${free_before}")" "$(human_bytes "${free_after}")"
  } | print_table
  if ((freed > 0)); then
    note "Freed $(human_bytes "${freed}")."
  else
    note "Nothing freed (jobs writing to the disk meanwhile can hide what was freed)."
  fi
}

# ---------------------------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------------------------

DOCTOR_ROWS=()
DOCTOR_FAILED=0

# Records one check's result (PASS, WARN or FAIL) for the doctor table; any FAIL makes doctor exit 1.
record() {
  DOCTOR_ROWS+=("$2"$'\t'"$1"$'\t'"$3")
  if [[ $1 == "FAIL" ]]; then DOCTOR_FAILED=1; fi
}

# Grades a free-space percentage: under 10% fails, under 20% warns.
classify_disk() {
  if (($1 < 10)); then echo "FAIL"; elif (($1 < 20)); then echo "WARN"; else echo "PASS"; fi
}

# Disk: jobs pull images and build caches, and a full disk fails every job.
check_disk() {
  local percent
  percent="$(disk_free_percent /)"
  record "$(classify_disk "${percent}")" "Disk free" "${percent}% free on / (warn under 20%, fail under 10%)"
}

# Docker: CI jobs run their services in containers.
check_docker() {
  if systemctl is-active --quiet docker 2>/dev/null; then
    record PASS "Docker" "running"
  else
    record FAIL "Docker" "not running: sudo systemctl start docker"
  fi
}

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

# Clean-up job: without it the disk fills with old images and build cache.
check_cleanup_job() {
  if [[ ! -e ${PRUNE_SCRIPT} ]]; then
    record FAIL "Clean-up job" "${PRUNE_SCRIPT} missing: run setup-runner.sh again"
  elif [[ ! -x ${PRUNE_SCRIPT} ]]; then
    record FAIL "Clean-up job" "${PRUNE_SCRIPT} isn't executable: sudo chmod +x ${PRUNE_SCRIPT}"
  elif ! systemctl is-active --quiet cron 2>/dev/null; then
    record FAIL "Clean-up job" "the cron service isn't running"
  else
    record PASS "Clean-up job" "${PRUNE_SCRIPT}, weekly"
  fi
}

# True when ufw is enforcing. Root asks ufw; other users read its config and service state.
firewall_on() {
  if [[ ${EUID} -eq 0 ]]; then
    [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]
  else
    grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && systemctl is-active --quiet ufw 2>/dev/null
  fi
}

# Firewall: runners only call out, so nothing but SSH should come in.
check_firewall() {
  if firewall_on; then
    record PASS "Firewall" "ufw on"
  else
    record FAIL "Firewall" "ufw off: sudo ufw allow OpenSSH && sudo ufw enable"
  fi
}

# Prints sshd_config with its Include lines replaced by the included files (in sshd's order), and a
# "#end-of-include" line after each, since a Match block ends with its file. Fails if any file can't be
# read. <base> is where relative Include paths start (/etc/ssh; tests pass a sample folder).
sshd_config_stream() {
  local file="$1" base="$2" line pattern included
  local -a patterns
  [[ -r ${file} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    if [[ ${line} =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+(.+)$ ]]; then
      read -r -a patterns <<<"${BASH_REMATCH[1]}"
      for pattern in "${patterns[@]}"; do
        [[ ${pattern} == /* ]] || pattern="${base}/${pattern}"
        while read -r included; do
          [[ -n ${included} ]] || continue
          sshd_config_stream "${included}" "${base}" || return 1
          echo "#end-of-include"
        done < <(compgen -G "${pattern}" | sort)
      done
    else
      printf '%s\n' "${line}"
    fi
  done <"${file}"
}

# From a config stream on stdin, prints the password and keyboard-interactive settings sshd would use:
# sshd keeps the first value it reads, and skips Match blocks (they apply to some connections only).
sshd_first_values() {
  awk '
    /^#end-of-include/ { in_match = 0; next }
    {
      sub(/^[ \t]+/, "")
      if ($0 == "" || $0 ~ /^#/) next
      split($0, field, /[ \t=]+/)
      key = tolower(field[1]); value = tolower(field[2])
      if (key == "match") { in_match = (value != "all"); next }
      if (in_match) next
      if (key == "challengeresponseauthentication") key = "kbdinteractiveauthentication"
      if ((key == "passwordauthentication" || key == "kbdinteractiveauthentication") && !(key in first)) first[key] = value
    }
    END {
      print "passwordauthentication " (("passwordauthentication" in first) ? first["passwordauthentication"] : "yes")
      print "kbdinteractiveauthentication " (("kbdinteractiveauthentication" in first) ? first["kbdinteractiveauthentication"] : "yes")
    }'
}

# Prints sshd's effective password and keyboard-interactive settings: root asks sshd itself (sshd -T),
# anyone else reads the config files. Fails when the files aren't all readable.
sshd_auth_settings() {
  local settings
  if [[ ${EUID} -eq 0 ]] && settings="$(sshd -T 2>/dev/null)"; then
    grep -E '^(passwordauthentication|kbdinteractiveauthentication) ' <<<"${settings}"
    return
  fi
  sshd_config_stream /etc/ssh/sshd_config /etc/ssh | sshd_first_values
}

# SSH: password login on an internet-facing VM invites brute force; keys only.
check_ssh() {
  local settings
  if ! settings="$(sshd_auth_settings)"; then
    if [[ ${EUID} -eq 0 ]]; then
      record WARN "SSH keys only" "can't read the SSH settings (is openssh-server installed?)"
    else
      record WARN "SSH keys only" "can't read every SSH config file: run with sudo"
    fi
    return
  fi
  if grep -qx 'passwordauthentication no' <<<"${settings}" && grep -qx 'kbdinteractiveauthentication no' <<<"${settings}"; then
    record PASS "SSH keys only" "password login off"
  else
    record FAIL "SSH keys only" "password login is on: run setup-runner.sh again (needs an authorized key)"
  fi
}

# Reboot: security updates to the kernel and libraries only take effect after one.
check_reboot() {
  if [[ -f /var/run/reboot-required ]]; then
    record WARN "Reboot pending" "$(reboot_state)"
  else
    record PASS "Reboot pending" "no"
  fi
}

# Swap: machines under 10 GB need it for memory-heavy jobs; bigger ones don't.
check_swap() {
  local memory swap
  memory="$(memory_gb)"
  swap="$(meminfo_bytes SwapTotal)"
  if ((memory >= 10)); then
    record PASS "Swap" "not needed with ${memory} GB of memory"
  elif ((swap > 0)); then
    record PASS "Swap" "$(human_bytes "${swap}") with ${memory} GB of memory"
  else
    record WARN "Swap" "off with only ${memory} GB of memory: run setup-runner.sh again"
  fi
}

# ghrunner doctor: runs every check, prints a PASS/WARN/FAIL table, exits 1 if anything failed.
doctor() {
  no_arguments "$@"
  check_disk
  check_docker
  check_runner_services
  check_cleanup_job
  check_firewall
  check_ssh
  check_reboot
  check_swap
  { printf 'CHECK\tRESULT\tDETAIL\n'; printf '%s\n' "${DOCTOR_ROWS[@]}"; } | print_table
  if ((DOCTOR_FAILED)); then exit 1; fi
}

# ---------------------------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------------------------

# ghrunner help: the command list.
usage() {
  cat <<'EOF'
Usage: ghrunner <command> [arguments]

Commands                  What it does                                                    Needs sudo
  add <repo> [count]      register runners 1..count for a repository (count: auto)        yes
  delete <repo>           stop, unregister and remove a repository's runners              yes
  update                  update system packages, report reboot and runner versions       yes
  status                  each runner: service, idle or busy, current job                 no
  stats [days]            jobs, results and durations (default 7 days), disk, memory      no
  prune                   run the weekly Docker clean-up now, show the space freed        yes
  doctor                  health checks as a PASS/WARN/FAIL table; exits 1 on a FAIL      no
  help                    this text                                                       no

<repo> is "repo" (owner: GITHUB_OWNER, default Sna-ke) or "owner/repo", e.g. example-org/example-app.
add and delete get tokens from GITHUB_TOKEN (fine-grained, Administration: read and write; never
stored) or ask you to paste one:  sudo --preserve-env=GITHUB_TOKEN ghrunner add example-app
EOF
}

# Runs the command named on the command line.
main() {
  GHRUNNER_COMMAND_LINE="$*"
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "${command}" in
    add) add "$@" ;;
    delete) delete "$@" ;;
    update) update "$@" ;;
    status) status "$@" ;;
    stats) stats "$@" ;;
    prune) prune "$@" ;;
    doctor) doctor "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2 && die "unknown command '${command}'" ;;
  esac
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
