#!/usr/bin/env bash
# Tests ghrunner's parsing against sample input: unit names, cgroups, systemctl lists, .runner files,
# runner output, journal JSON, job statistics, sshd settings and table layout. Needs no VM, root,
# systemd or Docker; only bash, jq, GNU sed and awk.
#
#   bash github-runner/tests/ghrunner-test.sh
#
# What only a real runner host can test (systemd, journald, Docker, apt, GitHub registration) is listed
# in github-runner/README.md under "Testing".

set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../ghrunner.sh
. "${TESTS_DIR}/../ghrunner.sh"
trap - ERR # failures are reported by the checks below, not by ghrunner's trap

unset GITHUB_TOKEN # nothing here may reach GitHub
SAMPLES="$(mktemp -d)"
trap 'rm -rf "${SAMPLES}"' EXIT
PASSED=0
FAILED=0

# Compares expected and actual output and records the result; prints both when they differ.
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ ${expected} == "${actual}" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n--- expected\n%s\n--- actual\n%s\n\n' "${name}" "${expected}" "${actual}"
  fi
}

# Records whether a command succeeded ("ok") or failed ("fails"), for checks on validation. Runs it in a
# subshell, because a validation failure calls die, which exits.
outcome() {
  if ("$@") >/dev/null 2>&1; then echo "ok"; else echo "fails"; fi
}

# ---------------------------------------------------------------------------------------------
# Unit names, cgroups and systemctl output
# ---------------------------------------------------------------------------------------------

check "unit name: plain" "vps-groundcore-1	groundcore	1" \
  "$(parse_unit_name actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service)"
check "unit name: systemd-escaped dashes" "vps-groundcore-2	groundcore	2" \
  "$(parse_unit_name 'actions.runner.Sna\x2dke\x2dGroundCore.vps\x2dgroundcore\x2d2.service')"
check "unit name: hostname with a dash" "ci-vps-mealplan-3	mealplan	3" \
  "$(parse_unit_name actions.runner.Sna-ke-MealPlan.ci-vps-mealplan-3.service)"
check "unit name: repository with a dot" "vps-example.com-1	example.com	1" \
  "$(parse_unit_name actions.runner.example-org-example.com.vps-example.com-1.service)"
check "unit name: not our convention" "fails" \
  "$(outcome parse_unit_name actions.runner.example-org-example-app.some-other-name.service)"
check "unit identity: falls back to the bare name" "custom	unknown	-" \
  "$(unit_identity actions.runner.custom.service)"

check "cgroup v2" "actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service" \
  "$(unit_from_cgroup <<<'0::/system.slice/actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service')"
check "cgroup v1" 'actions.runner.Sna\x2dke\x2dGroundCore.vps\x2dgroundcore\x2d1.service' \
  "$(unit_from_cgroup <<<$'12:pids:/system.slice/actions.runner.Sna\\x2dke\\x2dGroundCore.vps\\x2dgroundcore\\x2d1.service\n0::/system.slice/actions.runner.Sna\\x2dke\\x2dGroundCore.vps\\x2dgroundcore\\x2d1.service')"
check "cgroup: not a runner" "" "$(unit_from_cgroup <<<'0::/user.slice/user-1000.slice/session-3.scope' || true)"

check "unit list, with the failed-unit bullet" \
  $'actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service\tactive\nactions.runner.Sna-ke-GroundCore.vps-groundcore-2.service\tfailed\nactions.runner.Sna-ke-MealPlan.vps-mealplan-1.service\tinactive' \
  "$(parse_unit_list <<'EOF'
actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service loaded active   running GitHub Actions Runner (Sna-ke-GroundCore.vps-groundcore-1)
● actions.runner.Sna-ke-GroundCore.vps-groundcore-2.service loaded failed   failed  GitHub Actions Runner (Sna-ke-GroundCore.vps-groundcore-2)
actions.runner.Sna-ke-MealPlan.vps-mealplan-1.service loaded inactive dead    GitHub Actions Runner (Sna-ke-MealPlan.vps-mealplan-1)
EOF
)"

check "unit in list" "ok" "$(outcome unit_in_list b.service $'a.service\nb.service')"
check "unit in list: empty unit never matches" "fails" "$(outcome unit_in_list "" $'a.service\n')"

# ---------------------------------------------------------------------------------------------
# Repository names and .runner files
# ---------------------------------------------------------------------------------------------

check "repo: default owner" "Sna-ke/GroundCore" "$(full_repository_name GroundCore)"
check "repo: owner given" "example-org/example.app" "$(full_repository_name example-org/example.app)"
check "repo: path traversal rejected" "fails" "$(outcome full_repository_name ../etc)"
check "repo: nested path rejected" "fails" "$(outcome full_repository_name a/b/c)"
check "repo: spaces rejected" "fails" "$(outcome full_repository_name 'foo bar')"
check "repo: slug" "groundcore" "$(repository_slug Sna-ke/GroundCore)"
check "repo match: name only" "ok" "$(outcome repository_matches groundcore Sna-ke/GroundCore)"
check "repo match: owner and name" "ok" "$(outcome repository_matches sna-ke/GROUNDCORE Sna-ke/GroundCore)"
check "repo match: other owner" "fails" "$(outcome repository_matches example-org/GroundCore Sna-ke/GroundCore)"
check "repo match: prefix is not a match" "fails" "$(outcome repository_matches ground Sna-ke/GroundCore)"

# config.sh writes .runner with a UTF-8 byte-order mark.
mkdir -p "${SAMPLES}/groundcore-1" "${SAMPLES}/ghes-1" "${SAMPLES}/broken-1"
printf '\xEF\xBB\xBF{\n  "agentId": 12,\n  "agentName": "vps-groundcore-1",\n  "poolId": 1,\n  "poolName": "Default",\n  "serverUrl": "https://pipelines.actions.example.com/abc/",\n  "gitHubUrl": "https://github.com/Sna-ke/GroundCore",\n  "workFolder": "_work",\n  "useV2Flow": true\n}' \
  >"${SAMPLES}/groundcore-1/.runner"
printf '{"gitHubUrl": "https://ghe.example.com/example-org/example-app/"}' >"${SAMPLES}/ghes-1/.runner"
printf '{"agentName": "x"}' >"${SAMPLES}/broken-1/.runner"
check ".runner with byte-order mark" "Sna-ke/GroundCore" "$(runner_repository "${SAMPLES}/groundcore-1")"
check ".runner agent name" "vps-groundcore-1" "$(runner_config_value "${SAMPLES}/groundcore-1/.runner" agentName)"
check ".runner on another host, trailing slash" "example-org/example-app" "$(runner_repository "${SAMPLES}/ghes-1")"
check ".runner without gitHubUrl" "fails" "$(outcome runner_repository "${SAMPLES}/broken-1")"

# ---------------------------------------------------------------------------------------------
# Runner output and the journal
# ---------------------------------------------------------------------------------------------

RUNNER_OUTPUT="√ Connected to GitHub

Current runner version: '2.328.0'
2026-11-17 18:00:01Z: Listening for Jobs
2026-11-17 18:05:12Z: Running job: build
2026-11-17 18:09:40Z: Job build completed with result: Succeeded
Runner update in progress, do not shutdown runner.
Current runner version: '2.329.0'
2026-11-17 18:12:00Z: Listening for Jobs
2026-11-17 18:12:02Z: Running job: test (ubuntu-latest, 20)"
check "current job" "test (ubuntu-latest, 20)" "$(last_started_job <<<"${RUNNER_OUTPUT}")"
check "version after a self-update" "2.329.0" "$(last_reported_version <<<"${RUNNER_OUTPUT}")"
check "no job yet" "" "$(last_started_job <<<"Listening for Jobs")"

check "version: same" "up to date" "$(version_status 2.329.0 2.329.0)"
check "version: older" "older: it updates itself" "$(version_status 2.328.0 2.329.0)"
check "version: older, numeric order" "older: it updates itself" "$(version_status 2.99.0 2.329.0)"
check "version: newer" "newer than the latest release" "$(version_status 2.330.0 2.329.0)"
check "version: unknown" "can't tell" "$(version_status unknown 2.329.0)"

# journalctl -o json: timestamps in microseconds as strings; MESSAGE is an array for non-UTF-8 bytes.
G1="actions.runner.Sna-ke-GroundCore.vps-groundcore-1.service"
G2='actions.runner.Sna\x2dke\x2dGroundCore.vps\x2dgroundcore\x2d2.service'
M1="actions.runner.Sna-ke-MealPlan.vps-mealplan-1.service" # a runner that has since been deleted
JOURNAL_JSON="$(jq -cn --arg g1 "${G1}" --arg g2 "${G2}" --arg m1 "${M1}" '
  def e(t; u; m): {"__REALTIME_TIMESTAMP": ((t * 1000000) | tostring), "_SYSTEMD_UNIT": u, "MESSAGE": m};
  e(1000; $g1; "2026-11-17 18:00:01Z: Listening for Jobs"),
  e(1000; $g1; "2026-11-17 18:00:01Z: Running job: build"),
  e(1300; $g1; "2026-11-17 18:05:01Z: Job build completed with result: Succeeded"),
  e(1400; $g1; "2026-11-17 18:06:41Z: Running job: test (ubuntu-latest, 20)"),
  e(1490; $g1; "2026-11-17 18:08:11Z: Job test (ubuntu-latest, 20) completed with result: Failed"),
  e(1500; $g1; "2026-11-17 18:08:21Z: Running job: lint"),
  e(900;  $g2; "2026-11-17 17:58:21Z: Job deploy completed with result: Succeeded"),
  e(2000; $g2; "2026-11-17 18:16:41Z: Running job: e2e"),
  e(2030; $g2; "2026-11-17 18:17:11Z: Job e2e completed with result: Canceled"),
  e(3000; $m1; "2026-11-17 18:33:21Z: Running job: build"),
  e(3045; $m1; "2026-11-17 18:34:06Z: Job build completed with result: SucceededWithIssues"),
  {"__REALTIME_TIMESTAMP": "3100000000", "_SYSTEMD_UNIT": $m1, "MESSAGE": [255, 254, 82, 117, 110]}')"
EVENTS="$(journal_json_to_events <<<"${JOURNAL_JSON}")"
check "journal JSON to events: count" "10" "$(wc -l <<<"${EVENTS}" | tr -d ' ')"
check "journal JSON to events: first" $'1000\t'"${G1}"$'\t2026-11-17 18:00:01Z: Running job: build' \
  "$(head -n 1 <<<"${EVENTS}")"

MAP="$(unit_map "${EVENTS}")"
check "unit map" "M	${G1}	vps-groundcore-1	groundcore
M	${M1}	vps-mealplan-1	mealplan
M	${G2}	vps-groundcore-2	groundcore" "$(LC_ALL=C sort <<<"${MAP}")"

summarize_sample() {
  { printf '%s\n' "${MAP}"; awk '{ print "E\t" $0 }' <<<"${EVENTS}"; } | summarize_jobs "$1" | LC_ALL=C sort
}
# groundcore-1: build 300 s ok, test 90 s failed, lint still running. groundcore-2: deploy ended before
# the window (no duration), e2e cancelled after 30 s. mealplan-1: 45 s, succeeded with issues.
check "jobs per runner" "vps-groundcore-1	3	2	1	1	0	0	3m 15s
vps-groundcore-2	1	2	1	0	1	0	30s
vps-mealplan-1	1	1	0	0	0	1	45s" "$(summarize_sample runner)"
check "jobs per repository" "groundcore	4	4	2	1	1	0	2m 20s
mealplan	1	1	0	0	0	1	45s" "$(summarize_sample repository)"
check "durations over an hour" "r	1	1	1	0	0	0	1h 01m" \
  "$(printf 'M\tu\tr\tx\nE\t0\tu\tRunning job: a\nE\t3700\tu\tJob a completed with result: Succeeded\n' | summarize_jobs runner)"

# ---------------------------------------------------------------------------------------------
# sshd settings
# ---------------------------------------------------------------------------------------------

# Writes a sample sshd_config folder: main file with an Include, plus the given drop-in files.
sample_sshd() {
  local folder="${SAMPLES}/$1"
  shift
  mkdir -p "${folder}/sshd_config.d"
  printf 'Include %s/sshd_config.d/*.conf\nKbdInteractiveAuthentication no\nUsePAM yes\n' "${folder}" >"${folder}/sshd_config"
  while [[ $# -gt 0 ]]; do
    printf '%b' "$2" >"${folder}/sshd_config.d/$1"
    shift 2
  done
  sshd_config_stream "${folder}/sshd_config" "${folder}" | sshd_first_values
}
NO_NO=$'passwordauthentication no\nkbdinteractiveauthentication no'
check "sshd: ours sorts before cloud-init's" "${NO_NO}" "$(sample_sshd a \
  10-runner-host.conf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  50-cloud-init.conf 'PasswordAuthentication yes\n')"
check "sshd: cloud-init alone turns passwords on" $'passwordauthentication yes\nkbdinteractiveauthentication no' \
  "$(sample_sshd b 50-cloud-init.conf 'PasswordAuthentication yes\n')"
check "sshd: default is yes" $'passwordauthentication yes\nkbdinteractiveauthentication no' "$(sample_sshd c)"
check "sshd: Match blocks don't count, and end with their file" $'passwordauthentication yes\nkbdinteractiveauthentication no' \
  "$(sample_sshd d 05-match.conf 'Match User example\n  PasswordAuthentication no\n' 60-later.conf 'PasswordAuthentication yes\n')"
check "sshd: key=value and the old ChallengeResponse name" "${NO_NO}" \
  "$(sample_sshd e 10-x.conf '  passwordauthentication=no\nChallengeResponseAuthentication no\n')"
if ((EUID != 0)); then
  mkdir -p "${SAMPLES}/f/sshd_config.d"
  printf 'Include %s/sshd_config.d/*.conf\n' "${SAMPLES}/f" >"${SAMPLES}/f/sshd_config"
  printf 'PasswordAuthentication yes\n' >"${SAMPLES}/f/sshd_config.d/50-cloud-init.conf"
  chmod 600 "${SAMPLES}/f/sshd_config.d/50-cloud-init.conf"
  chmod 000 "${SAMPLES}/f/sshd_config.d/50-cloud-init.conf"
  check "sshd: unreadable drop-in fails" "fails" "$(outcome sshd_config_stream "${SAMPLES}/f/sshd_config" "${SAMPLES}/f")"
fi

# ---------------------------------------------------------------------------------------------
# Tables, thresholds, sizes
# ---------------------------------------------------------------------------------------------

check "table alignment and empty cells" "NAME    STATE  JOB
a       idle   -
longer  busy   build (x)" "$(printf 'NAME\tSTATE\tJOB\na\tidle\t\nlonger\tbusy\tbuild (x)\n' | print_table)"
check "disk 5% free" "FAIL" "$(classify_disk 5)"
check "disk 10% free" "WARN" "$(classify_disk 10)"
check "disk 19% free" "WARN" "$(classify_disk 19)"
check "disk 20% free" "PASS" "$(classify_disk 20)"
printf 'MemTotal:        3884512 kB\nMemAvailable:    2100000 kB\nSwapTotal:       4194300 kB\nSwapFree:        4194300 kB\n' \
  >"${SAMPLES}/meminfo"
check "meminfo" "4294963200" "$(meminfo_bytes SwapTotal "${SAMPLES}/meminfo")"
check "meminfo: missing key" "" "$(meminfo_bytes Nope "${SAMPLES}/meminfo")"
check "human bytes" "1.5GiB" "$(human_bytes 1610612736)"

# ---------------------------------------------------------------------------------------------
# .env settings (where jobs install tools)
# ---------------------------------------------------------------------------------------------

RUNNER_USER="$(id -un)" # the tests write files as whoever runs them
TOOL_CACHE_DIR="${SAMPLES}/hostedtoolcache"
check "env settings" "DOTNET_INSTALL_DIR=/home/runner/groundcore-1/.dotnet
AGENT_TOOLSDIRECTORY=${TOOL_CACHE_DIR}
RUNNER_TOOL_CACHE=${TOOL_CACHE_DIR}" "$(runner_env_settings /home/runner/groundcore-1)"
check "merge: empty file" $'A=1\nB=2' "$(printf '' | merge_env A=1 B=2)"
check "merge: keeps other lines, replaces in place, appends the rest" $'LANG=C.UTF-8\nA=1\n\nJAVA_HOME=/x\nB=2' \
  "$(printf 'LANG=C.UTF-8\nA=old\n\nJAVA_HOME=/x\nA=duplicate' | merge_env A=1 B=2)"
check "merge: values with = signs" $'A=x=y' "$(printf 'A=1\n' | merge_env 'A=x=y')"

mkdir -p "${SAMPLES}/home/idle-1" "${SAMPLES}/home/busy-1" "${SAMPLES}/home/done-1" "${SAMPLES}/home/new-1"
for name in idle-1 busy-1 done-1 new-1; do
  printf '{"gitHubUrl": "https://github.com/example-org/example-app"}' >"${SAMPLES}/home/${name}/.runner"
done
printf 'LANG=C.UTF-8\n' >"${SAMPLES}/home/idle-1/.env"
printf 'actions.runner.example-org-example-app.vps-idle-1.service\n' >"${SAMPLES}/home/idle-1/.service"
printf 'actions.runner.example-org-example-app.vps-busy-1.service\n' >"${SAMPLES}/home/busy-1/.service"
runner_env_settings "${SAMPLES}/home/done-1" >"${SAMPLES}/home/done-1/.env"
printf 'actions.runner.example-org-example-app.vps-done-1.service\n' >"${SAMPLES}/home/done-1/.service"
check "write .env: changed" "ok" "$(outcome write_runner_env "${SAMPLES}/home/new-1")"
check "write .env: unchanged the second time" "fails" "$(outcome write_runner_env "${SAMPLES}/home/new-1")"
check "doctor finds runners without the settings" "busy-1,idle-1" \
  "$(RUNNER_HOME="${SAMPLES}/home" runners_missing_settings)"

RESTARTS="${SAMPLES}/restarts"
# shellcheck disable=SC2317,SC2329 # stand-ins, called by the functions under test
systemctl() { echo "$*" >>"${RESTARTS}"; }
# shellcheck disable=SC2317,SC2329
busy_units() { echo "actions.runner.example-org-example-app.vps-busy-1.service"; }
check "configure runners: messages" "    busy-1: settings updated; it is running a job, so restart it afterwards: sudo systemctl restart actions.runner.example-org-example-app.vps-busy-1.service
    idle-1: settings updated and runner restarted" "$(RUNNER_HOME="${SAMPLES}/home" configure_runners)"
check "configure runners: only the idle, changed runner restarts" "restart actions.runner.example-org-example-app.vps-idle-1.service" \
  "$(cat "${RESTARTS}")"
check "configure runners: other .env lines kept" "LANG=C.UTF-8
DOTNET_INSTALL_DIR=${SAMPLES}/home/idle-1/.dotnet
AGENT_TOOLSDIRECTORY=${TOOL_CACHE_DIR}
RUNNER_TOOL_CACHE=${TOOL_CACHE_DIR}" "$(<"${SAMPLES}/home/idle-1/.env")"
check "configure runners: tool cache created" "ok" "$(outcome test -d "${TOOL_CACHE_DIR}")"
check "configure runners: second run changes nothing" "" "$(RUNNER_HOME="${SAMPLES}/home" configure_runners)"
unset -f systemctl

# ---------------------------------------------------------------------------------------------
# Sizing and resize
# ---------------------------------------------------------------------------------------------

check "sizing: VPS-1 (2 cores, 4 GB)" "1" "$(auto_runner_count 4 2)"
check "sizing: VPS-2 (4 cores, 8 GB)" "1" "$(auto_runner_count 8 4)"
check "sizing: VPS-3 (6 cores, 12 GB)" "2" "$(auto_runner_count 12 6)"
check "sizing: VPS-4 (8 cores, 24 GB)" "2" "$(auto_runner_count 24 8)"
check "sizing: lots of memory, 4 cores" "1" "$(auto_runner_count 32 4)"
check "sizing: 12 cores, 48 GB" "4" "$(auto_runner_count 48 12)"
STACK_LABEL=yes
check "labels: runner 1 with stack" "groundcore-ci,groundcore-stack" "$(expected_labels groundcore 1)"
check "labels: runner 2" "groundcore-ci" "$(expected_labels groundcore 2)"
check "labels sorted for comparing" "a-ci,a-stack" "$(sort_labels <<<"a-stack,a-ci,")"
check "count mismatches" "mealplan has 1" \
  "$(printf 'a\tgroundcore\t1\nb\tgroundcore\t2\nc\tmealplan\t1\nd\tunknown\t-\n' | count_mismatches 2)"

# Writes a sample runner folder: <folder name> <repository> [labels] [.service unit]
sample_runner() {
  local directory="${RUNNER_HOME}/$1"
  mkdir -p "${directory}"
  printf '{"agentName": "vps-%s", "agentId": 7, "gitHubUrl": "https://github.com/%s"}' "$1" "$2" >"${directory}/.runner"
  if [[ -n ${3:-} ]]; then echo "$3" >"${directory}/.labels"; fi
  if [[ -n ${4:-} ]]; then echo "$4" >"${directory}/.service"; fi
}
RUNNER_HOME="${SAMPLES}/resize-home"
# shellcheck disable=SC2034 # read by resize_repository
RUNNER_NAME_PREFIX="vps"
sample_runner groundcore-1 Sna-ke/GroundCore groundcore-ci unit-1
sample_runner groundcore-2 Sna-ke/GroundCore "" unit-2
sample_runner groundcore-10 Sna-ke/GroundCore groundcore-ci unit-10
sample_runner groundcore-x Sna-ke/GroundCore
sample_runner mealplan-1 Sna-ke/MealPlan mealplan-ci
check "runner folders of a repository, numeric order" "1	${RUNNER_HOME}/groundcore-1
2	${RUNNER_HOME}/groundcore-2
10	${RUNNER_HOME}/groundcore-10" "$(repository_runner_dirs Sna-ke/groundcore)"
check "repositories with runners" $'Sna-ke/GroundCore\nSna-ke/MealPlan' "$(repositories_with_runners)"

# Stand-ins for everything that would touch GitHub, systemd or the network.
ACTIONS="${SAMPLES}/actions"
# shellcheck disable=SC2317,SC2329
install_runner() { echo "install $1 $2" >>"${ACTIONS}"; }
# shellcheck disable=SC2317,SC2329
remove_runner() { echo "remove ${1##*/}" >>"${ACTIONS}"; [[ -z ${FAIL_REMOVE:-} ]]; }
# shellcheck disable=SC2317,SC2329
reregister_runner() { echo "reregister ${1##*/} $2" >>"${ACTIONS}"; }
# shellcheck disable=SC2317,SC2329
download_runner() { echo "/tmp/archive.tar.gz"; }
# shellcheck disable=SC2317,SC2329
busy_units() { echo "unit-2"; }
# shellcheck disable=SC2317,SC2329
token_available() { [[ -z ${NO_TOKEN:-} ]]; }

# Runs resize_repository for <repo> and prints the summary rows, then the to-do list.
resize_sample() {
  : >"${ACTIONS}"
  resize_repository "$1" >/dev/null
  printf '%s\n' "${RESIZE_ROWS[@]}"
  printf 'TODO %s\n' "${RESIZE_TODO[@]}"
}

RESULT="$(RUNNER_COUNT=1 resize_sample Sna-ke/GroundCore)"
check "shrink: relabel runner 1, remove idle 10, keep busy 2" "vps-groundcore-1	labels groundcore-ci -> groundcore-ci,groundcore-stack	done
vps-groundcore-10	remove (machine fits 1)	done
vps-groundcore-2	remove (machine fits 1)	not done
TODO vps-groundcore-2 (remove (machine fits 1)): it is running a job, and removing it now would cancel the job. \
Run 'sudo ghrunner resize' again once 'ghrunner status' shows it idle." "${RESULT}"
check "shrink: what it did" $'reregister groundcore-1 groundcore-ci,groundcore-stack\nremove groundcore-10' "$(<"${ACTIONS}")"

RESULT="$(RUNNER_COUNT=3 NO_TOKEN=1 resize_sample Sna-ke/GroundCore)"
check "grow without a token: reports, changes nothing" "vps-groundcore-1	labels groundcore-ci -> groundcore-ci,groundcore-stack	not done
vps-groundcore-2	check labels	unknown
vps-groundcore-3	add	not done
vps-groundcore-10	remove (machine fits 3)	not done" "$(grep -v '^TODO' <<<"${RESULT}")"
check "grow without a token: every gap has a why and how" "4" "$(grep -c '^TODO .*: ' <<<"${RESULT}")"
check "grow without a token: nothing touched" "" "$(<"${ACTIONS}")"

RESULT="$(RUNNER_COUNT=1 FAIL_REMOVE=1 resize_sample Sna-ke/GroundCore)"
check "failed unregister says how to finish by hand" "1" \
  "$(grep -c "TODO vps-groundcore-10 .*Settings > Actions > Runners.*sudo rm -rf ${RUNNER_HOME}/groundcore-10" <<<"${RESULT}")"

sample_runner groundcore-1 Sna-ke/GroundCore groundcore-stack,groundcore-ci unit-1
rm -rf "${RUNNER_HOME}/groundcore-2" "${RUNNER_HOME}/groundcore-10"
RESULT="$(RUNNER_COUNT=2 resize_sample Sna-ke/GroundCore)"
check "grow: keeps runner 1, adds runner 2" $'vps-groundcore-1\tkeep\tlabels groundcore-ci,groundcore-stack\nvps-groundcore-2\tadd\tdone' \
  "$(grep -v '^TODO' <<<"${RESULT}")"
check "grow: installed runner 2" "install Sna-ke/GroundCore 2" "$(<"${ACTIONS}")"
# Runs resize_report with one unfinished step.
report_with_todo() {
  RESIZE_ROWS=($'vps-a-1\tadd\tnot done')
  RESIZE_TODO=("vps-a-1 (add): why and how")
  resize_report
}
check "resize report fails when work is left" "fails" "$(outcome report_with_todo)"
check "resize report lists why and how" "1. vps-a-1 (add): why and how" "$(report_with_todo | tail -n 1)"
unset -f install_runner remove_runner reregister_runner download_runner busy_units token_available

# ---------------------------------------------------------------------------------------------
# status and stats end to end, with systemd, the journal and processes replaced by samples
# ---------------------------------------------------------------------------------------------

RUNNER_HOME="${SAMPLES}/no-runner-home" # keep the test machine's own folders out of it
runner_units() { printf '%s\tactive\n%s\tactive\n%s\tfailed\n' "${G1}" "${G2}" "${M1}"; }
busy_units() { echo "${G1}"; }
unit_journal() { if [[ $1 == "${G1}" ]]; then echo "${RUNNER_OUTPUT}"; fi; }
job_events() { echo "${EVENTS}"; }
check "status table" "RUNNER            REPOSITORY  SERVICE  STATE    JOB
vps-groundcore-1  groundcore  active   busy     test (ubuntu-latest, 20)
vps-groundcore-2  groundcore  active   idle     -
vps-mealplan-1    mealplan    failed   stopped  -" "$(status)"
check "job table" "REPOSITORY  STARTED  COMPLETED  SUCCEEDED  FAILED  CANCELLED  OTHER  AVERAGE TIME
groundcore  4        4          2          1       1          0      2m 20s
mealplan    1        1          0          0       0          1      45s" "$(job_table repository "${EVENTS}" "${MAP}")"
check "stats rejects a bad day count" "fails" "$(outcome stats 7x)"

printf '%d passed, %d failed\n' "${PASSED}" "${FAILED}"
((FAILED == 0))
