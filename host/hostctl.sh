#!/usr/bin/env bash
# hostctl: looks after a host set up by host/setup-host.sh, whatever components it runs (the GitHub
# runner, Portainer). Installed as /usr/local/bin/hostctl, a link to /usr/local/lib/hostctl/host/hostctl.sh.
#
# Usage: hostctl <command> [arguments]   (run "hostctl help" for the list)
#
# doctor, version and help only read and work without root (some details need sudo). audit, update,
# prune, self-update and "doctor --fix" need sudo.

set -Eeuo pipefail

HOST_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/host-lib.sh
. "${HOST_DIR}/host-lib.sh"
trap 'die "line ${LINENO}: \"${BASH_COMMAND}\" failed"' ERR
PROGRAM="hostctl"
load_components "$(dirname "${HOST_DIR}")"

# ---------------------------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------------------------

# Prints the audit findings for a baseline and snapshot file. A baseline from before 2.0.0 is compared
# without the sections that moved (hostctl's files were ghrunner's).
audit_findings() {
  local baseline="$1" snapshot="$2"
  if [[ "$(head -n 1 "${baseline}")" == "${AUDIT_FORMAT_1}" ]]; then
    audit_diff "${baseline}" "${snapshot}" | awk -F'\t' '$1 != "ghrunner" && $1 != "tools"'
  else
    audit_diff "${baseline}" "${snapshot}"
  fi
}

# hostctl audit [--accept | --notify | --before-setup]: compares this machine with the baseline and lists
# every change. Exits 1 if there are any.
#   --accept        you made the changes: they become the new baseline
#   --notify        the daily timer: records the result, shows it at login, and alerts when it's new
#   --before-setup  setup's first step: logins from new addresses don't count
audit() {
  require_root
  local mode="${1:-}" snapshot findings blocking first=""
  case "${mode}" in
    "" | --accept | --notify | --before-setup) ;;
    *) die "usage: hostctl audit [--accept | --notify]" ;;
  esac
  install -d -m 0755 "${STATE_DIR}"
  snapshot="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the file name is local
  trap "rm -f '${snapshot}'" EXIT
  audit_snapshot >"${snapshot}"

  if [[ -f ${AUDIT_BASELINE} ]]; then first="$(head -n 1 "${AUDIT_BASELINE}")"; fi
  if [[ ${first} != "${AUDIT_FORMAT}" && ${first} != "${AUDIT_FORMAT_1}" ]]; then
    case "${mode}" in
      --accept) audit_accept "${snapshot}" && audit_record "" && note "baseline recorded" && return ;;
      --before-setup) note "no baseline yet; setup records one at the end" && return ;;
      *) die "there is no audit baseline yet: run 'sudo hostctl audit --accept' (setup does this)" ;;
    esac
  fi
  findings="$(audit_findings "${AUDIT_BASELINE}" "${snapshot}")"

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
      note "If you made these changes: sudo hostctl audit --accept"
      note "If you didn't: see 'If the VM is compromised' in host/README.md"
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# update and prune
# ---------------------------------------------------------------------------------------------

# hostctl update [--scheduled]: upgrades every package (Docker's too), never reboots, and warns when a
# new kernel waits for a reboot; then each component upgrades its own software (Portainer: the newest
# image of its tag) and reports (the runner: versions against the latest release). --scheduled (the weekly timer) first lets each component pause its work (the runner waits
# until no job is running), and alerts instead of printing.
update() {
  require_root
  local scheduled="no" packages reason
  case "${1:-}" in
    "") ;;
    --scheduled) scheduled="yes" ;;
    *) die "usage: hostctl update [--scheduled]" ;;
  esac
  if [[ ${scheduled} == "yes" ]]; then
    trap 'call_hooks resume || true' EXIT
    if ! call_hooks pause; then
      send_alert "weekly update skipped" "A component couldn't pause its work (runners busy for 3 hours). It tries again next week, or run: sudo hostctl update"
      exit 1
    fi
  fi

  log "Updating system packages"
  packages="$(upgrade_packages)"
  if [[ ${scheduled} == "yes" ]]; then
    call_hooks resume || true
    trap - EXIT
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
  # A failure stops here, so the timer's service shows as failed and doctor reports it.
  call_hooks upgrade
  call_hooks update_report
}

# hostctl prune: runs the weekly clean-up script now (the same file cron runs), then shows Docker's disk
# use before and after and the space freed on Docker's filesystem.
prune() {
  require_root
  no_arguments "$@"
  [[ -x ${PRUNE_SCRIPT} ]] || die "${PRUNE_SCRIPT} is missing or not executable: sudo hostctl doctor --fix"
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
    note "Nothing freed (anything writing to the disk meanwhile can hide what was freed)."
  fi
}

# ---------------------------------------------------------------------------------------------
# version and self-update
# ---------------------------------------------------------------------------------------------

# Prints the blob hashes of every installed folder's scripts at <commit>.
installed_blobs_at() {
  local -a components folders
  mapfile -t components < <(installed_components)
  mapfile -t folders < <(tool_folders "${components[@]}")
  blobs_at "$1" "${folders[@]}"
}

# hostctl version: the installed version, the latest on main, and whether they match. When the files
# match main, that is the installed commit too, even if setup was run by hand.
version() {
  no_arguments "$@"
  local commits latest latest_version="" blobs state commit
  commit="$(installed_commit)"
  commits="$(latest_commits 2>/dev/null || true)"
  latest="$(head -n 1 <<<"${commits}" | cut -f1)"
  if [[ -z ${latest} ]]; then
    state="can't tell: GitHub didn't answer"
  else
    latest_version="$(file_at "${latest}" host/host-lib.sh 2>/dev/null | version_from_text || true)"
    blobs="$(installed_blobs_at "${latest}" 2>/dev/null || true)"
    if files_match "${TOOLS_DIR}" "${blobs}"; then
      state="up to date"
      commit="${latest}"
    else
      state="update available: sudo hostctl self-update"
    fi
  fi
  {
    printf 'ITEM\tVALUE\n'
    printf 'Installed\t%s\n' "$(describe_version "$(installed_version)" "${commit}")"
    printf 'Components\t%s\n' "$(installed_components | paste -sd' ' -)"
    if [[ -n ${latest} ]]; then
      printf 'Latest on main\t%s, %s\n' "$(describe_version "${latest_version:-?}" "${latest}")" \
        "$(head -n 1 <<<"${commits}" | cut -f2)"
    fi
    printf 'Status\t%s\n' "${state}"
  } | print_table
}

# hostctl self-update [--yes]: when main has a newer version, lists what changed, asks, downloads every
# installed folder's scripts from that exact commit (each checked against GitHub's hash), and runs its
# setup-host.sh for the installed components: the same as the one-line install.
self_update() {
  require_root
  local assume_yes="no" commits latest latest_version blobs folder
  local -a components
  case "${1:-}" in
    "") ;;
    --yes | -y) assume_yes="yes" ;;
    *) die "usage: hostctl self-update [--yes]" ;;
  esac
  mapfile -t components < <(installed_components)
  ((${#components[@]} > 0)) || die "no components are installed: use the one-line install"
  log "Checking ${TOOLS_REPO} for a newer version"
  commits="$(latest_commits)" || die "couldn't reach GitHub"
  latest="$(head -n 1 <<<"${commits}" | cut -f1)"
  [[ ${latest} =~ ^[0-9a-f]{40}$ ]] || die "GitHub's answer had no commit"
  blobs="$(installed_blobs_at "${latest}")" || die "couldn't list the files at ${latest}"
  if files_match "${TOOLS_DIR}" "${blobs}"; then
    echo "${latest}" >"${TOOLS_DIR}/VERSION"
    note "already up to date: $(describe_version "$(installed_version)" "${latest}")"
    return
  fi
  latest_version="$(file_at "${latest}" host/host-lib.sh | version_from_text || true)"
  note "installed: $(describe_version "$(installed_version)" "$(installed_commit)")"
  note "latest:    $(describe_version "${latest_version:-?}" "${latest}")"
  log "What's new"
  whats_new "${latest}" "${commits}"
  note "Updating runs setup again for: ${components[*]}"
  if [[ ${assume_yes} != "yes" ]]; then
    has_terminal || die "no terminal to confirm on: run 'sudo hostctl self-update --yes'"
    confirm "Update to ${latest_version:-${latest:0:7}}?" || die "not updated"
  fi

  folder="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the folder is local to this function
  trap "rm -rf '${folder}'" EXIT
  log "Downloading ${latest_version:-${latest:0:7}}"
  download_version "${latest}" "${folder}" "${blobs}"
  note "all files match GitHub's hashes"
  TOOLS_COMMIT="${latest}" bash "${folder}/host/setup-host.sh" "${components[@]}"
}

# ---------------------------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------------------------

# Runs every check (the host's, then each component's) and prints the PASS/WARN/FAIL table.
run_checks() {
  DOCTOR_ROWS=()
  DOCTOR_FAILED=0
  DOCTOR_FIXABLE=0
  check_disk
  check_docker
  check_docker_local
  check_scheduled_jobs
  check_security_updates
  check_firewall
  check_ssh
  check_kernel_settings
  check_alerts
  check_audit
  check_kernel
  check_reboot
  check_swap
  call_hooks checks
  check_tools_version
  { printf 'CHECK\tRESULT\tDETAIL\n'; printf '%s\n' "${DOCTOR_ROWS[@]}"; } | print_table
}

# hostctl doctor [--fix]: runs every check and prints a PASS/WARN/FAIL table; exits 1 if anything failed.
# --fix: when a problem is one setup fixes, runs the installed setup-host.sh (the same version, nothing
# downloaded; it asks the usual questions), then checks again. Other problems say what to do.
doctor() {
  local fix="no"
  local -a components
  case "${1:-}" in
    "") ;;
    --fix) fix="yes" ;;
    *) die "usage: hostctl doctor [--fix]" ;;
  esac
  if [[ ${fix} == "yes" ]]; then require_root; fi
  run_checks
  if [[ ${fix} == "yes" && ${DOCTOR_FIXABLE} -eq 1 ]]; then
    [[ -f ${TOOLS_DIR}/host/setup-host.sh ]] || die "${TOOLS_DIR}/host/setup-host.sh is missing: run the one-line install"
    mapfile -t components < <(installed_components)
    log "Fixing: running setup-host.sh ${TOOLS_VERSION} again (${components[*]})"
    if ! bash "${TOOLS_DIR}/host/setup-host.sh" "${components[@]}"; then note "setup stopped; the reason is above"; fi
    log "Checking again"
    run_checks
  elif [[ ${fix} == "yes" ]]; then
    note "nothing here that setup fixes; any other problem above says what to do"
  elif ((DOCTOR_FIXABLE)); then
    note "Fix what setup can with: sudo hostctl doctor --fix"
  fi
  if ((DOCTOR_FAILED)); then exit 1; fi
}

# ---------------------------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------------------------

# hostctl help: the command list.
usage() {
  printf 'hostctl %s\n\n' "${TOOLS_VERSION}"
  # "|| true": a reader that stops early (hostctl help | head) is not an error.
  cat <<'EOF' || true
Usage: hostctl <command> [arguments]

Commands                What it does                                                       Needs sudo
  doctor [--fix]        health checks; --fix runs setup again for what it fixes (sudo)     no
  audit [--accept]      list changes since the baseline (users, keys, sudo, ports...)      yes
  update [--scheduled]  upgrade all packages, warn about a waiting kernel                  yes
  prune                 run the weekly Docker clean-up now, show the space freed           yes
  version               installed version, and whether main has a newer one                no
  self-update [--yes]   update from main, after showing what changed                       yes
  help                  this text                                                          no

Components add their own command: ghrunner (GitHub runners), portainerctl (Portainer).
EOF
}

# Runs the command named on the command line.
main() {
  COMMAND_LINE="$*"
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "${command}" in
    doctor) doctor "$@" ;;
    audit) audit "$@" ;;
    update) update "$@" ;;
    prune) prune "$@" ;;
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
