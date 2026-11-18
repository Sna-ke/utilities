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
  sshd_config_stream "${folder}/sshd_config" "${folder}" | sshd_first_values | head -n 2
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
mkdir -p "${SAMPLES}/g/sshd_config.d"
printf 'Include %s/sshd_config.d/*.conf\nKbdInteractiveAuthentication no\n' "${SAMPLES}/g" >"${SAMPLES}/g/sshd_config"
printf 'Port 22\nPort 9452\nPasswordAuthentication no\nPermitRootLogin no\nMaxAuthTries 3\nDenyUsers runner\n' \
  >"${SAMPLES}/g/sshd_config.d/10-runner-host.conf"
printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' >"${SAMPLES}/g/sshd_config.d/50-cloud-init.conf"
SSH_SAMPLE="$(sshd_config_stream "${SAMPLES}/g/sshd_config" "${SAMPLES}/g" | sshd_first_values)"
check "sshd: every setting the check needs, first value wins, every Port counts" "passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin no
maxauthtries 3
denyusers runner
port 22
port 9452" "${SSH_SAMPLE}"
check "ssh problems: moving ports" "WARN listening on ports 22 9452: confirm the new one so the old one closes" \
  "$(ssh_problems runner <<<"${SSH_SAMPLE}")"
check "ssh problems: none when locked down" "" "$(grep -v '^port 22$' <<<"${SSH_SAMPLE}" | ssh_problems runner)"
check "ssh problems: a stock server" "FAIL password login is on
WARN on port 22, which every scanner tries
WARN root can log in (prohibit-password)
WARN the runner user can log in over SSH
WARN 6 tries per connection" "$(printf 'passwordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\nmaxauthtries 6\nport 22\n' | ssh_problems runner)"

UFW_SAMPLE="Status: active

To                         Action      From
--                         ------      ----
9452/tcp                   LIMIT       Anywhere                   # SSH
22/tcp                     LIMIT       Anywhere                   # SSH
OpenSSH                    ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
9452/tcp (v6)              LIMIT       Anywhere (v6)              # SSH
80/tcp (v6)                ALLOW       Anywhere (v6)
5000/tcp                   DENY        Anywhere"
check "firewall: SSH moved, leftovers" "also lets in 22/tcp
also lets in OpenSSH
also lets in 80/tcp" "$(firewall_problems 9452 <<<"${UFW_SAMPLE}")"
check "firewall: still on 22, plain allow" "OpenSSH has no rate limit
also lets in 80/tcp" "$(firewall_problems "22 9452" <<<"${UFW_SAMPLE}")"
check "firewall: clean" "" "$(firewall_problems 9452 <<<"$(grep -vE '^(22/tcp|OpenSSH|80/tcp)' <<<"${UFW_SAMPLE}")")"
check "firewall: a component's port is allowed" "also lets in 22/tcp
also lets in OpenSSH" "$(firewall_problems 9452 "80/tcp" <<<"${UFW_SAMPLE}")"

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
# shellcheck disable=SC2317,SC2329
repository_visibility() { echo "${VISIBILITY:-private}"; }

# Runs resize_repository for <repo> and prints the summary rows, then the to-do list.
resize_sample() {
  : >"${ACTIONS}"
  resize_repository "$1" >/dev/null
  printf '%s\n' "${RESIZE_ROWS[@]}"
  printf 'TODO %s\n' "${STILL_TO_DO[@]}"
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
  STILL_TO_DO=("vps-a-1 (add): why and how")
  resize_report
}
RESULT="$(RUNNER_COUNT=2 VISIBILITY=public resize_sample Sna-ke/GroundCore)"
check "public repository: nothing touched, says why" "1" "$(grep -c '^TODO Sna-ke/GroundCore .*public repository' <<<"${RESULT}")"
check "public repository: no actions" "" "$(<"${ACTIONS}")"
check "resize report fails when work is left" "fails" "$(outcome report_with_todo)"
check "resize report lists why and how" "1. vps-a-1 (add): why and how" "$(report_with_todo | tail -n 1)"
unset -f install_runner remove_runner reregister_runner download_runner busy_units token_available repository_visibility

# ---------------------------------------------------------------------------------------------
# version and self-update
# ---------------------------------------------------------------------------------------------

mkdir -p "${SAMPLES}/installed/github-runner" "${SAMPLES}/installed/host"
printf 'echo one\n' >"${SAMPLES}/installed/github-runner/setup-runner.sh"
printf '' >"${SAMPLES}/installed/github-runner/runner-lib.sh"
printf 'tab\there\0nul\n' >"${SAMPLES}/installed/github-runner/ghrunner.sh"
if command -v git >/dev/null; then
  for file in setup-runner.sh runner-lib.sh ghrunner.sh; do
    check "blob hash matches git: ${file}" "$(git hash-object "${SAMPLES}/installed/github-runner/${file}")" \
      "$(git_blob_sha "${SAMPLES}/installed/github-runner/${file}")"
  done
fi
COMMITS_JSON="$(jq -cn '[
  {sha: ("c" * 40), commit: {committer: {date: "2026-11-20T10:00:00Z"}, message: "Newest change\n\nBody text"}},
  {sha: ("b" * 40), commit: {committer: {date: "2026-11-18T10:00:00Z"}, message: "Middle change"}},
  {sha: ("a" * 40), commit: {committer: {date: "2026-11-17T10:00:00Z"}, message: "Installed one"}}]')"
COMMITS="$(parse_commits <<<"${COMMITS_JSON}")"
check "commit list" "$(printf 'c%.0s' {1..40})	2026-11-20	Newest change" "$(head -n 1 <<<"${COMMITS}")"
check "changes since the installed commit" "ccccccc  2026-11-20  Newest change
bbbbbbb  2026-11-18  Middle change" "$(commits_since "$(printf 'a%.0s' {1..40})" <<<"${COMMITS}")"
check "changes since an unknown commit: newest ones" "3" "$(commits_since unknown <<<"${COMMITS}" | wc -l | tr -d ' ')"

BLOBS_JSON="$(jq -cn --arg s "$(git_blob_sha "${SAMPLES}/installed/github-runner/setup-runner.sh")" \
  --arg l "$(git_blob_sha "${SAMPLES}/installed/github-runner/runner-lib.sh")" \
  --arg g "$(git_blob_sha "${SAMPLES}/installed/github-runner/ghrunner.sh")" '[
  {name: "README.md", type: "file", sha: "0000"}, {name: "tests", type: "dir", sha: "1111"},
  {name: "setup-runner.sh", type: "file", sha: $s}, {name: "runner-lib.sh", type: "file", sha: $l},
  {name: "ghrunner.sh", type: "file", sha: $g}]')"
BLOBS="$(parse_blobs github-runner <<<"${BLOBS_JSON}")"
check "file list: scripts only, with their folder" "github-runner/setup-runner.sh
github-runner/runner-lib.sh
github-runner/ghrunner.sh" "$(cut -f1 <<<"${BLOBS}")"
check "installed files match" "ok" "$(outcome files_match "${SAMPLES}/installed" "${BLOBS}")"
printf 'echo two\n' >"${SAMPLES}/installed/github-runner/setup-runner.sh"
check "a changed file doesn't match" "fails" "$(outcome files_match "${SAMPLES}/installed" "${BLOBS}")"
check "a missing file doesn't match" "fails" "$(outcome files_match "${SAMPLES}/nowhere" "${BLOBS}")"
check "an empty listing doesn't match" "fails" "$(outcome files_match "${SAMPLES}/installed" "")"
check "version in host-lib.sh" "${TOOLS_VERSION}" "$(version_from_text <"${TESTS_DIR}/../../host/host-lib.sh")"
check "version of a 1.x runner-lib.sh" "1.5.0" "$(version_from_text <<<'GHRUNNER_VERSION="1.5.0"')"
check "version: none in an old copy" "" "$(version_from_text <<<'GITHUB_OWNER="x"')"
check "newer: 1.10.0 vs 1.9.0" "ok" "$(outcome version_newer 1.10.0 1.9.0)"
check "newer: same version" "fails" "$(outcome version_newer 1.3.0 1.3.0)"
check "newer: older" "fails" "$(outcome version_newer 1.2.9 1.3.0)"
check "changelog has a line for this version" "1" \
  "$(changelog_since 0 <"${TESTS_DIR}/../../host/CHANGELOG.md" | grep -c "^${TOOLS_VERSION//./\\.}  ")"
CHANGELOG_SAMPLE="| Version | Date | Changes |
| --- | --- | --- |
| 1.10.0 | 2026-12-01 | Ten |
| 1.9.0 | 2026-11-30 | Nine, with \`code\` |
| 1.3.0 | 2026-11-17 | Three |"
check "changelog since 1.3.0" "1.10.0  2026-12-01  Ten
1.9.0  2026-11-30  Nine, with \`code\`" "$(changelog_since 1.3.0 <<<"${CHANGELOG_SAMPLE}")"
check "changelog since an old copy: everything" "3" \
  "$(changelog_since "1.2.0 or older" <<<"${CHANGELOG_SAMPLE}" | wc -l | tr -d ' ')"
check "changelog since the latest: nothing" "" "$(changelog_since 1.10.0 <<<"${CHANGELOG_SAMPLE}")"
check "describe version with commit" "1.3.0 (commit abcdef1)" "$(describe_version 1.3.0 abcdef1234567890)"
check "describe version, commit unknown" "1.3.0" "$(describe_version 1.3.0 unknown)"
check "installed version of an old copy" "1.2.0 or older" "$(TOOLS_DIR="${SAMPLES}/installed" installed_version)"
check "self-update without root" "fails" "$(outcome bash "${TESTS_DIR}/../ghrunner.sh" self-update --bogus)"

# ---------------------------------------------------------------------------------------------
# Security: repository visibility, SSH settings, audit
# ---------------------------------------------------------------------------------------------

check "visibility: public" "public" "$(visibility_from_response 200 '{"private": false}')"
check "visibility: private (with a token)" "private" "$(visibility_from_response 200 '{"private": true}')"
check "visibility: hidden means private" "private" "$(visibility_from_response 404 '{"message": "Not Found"}')"
check "visibility: rate limited" "unknown" "$(visibility_from_response 403 '{}')"

# setup-host.sh's functions (it only runs when executed, not when sourced).
# shellcheck source=SCRIPTDIR/../../host/setup-host.sh
. "${TESTS_DIR}/../../host/setup-host.sh"
# hostctl.sh's functions too (audit_findings).
# shellcheck source=SCRIPTDIR/../../host/hostctl.sh
. "${TESTS_DIR}/../../host/hostctl.sh"
trap - ERR
COMPONENTS_FILE="${SAMPLES}/components"
echo "github-runner" >"${COMPONENTS_FILE}"
trap - ERR
check "ssh port 22" "ok" "$(outcome valid_ssh_port 22)"
check "ssh port 9452" "ok" "$(outcome valid_ssh_port 9452)"
check "ssh port 80 refused" "fails" "$(outcome valid_ssh_port 80)"
check "ssh port 70000 refused" "fails" "$(outcome valid_ssh_port 70000)"
check "ssh port text refused" "fails" "$(outcome valid_ssh_port 22a)"
# shellcheck disable=SC2317,SC2329
has_terminal() { return 1; }
check "no terminal keeps the port" "9452" "$(choose_ssh_port 9452)"
check "no terminal never moves off 22" "22" "$(choose_ssh_port 22)"
check "SSH_PORT wins" "2200" "$(SSH_PORT=2200 choose_ssh_port 22)"
# Runs choose_ssh_port with SSH_PORT=80, which should stop with an error.
choose_bad_port() {
  SSH_PORT=80
  choose_ssh_port 22
}
check "a bad SSH_PORT stops" "fails" "$(outcome choose_bad_port)"
unset -f has_terminal
SETTINGS="$(ssh_settings yes no 22 9452)"
check "ssh settings: both ports while moving" $'Port 22\nPort 9452' "$(grep '^Port' <<<"${SETTINGS}")"
check "ssh settings: keys only" $'PasswordAuthentication no\nKbdInteractiveAuthentication no' \
  "$(grep -E '^(Password|KbdInteractive)' <<<"${SETTINGS}")"
check "ssh settings: the component's service account can't log in" "DenyUsers ${RUNNER_USER}" "$(grep '^DenyUsers' <<<"${SETTINGS}")"
check "ssh settings: no key, password stays" "" "$(ssh_settings no prohibit-password 22 | grep '^PasswordAuthentication' || true)"

check "audit users" "users	root	uid=0 shell=/bin/bash
users	ubuntu	uid=1000 shell=/bin/bash
users	runner	uid=1001 shell=/bin/bash
users	sneaky	uid=999 shell=/bin/sh" "$(audit_users <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash
runner:x:1001:1001::/home/runner:/bin/bash
sneaky:x:999:999::/var/lib/x:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
)"
check "public listeners" "tcp 9452
udp 68" "$(public_listeners <<'EOF'
tcp   LISTEN 0      4096       0.0.0.0:9452       0.0.0.0:*
tcp   LISTEN 0      4096          [::]:9452          [::]:*
tcp   LISTEN 0      4096     127.0.0.53%lo:53     0.0.0.0:*
tcp   LISTEN 0      4096     127.0.0.1:5432     0.0.0.0:*
tcp   LISTEN 0      4096         [::1]:631          [::]:*
udp   UNCONN 0      0     10.0.0.5%ens3:68       0.0.0.0:*
udp   UNCONN 0      0        127.0.0.1:323       0.0.0.0:*
EOF
)"
check "ssh logins" "brian from 203.0.113.7
root from 198.51.100.9" "$(parse_logins <<'EOF'
Accepted publickey for brian from 203.0.113.7 port 51234 ssh2: ED25519 SHA256:abc
Accepted publickey for brian from 203.0.113.7 port 51240 ssh2: ED25519 SHA256:abc
Failed password for invalid user admin from 192.0.2.1 port 4444 ssh2
Accepted keyboard-interactive/pam for root from 198.51.100.9 port 1 ssh2
EOF
)" || true
check "newest kernel" "6.8.0-51-generic" "$(printf 'vmlinuz-6.8.0-9-generic\nvmlinuz-6.8.0-51-generic\nvmlinuz-6.8.0-49-generic\n' | newest_kernel)"

STATE_DIR="${SAMPLES}/state"
AUDIT_BASELINE="${STATE_DIR}/audit-baseline"
AUDIT_STATUS="${STATE_DIR}/audit-status"
printf 'firewall\tStatus: active\t-\nlogins\tbrian from 203.0.113.7\t-\nsudo\t/etc/sudoers\taaaa\nusers\trunner\tuid=1001 shell=/bin/bash\n' \
  >"${SAMPLES}/snapshot-1"
audit_accept "${SAMPLES}/snapshot-1"
check "baseline has its format line" "${AUDIT_FORMAT}" "$(head -n 1 "${AUDIT_BASELINE}")"
check "baseline is root-only" "600" "$(stat -c %a "${AUDIT_BASELINE}")"
check "no changes" "" "$(audit_diff "${AUDIT_BASELINE}" "${SAMPLES}/snapshot-1")"
printf 'firewall\tStatus: inactive\t-\nlistening\ttcp 4444\t-\nsudo\t/etc/sudoers\tbbbb\nusers\trunner\tuid=1001 shell=/bin/bash\n' \
  >"${SAMPLES}/snapshot-2"
check "changes: added, changed, removed; logins that aged out don't count" "firewall	added	Status: inactive
firewall	removed	Status: active
listening	added	tcp 4444
sudo	changed	/etc/sudoers" "$(audit_diff "${AUDIT_BASELINE}" "${SAMPLES}/snapshot-2")"
printf 'logins\tmallory from 192.0.2.66\t-\n' >>"${SAMPLES}/snapshot-1"
check "a login from a new address counts" "logins	added	mallory from 192.0.2.66" \
  "$(audit_diff "${AUDIT_BASELINE}" "${SAMPLES}/snapshot-1")"
audit_accept "${SAMPLES}/snapshot-2"
check "accepting keeps known logins" "1" "$(grep -c '^logins	brian from 203.0.113.7' "${AUDIT_BASELINE}")"

# A host updating from 1.x: its baseline's sections for the tools' files moved (ghrunner -> tools).
check "1.x baseline header, exactly as 1.x wrote it" "# ghrunner audit baseline, format 1" "${AUDIT_FORMAT_1}"
printf '%s\nghrunner\t/usr/local/bin/ghrunner\taaaa\nsudo\t/etc/sudoers\tbbbb\n' "${AUDIT_FORMAT_1}" >"${SAMPLES}/baseline-1"
printf 'ghrunner\t/usr/local/bin/ghrunner\tzzzz\nsudo\t/etc/sudoers\tbbbb\ntools\t/usr/local/bin/hostctl\tcccc\n' >"${SAMPLES}/snapshot-3"
check "1.x baseline: the moved sections don't count" "" "$(audit_findings "${SAMPLES}/baseline-1" "${SAMPLES}/snapshot-3")"
printf 'sudo\t/etc/sudoers.d/extra\tdddd\n' >>"${SAMPLES}/snapshot-3"
check "1.x baseline: a real change still does" "sudo	added	/etc/sudoers.d/extra" "$(audit_findings "${SAMPLES}/baseline-1" "${SAMPLES}/snapshot-3")"

ALERTS="${SAMPLES}/alerts"
# shellcheck disable=SC2317,SC2329
send_alert() { echo "$1" >>"${ALERTS}"; }
audit_record "$(printf 'sudo\tchanged\t/etc/sudoers')"
check "a manual check doesn't alert" "fails" "$(outcome test -e "${ALERTS}")"
audit_record "$(printf 'sudo\tchanged\t/etc/sudoers')" yes
check "findings: status for doctor" "1" "$(cut -f2 "${AUDIT_STATUS}")"
check "findings: note for the next login" "1" "$(grep -c 'nobody accepted' "${STATE_DIR}/attention/audit")"
check "findings: one alert" "audit found 1 unexpected change(s)" "$(cat "${ALERTS}")"
audit_record "$(printf 'sudo\tchanged\t/etc/sudoers')" yes
check "same findings tomorrow: no second alert" "1" "$(wc -l <"${ALERTS}" | tr -d ' ')"
audit_record ""
check "all clear: login note removed" "fails" "$(outcome test -e "${STATE_DIR}/attention/audit")"
check "all clear: status 0" "0" "$(cut -f2 "${AUDIT_STATUS}")"
unset -f send_alert

# ---------------------------------------------------------------------------------------------
# doctor: kernel settings, Pushover, fixable problems
# ---------------------------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329
current_kernel_value() { if [[ $1 == "kernel.dmesg_restrict" ]]; then echo 0; else grep -m1 "^$1=" <<<"$(printf '%s\n' "${KERNEL_SETTINGS[@]}")" | cut -d= -f2; fi; }
DOCTOR_ROWS=()
DOCTOR_FIXABLE=0
check_kernel_settings
check "kernel settings: one off" "Kernel settings	WARN	not hardened: kernel.dmesg_restrict=0" "${DOCTOR_ROWS[0]}"
# shellcheck disable=SC2317,SC2329
current_kernel_value() { if [[ $1 == net.ipv6.* ]]; then return 1; fi; grep -m1 "^$1=" <<<"$(printf '%s\n' "${KERNEL_SETTINGS[@]}")" | cut -d= -f2; }
DOCTOR_ROWS=()
check_kernel_settings
check "kernel settings: IPv6 turned off isn't a problem" "Kernel settings	PASS	no redirects or source routing; kernel addresses hidden" "${DOCTOR_ROWS[0]}"
check "a fixable warning marks doctor --fix" "1" "${DOCTOR_FIXABLE}"
unset -f current_kernel_value
DOCTOR_ROWS=()
DOCTOR_FIXABLE=0
record WARN "Kernel" "reboot when convenient"
check "a warning setup can't fix doesn't" "0" "${DOCTOR_FIXABLE}"
record PASS "SSH" "fine" fix
check "a pass never does" "0" "${DOCTOR_FIXABLE}"

check "pushover key" "ok" "$(outcome valid_pushover_key "$(printf 'a%.0s' {1..30})")"
check "pushover key: too short" "fails" "$(outcome valid_pushover_key abc)"
check "pushover key: not letters and digits" "fails" "$(outcome valid_pushover_key "$(printf 'a%.0s' {1..29})-")"
PUSHOVER_FILE="${SAMPLES}/pushover"
check "pushover: off without a file" "" "$(pushover_settings)"
printf 'PUSHOVER_USER=%s\nPUSHOVER_TOKEN=%s\n' "$(printf 'u%.0s' {1..30})" "$(printf 't%.0s' {1..30})" >"${PUSHOVER_FILE}"
check "pushover: settings" "$(printf 'u%.0s' {1..30})	$(printf 't%.0s' {1..30})" "$(pushover_settings)"
check "curl config quoting" 'form-string = "message=say \"hi\"\nC:\\temp"' "$(pushover_field message $'say "hi"\nC:\\temp')"
check "pushover reply ok" "ok" "$(outcome pushover_ok <<<'{"status":1,"request":"x"}')"
check "pushover reply refused" "fails" "$(outcome pushover_ok <<<'{"status":0,"errors":["application token is invalid"]}')"

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
