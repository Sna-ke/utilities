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
# version and self-update
#
# A version is a commit of GHRUNNER_REPO. Files are compared by their git blob hash, which GitHub
# reports for every file, so a copy downloaded by hand is recognised too.
# ---------------------------------------------------------------------------------------------

# The commit recorded at install, or "unknown" (setup-runner.sh run from a download by hand).
installed_commit() {
  local commit=""
  if [[ -r ${GHRUNNER_LIB_DIR}/VERSION ]]; then commit="$(<"${GHRUNNER_LIB_DIR}/VERSION")"; fi
  echo "${commit:-unknown}"
}

# The installed version number, from the installed runner-lib.sh. Copies older than 1.3.0 had none.
installed_version() {
  local version=""
  if [[ -r ${GHRUNNER_LIB_DIR}/runner-lib.sh ]]; then version="$(version_from_text <"${GHRUNNER_LIB_DIR}/runner-lib.sh")"; fi
  echo "${version:-1.2.0 or older}"
}

# From commits ("<sha>\t<date>\t<title>", newest first) on stdin, prints the ones newer than <installed>
# as "<short sha>  <date>  <title>". With an unknown or unlisted installed commit, prints the newest 5.
# Used when a version's changelog can't be read.
commits_since() {
  awk -F'\t' -v installed="$1" '
    $1 == installed { found = 1; exit }
    { line[++count] = substr($1, 1, 7) "  " $2 "  " $3 }
    END { for (i = 1; i <= count && (found || i <= 5); i++) print line[i] }'
}

# From CHANGELOG.md on stdin, prints "<version>  <date>  <changes>" for each version newer than
# <installed> (every version when <installed> isn't a number), newest first.
changelog_since() {
  local version date changes
  while IFS='|' read -r _ version date changes _; do
    version="${version//[[:space:]\`]/}"
    [[ ${version} =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    if [[ $1 =~ ^[0-9]+(\.[0-9]+)*$ ]] && ! version_newer "${version}" "$1"; then continue; fi
    date="${date//[[:space:]]/}"
    changes="${changes#"${changes%%[![:space:]]*}"}"
    printf '%s  %s  %s\n' "${version}" "${date}" "${changes%"${changes##*[![:space:]]}"}"
  done
}

# Prints "<version> (commit <short sha>)", or just the version when the commit is unknown.
describe_version() {
  if [[ $2 == "unknown" || -z $2 ]]; then echo "$1"; else echo "$1 (commit ${2:0:7})"; fi
}

# ghrunner version: the installed version, the latest on main, and whether they match. When the files
# match main, that is the installed commit too, even if setup-runner.sh was run by hand.
version() {
  no_arguments "$@"
  local commits latest latest_version="" blobs state commit
  commit="$(installed_commit)"
  commits="$(latest_commits 2>/dev/null || true)"
  latest="$(head -n 1 <<<"${commits}" | cut -f1)"
  if [[ -z ${latest} ]]; then
    state="can't tell: GitHub didn't answer"
  else
    latest_version="$(file_at "${latest}" runner-lib.sh 2>/dev/null | version_from_text || true)"
    blobs="$(blobs_at "${latest}" 2>/dev/null || true)"
    if files_match "${GHRUNNER_LIB_DIR}" "${blobs}"; then
      state="up to date"
      commit="${latest}"
    else
      state="update available: sudo ghrunner self-update"
    fi
  fi
  {
    printf 'ITEM\tVALUE\n'
    printf 'Installed\t%s\n' "$(describe_version "$(installed_version)" "${commit}")"
    if [[ -n ${latest} ]]; then
      printf 'Latest on main\t%s, %s\n' "$(describe_version "${latest_version:-1.2.0 or older}" "${latest}")" \
        "$(head -n 1 <<<"${commits}" | cut -f2)"
    fi
    printf 'Status\t%s\n' "${state}"
  } | print_table
}

# Prints what changed between the installed version and <latest commit>: the changelog entries when
# that version has a changelog, else the commit titles.
whats_new() {
  local latest="$1" commits="$2" changes line
  changes="$(file_at "${latest}" CHANGELOG.md 2>/dev/null | changelog_since "$(installed_version)" || true)"
  if [[ -z ${changes} ]]; then changes="$(commits_since "$(installed_commit)" <<<"${commits}")"; fi
  while IFS= read -r line; do note "${line}"; done <<<"${changes}"
}

# ghrunner self-update [--yes]: when main has a newer version, lists what changed, asks, downloads all
# three files from that exact commit, and runs its setup-runner.sh: the same as updating by hand.
self_update() {
  require_root
  local assume_yes="no" commits latest latest_version blobs folder
  case "${1:-}" in
    "") ;;
    --yes | -y) assume_yes="yes" ;;
    *) die "usage: ghrunner self-update [--yes]" ;;
  esac
  log "Checking ${GHRUNNER_REPO} for a newer version"
  commits="$(latest_commits)" || die "couldn't reach GitHub"
  latest="$(head -n 1 <<<"${commits}" | cut -f1)"
  [[ ${latest} =~ ^[0-9a-f]{40}$ ]] || die "GitHub's answer had no commit"
  blobs="$(blobs_at "${latest}")" || die "couldn't list the files at ${latest}"
  if files_match "${GHRUNNER_LIB_DIR}" "${blobs}"; then
    echo "${latest}" >"${GHRUNNER_LIB_DIR}/VERSION"
    note "already up to date: $(describe_version "$(installed_version)" "${latest}")"
    return
  fi
  latest_version="$(file_at "${latest}" runner-lib.sh | version_from_text || true)"
  note "installed: $(describe_version "$(installed_version)" "$(installed_commit)")"
  note "latest:    $(describe_version "${latest_version:-1.2.0 or older}" "${latest}")"
  log "What's new"
  whats_new "${latest}" "${commits}"
  note "Updating runs setup-runner.sh again: packages, ghrunner, runner settings and sizing."
  if [[ ${assume_yes} != "yes" ]]; then
    { true </dev/tty; } 2>/dev/null || die "no terminal to confirm on: run 'sudo ghrunner self-update --yes'"
    confirm "Update to ${latest_version:-${latest:0:7}}?" || die "not updated"
  fi

  folder="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the folder is local to this function
  trap "rm -rf '${folder}'" EXIT
  log "Downloading ${latest_version:-${latest:0:7}}"
  download_version "${latest}" "${folder}" "${blobs}"
  note "all files match GitHub's hashes"
  GHRUNNER_COMMIT="${latest}" bash "${folder}/setup-runner.sh"
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

# From kernel image names (vmlinuz-<version>) on stdin, prints the newest version.
newest_kernel() {
  sed -n 's/^vmlinuz-//p' | sort -V | tail -n 1
}

# Prints the newest installed kernel when it is newer than the running one (it waits for a reboot),
# else nothing.
kernel_waiting() {
  local running newest
  running="$(uname -r)"
  newest="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | newest_kernel || true)"
  if [[ -n ${newest} ]] && version_newer "${newest}" "${running}"; then echo "${newest}"; fi
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

# Prints what needs a reboot, for people: a waiting kernel first, as that is the one that matters.
reboot_reason() {
  local kernel
  kernel="$(kernel_waiting)"
  if [[ -n ${kernel} ]]; then
    echo "kernel ${kernel} is installed but $(uname -r) is running: reboot when convenient (sudo reboot; runners restart by themselves)"
  elif [[ -f /var/run/reboot-required ]]; then
    reboot_state
  fi
}

# ghrunner update [--scheduled]: upgrades every package (Docker's too), never reboots, and warns when a
# new kernel waits for a reboot; then compares each runner's version with the latest release (runners
# update themselves, so this only reports). --scheduled (the weekly timer) first waits until no job is
# running, pauses the runners during the upgrade, and alerts instead of printing.
update() {
  require_root
  local scheduled="no" packages reason latest unit name version
  case "${1:-}" in
    "") ;;
    --scheduled) scheduled="yes" ;;
    *) die "usage: ghrunner update [--scheduled]" ;;
  esac
  if [[ ${scheduled} == "yes" ]]; then
    log "Waiting until no job is running (up to 3 hours)"
    if ! wait_until_idle 180; then
      send_alert "weekly update skipped" "Runners were busy for 3 hours. It tries again next week, or run: sudo ghrunner update"
      exit 1
    fi
    trap 'resume_runners' EXIT
    pause_runners
    note "paused ${#PAUSED_UNITS[@]} runner(s) for the upgrade"
  fi

  log "Updating system packages"
  packages="$(upgrade_packages)"
  if [[ ${scheduled} == "yes" ]]; then
    resume_runners
    trap - EXIT
    note "runners started again"
  fi
  reason="$(reboot_reason)"
  { printf 'ITEM\tRESULT\n'; printf 'Packages\t%s\n' "${packages}"; printf 'Reboot\t%s\n' "${reason:-not needed}"; } |
    print_table
  if [[ -n ${reason} ]]; then
    printf 'Reboot needed: %s\n' "${reason}" | set_attention reboot
    if [[ ${scheduled} == "yes" && -n "$(kernel_waiting)" ]]; then send_alert "kernel update waiting" "${reason}"; fi
  else
    clear_attention reboot
  fi

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
# audit: has anything changed that nobody accepted?
#
# setup-runner.sh records a baseline of everything that decides who can get in and what runs as root.
# The daily timer compares the machine with it. A change nobody made is the sign this VM has been
# tampered with; README.md says what to do then.
# ---------------------------------------------------------------------------------------------

AUDIT_BASELINE="${GHRUNNER_STATE_DIR}/audit-baseline"
AUDIT_STATUS="${GHRUNNER_STATE_DIR}/audit-status"
AUDIT_FORMAT="# ghrunner audit baseline, format 1"

# From /etc/passwd on stdin: accounts that are root (UID 0), people (UID 1000 and up), or can log in.
audit_users() {
  awk -F: '$3 == 0 || ($3 >= 1000 && $3 < 65534) || $7 !~ /(nologin|false|sync|halt|shutdown)$/ {
    printf "users\t%s\tuid=%s shell=%s\n", $1, $3, $7 }'
}

# Every SSH key that can log in to any account, by fingerprint.
audit_ssh_keys() {
  local user home file
  while IFS=: read -r user _ _ _ _ home _; do
    for file in "${home}/.ssh/authorized_keys" "${home}/.ssh/authorized_keys2"; do
      [[ -s ${file} ]] || continue
      ssh-keygen -lf "${file}" 2>/dev/null | awk -v user="${user}" '{ printf "ssh-keys\t%s %s\t%s\n", user, $2, $NF }' ||
        printf 'ssh-keys\t%s %s\tunreadable\n' "${user}" "${file}"
    done
  done </etc/passwd
}

# Files given, by content hash, under <section> (sudo rules, cron jobs). Missing files are skipped.
audit_files() {
  local section="$1" file
  shift
  for file in "$@"; do
    [[ -f ${file} ]] || continue
    printf '%s\t%s\t%s\n' "${section}" "${file}" "$(sha256sum "${file}" | cut -c1-16)"
  done
}

# The SSH settings that decide who gets in, from sshd itself.
audit_ssh_settings() {
  install -d -m 0755 /run/sshd
  sshd -T 2>/dev/null | awk '$1 ~ /^(port|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|authorizedkeysfile|allowusers|denyusers|allowgroups|permitemptypasswords)$/ {
    printf "ssh-settings\t%s\t-\n", $0 }'
}

# The firewall: whether it is on, and every rule.
audit_firewall() {
  ufw status 2>/dev/null | awk 'NR == 1 { printf "firewall\t%s\t-\n", $0; next }
    /^To / || /^--/ || NF == 0 { next } { gsub(/ +/, " "); printf "firewall\t%s\t-\n", $0 }'
}

# From "ss -Htlnu" on stdin, prints "<protocol> <port>" for every socket listening on an address other
# than loopback: what the internet could reach if the firewall let it.
public_listeners() {
  awk '{
    local_address = $5; port = local_address; sub(/.*:/, "", port)
    address = substr(local_address, 1, length(local_address) - length(port) - 1)
    gsub(/[][]/, "", address); sub(/%.*/, "", address)
    if (address ~ /^127\./ || address == "::1") next
    print $1 " " port
  }' | sort -u
}

# Listening sockets reachable from outside.
audit_listening() {
  ss -Htlnu 2>/dev/null | public_listeners | awk '{ printf "listening\t%s\t-\n", $0 }'
}

# Services and timers that start by themselves. Runner services are left out: ghrunner adds and
# removes those.
audit_services() {
  systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
    awk '$1 !~ /^actions\.runner\./ && $1 ~ /\.(service|timer|socket|path)$/ { printf "services\t%s\t-\n", $1 }'
}

# Programs that run with their owner's rights (setuid or setgid), outside the runners' folders and Docker.
audit_setuid() {
  find / -xdev \( -path /proc -o -path /sys -o -path "${RUNNER_HOME}" -o -path /var/lib/docker -o -path /snap \) -prune \
    -o -type f -perm /6000 -print 2>/dev/null | awk '{ printf "setuid\t%s\t-\n", $0 }'
}

# ghrunner's own files, by hash: only setup-runner.sh should change them.
audit_ghrunner() {
  local file
  for file in /usr/local/bin/ghrunner "${GHRUNNER_LIB_DIR}"/*.sh; do
    if [[ -f ${file} ]]; then printf 'ghrunner\t%s\t%s\n' "${file}" "$(git_blob_sha "${file}" | cut -c1-16)"; fi
  done
}

# From sshd's journal lines on stdin, prints "<user> from <address>" for each successful login.
parse_logins() {
  sed -nE 's/.*Accepted [^ ]+ for ([^ ]+) from ([^ ]+) port .*/\1 from \2/p' | sort -u
}

# Who logged in over SSH from where, in the last 8 days.
audit_logins() {
  journalctl -t sshd -t sshd-session --since "-8d" -o cat --no-pager 2>/dev/null | parse_logins |
    awk '{ printf "logins\t%s\t-\n", $0 }'
}

# Everything the audit compares, one "<section>\t<item>\t<value>" line each, sorted. A piece that
# fails leaves its section out rather than stopping the audit.
audit_snapshot() {
  {
    audit_users </etc/passwd || true
    audit_ssh_keys || true
    audit_files sudo /etc/sudoers /etc/sudoers.d/* || true
    audit_ssh_settings || true
    audit_firewall || true
    audit_listening || true
    audit_files cron /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* \
      /etc/cron.monthly/* /var/spool/cron/crontabs/* || true
    audit_services || true
    audit_setuid || true
    audit_ghrunner || true
    audit_logins || true
  } | LC_ALL=C sort -u
}

# Compares a baseline file with a snapshot file, printing "<section>\t<added|removed|changed>\t<item>"
# for each difference. Logins only count when new: old ones age out of the journal.
audit_diff() {
  awk -F'\t' '
    FNR == NR { if ($0 !~ /^#/) old[$1 FS $2] = $3; next }
    /^#/ { next }
    {
      key = $1 FS $2; seen[key] = 1
      if (!(key in old)) print $1 "\tadded\t" $2
      else if (old[key] != $3) print $1 "\tchanged\t" $2
    }
    END {
      for (key in old) if (!(key in seen)) {
        split(key, part, FS)
        if (part[1] != "logins") print part[1] "\tremoved\t" part[2]
      }
    }' "$1" "$2" | LC_ALL=C sort
}

# Makes a snapshot file the new baseline, keeping logins already known.
audit_accept() {
  local snapshot="$1"
  install -d -m 0755 "${GHRUNNER_STATE_DIR}"
  {
    echo "${AUDIT_FORMAT}"
    { cat "${snapshot}"; if [[ -f ${AUDIT_BASELINE} ]]; then awk -F'\t' '$1 == "logins"' "${AUDIT_BASELINE}"; fi; } |
      LC_ALL=C sort -u
  } >"${AUDIT_BASELINE}.new"
  chmod 0600 "${AUDIT_BASELINE}.new"
  mv "${AUDIT_BASELINE}.new" "${AUDIT_BASELINE}"
}

# Records an audit's result for doctor ("<epoch>\t<number of changes>") and the login message. With
# <alert> "yes" (the daily run), also alerts when the set of changes is new, not every day for the same ones.
audit_record() {
  local findings="$1" alert="${2:-no}" count=0 digest previous=""
  [[ -z ${findings} ]] || count="$(wc -l <<<"${findings}")"
  printf '%s\t%s\n' "$(date +%s)" "${count}" >"${AUDIT_STATUS}"
  if ((count == 0)); then
    clear_attention audit
    rm -f "${GHRUNNER_STATE_DIR}/audit-alerted"
    return
  fi
  {
    printf 'Audit %s: %s change(s) nobody accepted, e.g.\n' "$(date '+%Y-%m-%d %H:%M')" "${count}"
    head -n 5 <<<"${findings}" | sed 's/\t/ /g; s/^/  /'
    printf 'If you made them: sudo ghrunner audit --accept. If not: see "If the VM is compromised" in the README.\n'
  } | set_attention audit
  [[ ${alert} == "yes" ]] || return 0
  digest="$(sha256sum <<<"${findings}" | cut -c1-16)"
  if [[ -f ${GHRUNNER_STATE_DIR}/audit-alerted ]]; then previous="$(<"${GHRUNNER_STATE_DIR}/audit-alerted")"; fi
  if [[ ${digest} != "${previous}" ]]; then
    send_alert "audit found ${count} unexpected change(s)" "$(head -n 10 <<<"${findings}" | sed 's/\t/ /g')"
    echo "${digest}" >"${GHRUNNER_STATE_DIR}/audit-alerted"
  fi
}

# Prints audit findings as a table.
audit_table() {
  { printf 'SECTION\tCHANGE\tITEM\n'; printf '%s\n' "$1"; } | print_table
}

# ghrunner audit [--accept | --notify | --before-setup]: compares this machine with the baseline and
# lists every change. Exits 1 if there are any.
#   --accept        you made the changes: they become the new baseline
#   --notify        the daily timer: records the result, shows it at login, and alerts when it's new
#   --before-setup  setup-runner.sh's first step: logins from new addresses don't count
audit() {
  require_root
  local mode="${1:-}" snapshot findings blocking
  case "${mode}" in
    "" | --accept | --notify | --before-setup) ;;
    *) die "usage: ghrunner audit [--accept | --notify]" ;;
  esac
  install -d -m 0755 "${GHRUNNER_STATE_DIR}"
  snapshot="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the file name is local
  trap "rm -f '${snapshot}'" EXIT
  audit_snapshot >"${snapshot}"

  if [[ ! -f ${AUDIT_BASELINE} || "$(head -n 1 "${AUDIT_BASELINE}")" != "${AUDIT_FORMAT}" ]]; then
    case "${mode}" in
      --accept) audit_accept "${snapshot}" && audit_record "" && note "baseline recorded" && return ;;
      --before-setup) note "no baseline yet; setup records one at the end" && return ;;
      *) die "there is no audit baseline yet: run 'sudo ghrunner audit --accept' (setup-runner.sh does this)" ;;
    esac
  fi
  findings="$(audit_diff "${AUDIT_BASELINE}" "${snapshot}")"

  case "${mode}" in
    --accept)
      if [[ -n ${findings} ]]; then
        log "Accepting these changes"
        audit_table "${findings}"
      fi
      audit_accept "${snapshot}"
      audit_record ""
      note "baseline updated"
      ;;
    --before-setup)
      if [[ -n ${findings} ]]; then audit_table "${findings}"; fi
      blocking="$(awk -F'\t' '$1 != "logins"' <<<"${findings}")"
      [[ -z ${blocking} ]]
      ;;
    --notify)
      audit_record "${findings}" yes
      [[ -z ${findings} ]]
      ;;
    *)
      audit_record "${findings}"
      if [[ -z ${findings} ]]; then
        note "nothing changed since the baseline ($(date -r "${AUDIT_BASELINE}" '+%Y-%m-%d %H:%M'))"
        return
      fi
      audit_table "${findings}"
      note "If you made these changes: sudo ghrunner audit --accept"
      note "If you didn't: see 'If the VM is compromised' in github-runner/README.md"
      exit 1
      ;;
  esac
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

# Scheduled jobs: the weekly Docker clean-up (cron), the weekly update and the daily audit (timers).
check_scheduled_jobs() {
  local problems="" timer
  if [[ ! -x ${PRUNE_SCRIPT} ]]; then problems="${PRUNE_SCRIPT} missing or not executable"; fi
  if ! systemctl is-active --quiet cron 2>/dev/null; then problems="${problems:+${problems}; }cron isn't running"; fi
  for timer in ghrunner-update ghrunner-audit; do
    if ! systemctl is-active --quiet "${timer}.timer" 2>/dev/null; then
      problems="${problems:+${problems}; }${timer}.timer isn't on"
    elif systemctl is-failed --quiet "${timer}.service" 2>/dev/null; then
      problems="${problems:+${problems}; }${timer} failed last time (journalctl -u ${timer})"
    fi
  done
  if [[ -n ${problems} ]]; then
    record FAIL "Scheduled jobs" "${problems}: run setup-runner.sh again"
  else
    record PASS "Scheduled jobs" "clean-up, weekly update and daily audit on"
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
    grep -E '^(passwordauthentication|kbdinteractiveauthentication|port) ' <<<"${settings}"
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
    record PASS "SSH keys only" "password login off$(awk '$1 == "port" { ports = ports " " $2 } END { if (ports) print "; port" ports }' <<<"${settings}")"
  else
    record FAIL "SSH keys only" "password login is on: run setup-runner.sh again (needs an authorized key)"
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
    record WARN "Sizing" "machine fits ${RUNNER_COUNT} per repository; ${problems}: sudo ghrunner resize"
  else
    record PASS "Sizing" "${RUNNER_COUNT} runner(s) per repository fits $(memory_gb) GB, $(cpu_count) cores"
  fi
}

# ghrunner itself: a newer version on main may fix problems this machine has.
check_ghrunner_version() {
  local latest blobs
  latest="$(latest_commits 2>/dev/null | head -n 1 | cut -f1 || true)"
  if [[ -z ${latest} ]]; then
    record WARN "ghrunner version" "couldn't reach GitHub to check"
    return
  fi
  blobs="$(blobs_at "${latest}" 2>/dev/null || true)"
  if files_match "${GHRUNNER_LIB_DIR}" "${blobs}"; then
    record PASS "ghrunner version" "$(installed_version), up to date"
  else
    record WARN "ghrunner version" "$(installed_version) installed, newer on main: sudo ghrunner self-update"
  fi
}

# Tool locations: without them, setup-dotnet, setup-python and setup-ruby fail with "Permission denied".
check_tool_settings() {
  local owner missing
  owner="$(stat -c %U "${TOOL_CACHE_DIR}" 2>/dev/null || true)"
  if [[ ${owner} != "${RUNNER_USER}" ]]; then
    record WARN "Tool locations" "${TOOL_CACHE_DIR} ${owner:+is owned by ${owner}}${owner:-missing}: run setup-runner.sh again"
  elif [[ ${EUID} -ne 0 ]]; then
    record PASS "Tool locations" "${TOOL_CACHE_DIR} ready (run with sudo to check each runner's .env)"
  elif missing="$(runners_missing_settings)" && [[ -n ${missing} ]]; then
    record WARN "Tool locations" ".env settings missing for ${missing}: run setup-runner.sh again"
  else
    record PASS "Tool locations" "${TOOL_CACHE_DIR} ready; every runner's .env set"
  fi
}

# Kernel: a new kernel's fixes only apply after a reboot, which nothing here does by itself.
check_kernel() {
  local waiting
  waiting="$(kernel_waiting)"
  if [[ -n ${waiting} ]]; then
    record WARN "Kernel" "${waiting} installed, $(uname -r) running: sudo reboot when convenient"
  else
    record PASS "Kernel" "running the newest installed ($(uname -r))"
  fi
}

# Audit: the daily comparison with the baseline is how a tampered VM gets noticed.
check_audit() {
  local when count
  if [[ ! -r ${AUDIT_STATUS} ]]; then
    record WARN "Audit" "hasn't run yet: sudo ghrunner audit"
    return
  fi
  IFS=$'\t' read -r when count <"${AUDIT_STATUS}"
  if ((count > 0)); then
    record FAIL "Audit" "${count} change(s) nobody accepted ($(when_was "${when}")): sudo ghrunner audit"
  elif (($(date +%s) - when > 2 * 86400)); then
    record WARN "Audit" "last ran $(when_was "${when}"): is ghrunner-audit.timer on?"
  else
    record PASS "Audit" "no unexpected changes ($(when_was "${when}"))"
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
  check_sizing
  check_public_repositories
  check_tool_settings
  check_scheduled_jobs
  check_firewall
  check_ssh
  check_audit
  check_kernel
  check_reboot
  check_swap
  check_ghrunner_version
  { printf 'CHECK\tRESULT\tDETAIL\n'; printf '%s\n' "${DOCTOR_ROWS[@]}"; } | print_table
  if ((DOCTOR_FAILED)); then exit 1; fi
}

# ---------------------------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------------------------

# ghrunner help: the command list.
usage() {
  printf 'ghrunner %s\n\n' "${GHRUNNER_VERSION}"
  cat <<'EOF'
Usage: ghrunner <command> [arguments]

Commands                What it does                                                        Needs sudo
  add <repo> [count]    register runners 1..count for a repository (count: auto)            yes
  delete <repo>         stop, unregister and remove a repository's runners                  yes
  resize [repo]         after a VM resize: add, relabel or remove runners to fit            yes
  update [--scheduled]  upgrade all packages, warn about a waiting kernel, runner versions  yes
  status                each runner: service, idle or busy, current job                     no
  stats [days]          jobs, results and durations (default 7 days), disk, memory          no
  prune                 run the weekly Docker clean-up now, show the space freed            yes
  doctor                health checks as a PASS/WARN/FAIL table; exits 1 on a FAIL          no
  audit [--accept]      list changes since the baseline (users, keys, sudo, ports...)       yes
  version               installed version, and whether main has a newer one                 no
  self-update [--yes]   update ghrunner and setup from main, after showing what changed     yes
  help                  this text                                                           no

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
    resize) resize "$@" ;;
    update) update "$@" ;;
    status) status "$@" ;;
    stats) stats "$@" ;;
    prune) prune "$@" ;;
    doctor) doctor "$@" ;;
    audit) audit "$@" ;;
    version | --version) version "$@" ;;
    self-update) self_update "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2 && die "unknown command '${command}'" ;;
  esac
}

# Sourced by the tests for its functions; run as a command otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
