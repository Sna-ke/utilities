# shellcheck shell=bash
# hostctl's shared code: settings, messages, downloads checked against GitHub, alerts, the audit, and
# the doctor checks every host gets. Sourced by setup-host.sh, hostctl.sh and the components (the
# GitHub runner, Portainer), never run on its own.
#
# Layout. The repository's folders (host/, github-runner/, ...) are copied as they are to TOOLS_DIR, so
# the same relative paths work in a checkout, a download folder and the installed copy.
#
# Components. Each one is a folder with a library that defines hooks named <prefix>_<hook>, all optional:
#   setup             install and configure the component (setup-host.sh runs it after the host steps)
#   install_commands  link the component's commands into /usr/local/bin
#   checks            add rows to "hostctl doctor" (with record)
#   pause, resume     stop and restart work around the weekly update (pause fails to skip the update)
#   upgrade           after the packages, bring the component's own software up to date (Portainer:
#                     the newest image of its tag)
#   update_report     print the component's part of "hostctl update"
#   prune_level       "full" (CI: volumes too) or "images" (production: never volumes)
#   firewall_allowed  ports besides SSH the component opens, e.g. "9443/tcp" (doctor accepts them)
#   ssh_deny_users    service accounts that must never log in over SSH
#   notes             what to do next, printed at the end of setup
#
# Secrets: none in the repository. GITHUB_TOKEN is read from the environment and never written to disk;
# the Pushover key and token, and component secrets, live in root-only files on the host.

# The version of every script in host/ and the component folders. Every pull request that changes one
# raises it and adds a line to host/CHANGELOG.md; CI checks both (github-runner/tests/version-check.sh).
# shellcheck disable=SC2034 # read by the scripts that source this file
TOOLS_VERSION="2.2.0"
# Where self-update and the installer get new versions.
TOOLS_REPO="${TOOLS_REPO:-Sna-ke/utilities}"
TOOLS_BRANCH="${TOOLS_BRANCH:-main}"
# The installed copy, its state (audit baseline, notes for the next login) and its settings (root only).
TOOLS_DIR="/usr/local/lib/hostctl"
STATE_DIR="/var/lib/hostctl"
CONFIG_DIR="/etc/hostctl"
COMPONENTS_FILE="${CONFIG_DIR}/components"
# Pushover user key and application token for alerts (PUSHOVER_USER=..., PUSHOVER_TOKEN=...).
PUSHOVER_FILE="${CONFIG_DIR}/pushover"
# shellcheck disable=SC2034 # read by setup-host.sh and hostctl.sh
PRUNE_SCRIPT="/etc/cron.weekly/docker-prune"
# Kernel settings setup writes (/etc/sysctl.d/90-runner-hardening.conf) and doctor checks: ignore ICMP
# redirects and source-routed packets (both let others reroute this VM's traffic), send no redirects,
# and hide kernel addresses from unprivileged users.
KERNEL_SETTINGS=(
  net.ipv4.conf.all.accept_redirects=0
  net.ipv4.conf.default.accept_redirects=0
  net.ipv6.conf.all.accept_redirects=0
  net.ipv6.conf.default.accept_redirects=0
  net.ipv4.conf.all.send_redirects=0
  net.ipv4.conf.default.send_redirects=0
  net.ipv4.conf.all.accept_source_route=0
  net.ipv6.conf.all.accept_source_route=0
  kernel.kptr_restrict=2
  kernel.dmesg_restrict=1
)
# Components: <name>:<folder>:<library>:<hook prefix>.
TOOLS_COMPONENTS=(
  github-runner:github-runner:runner-lib.sh:runner
  portainer-server:portainer:portainer-lib.sh:pserver
  portainer-node:portainer:portainer-lib.sh:pnode
)
# What setup and resize couldn't do, with why and how to finish; printed at the end.
STILL_TO_DO=()
COMMAND_LINE=""
PROGRAM="hostctl"

# ---------------------------------------------------------------------------------------------
# Messages, terminal, versions
# ---------------------------------------------------------------------------------------------

# From a host-lib.sh (or a runner-lib.sh before 2.0.0) on stdin, prints its version, or nothing.
version_from_text() {
  sed -nE 's/^(TOOLS|GHRUNNER)_VERSION="([^"]+)".*/\2/p' | head -n 1
}

# True when version <a> is newer than <b> (numeric order: 1.10.0 is newer than 1.9.0).
version_newer() {
  [[ $1 != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# True when there is a terminal to ask questions on (not under cron, systemd or "self-update --yes").
has_terminal() {
  { true </dev/tty; } 2>/dev/null
}

# Prints a step heading, so long runs show where they are.
log() { printf '\n==> %s\n' "$*"; }

# Prints an indented detail line under the current step.
note() { printf '    %s\n' "$*"; }

# Prints an error and stops; every failure goes through here so messages look the same.
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Asks a yes/no question on the terminal; anything but "y" or "yes" is no.
confirm() {
  local answer
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r answer </dev/tty
  [[ ${answer,,} == "y" || ${answer,,} == "yes" ]]
}

# Prints the git blob hash of a file (what "git hash-object" prints), to compare it with GitHub's.
git_blob_sha() {
  { printf 'blob %d\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -d' ' -f1
}

# Calls GitHub's API for TOOLS_REPO (public, so no token; GITHUB_TOKEN is for the runner repositories).
github_api() {
  curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${TOOLS_REPO}/$1"
}

# From GitHub's commit list on stdin, prints "<sha>\t<date>\t<title>" for each commit, newest first.
parse_commits() {
  jq -r '.[] | [.sha, (.commit.committer.date | .[0:10]), (.commit.message | split("\n")[0])] | join("\t")'
}

# ---------------------------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------------------------

# Prints one field (folder, library or prefix) of a component; fails for an unknown one.
component_field() {
  local entry name folder library prefix
  for entry in "${TOOLS_COMPONENTS[@]}"; do
    IFS=: read -r name folder library prefix <<<"${entry}"
    [[ ${name} == "$1" ]] || continue
    case "$2" in
      folder) echo "${folder}" ;;
      library) echo "${library}" ;;
      prefix) echo "${prefix}" ;;
    esac
    return
  done
  return 1
}

# Lists the components installed on this host, one per line.
installed_components() {
  if [[ -r ${COMPONENTS_FILE} ]]; then sed '/^[[:space:]]*$/d; /^#/d' "${COMPONENTS_FILE}"; fi
}

# Adds components to the installed list (keeping those already there).
register_components() {
  local component
  for component in "$@"; do component_field "${component}" folder >/dev/null || die "unknown component '${component}'"; done
  install -d -m 0700 "${CONFIG_DIR}"
  { installed_components; printf '%s\n' "$@"; } | awk 'NF && !seen[$0]++' >"${COMPONENTS_FILE}.new"
  mv "${COMPONENTS_FILE}.new" "${COMPONENTS_FILE}"
}

# Removes components from the installed list (their own remove command has undone their setup).
unregister_components() {
  local component
  [[ -f ${COMPONENTS_FILE} ]] || return 0
  installed_components | grep -vxF -f <(printf '%s\n' "$@") >"${COMPONENTS_FILE}.new" || true
  mv "${COMPONENTS_FILE}.new" "${COMPONENTS_FILE}"
  for component in "$@"; do note "${component} removed from hostctl's components"; done
}

# Prints the folders a set of components needs: host first, then each component's folder, once.
tool_folders() {
  local component
  {
    echo "host"
    for component in "$@"; do
      component_field "${component}" folder
      case "${component}" in portainer-server|portainer-node) echo network ;; esac
    done
  } | awk '!seen[$0]++'
}

# True when setup-host.sh will migrate a pre-2.0.0 runner installation.
legacy_runner_present() {
  [[ -d /var/lib/ghrunner || -d /etc/ghrunner ]]
}

# Components setup-host.sh will load: newly requested ones, already registered ones, and any runner
# found in the old 1.x layout. Include them all in a one-line install's verified download; otherwise
# load_components and install_tools fail when adding Portainer to an existing runner VM.
components_for_setup() {
  {
    printf '%s\n' "$@"
    installed_components
    if legacy_runner_present; then echo github-runner; fi
  } | awk 'NF && !seen[$0]++'
}

# Sources the libraries of the installed components from <root> (a checkout, a download or TOOLS_DIR),
# each library once (the Portainer server and node share one).
load_components() {
  local root="$1" component library
  local -A loaded=()
  while read -r component; do
    [[ -n ${component} ]] || continue
    library="${root}/$(component_field "${component}" folder)/$(component_field "${component}" library)"
    [[ -z ${loaded[${library}]+set} ]] || continue
    loaded["${library}"]=1
    # shellcheck source=/dev/null # the component libraries are checked on their own
    . "${library}"
  done < <(installed_components)
}

# Runs hook <name> of every installed component that has it, with the remaining arguments. Fails as soon
# as one fails.
call_hooks() {
  local hook="$1" component prefix
  shift
  while read -r component; do
    [[ -n ${component} ]] || continue
    prefix="$(component_field "${component}" prefix)"
    if declare -F "${prefix}_${hook}" >/dev/null; then "${prefix}_${hook}" "$@" || return 1; fi
  done < <(installed_components)
}

# ---------------------------------------------------------------------------------------------
# Getting a version from GitHub (host/install.sh, "hostctl self-update")
# ---------------------------------------------------------------------------------------------

# Prints the latest commits on TOOLS_BRANCH, newest first (up to 30).
latest_commits() {
  github_api "commits?sha=${TOOLS_BRANCH}&per_page=30" | parse_commits
}

# From a folder listing (GitHub's contents API) on stdin, prints "<folder>/<name>\t<blob sha>" for each
# script in it (the files a version is made of; tests and documents aren't installed).
parse_blobs() {
  jq -r --arg folder "$1" '.[] | select(.type == "file" and (.name | endswith(".sh")))
    | [($folder + "/" + .name), .sha] | join("\t")'
}

# Prints "<folder>/<name>\t<blob sha>" for the scripts of each folder given, at <commit>.
blobs_at() {
  local commit="$1" folder
  shift
  for folder in "$@"; do
    github_api "contents/${folder}?ref=${commit}" | parse_blobs "${folder}" || return 1
  done
}

# Downloads a file of the repository (<path>, e.g. host/CHANGELOG.md) at <commit> and prints it.
file_at() {
  curl -fsSL --max-time 60 "https://raw.githubusercontent.com/${TOOLS_REPO}/$1/$2"
}

# True when every file listed in <blobs> ("<folder>/<name>\t<sha>" lines) is under <root> with that hash.
files_match() {
  local root="$1" blobs="$2" path want
  [[ -n ${blobs} ]] || return 1
  while IFS=$'\t' read -r path want; do
    [[ -f ${root}/${path} && "$(git_blob_sha "${root}/${path}")" == "${want}" ]] || return 1
  done <<<"${blobs}"
}

# Downloads every file listed in <blobs> at <commit> under <root>, keeping the folders, and checks each
# against GitHub's hash, so a cut-off or mixed download never runs.
download_version() {
  local commit="$1" root="$2" blobs="$3" path _
  while IFS=$'\t' read -r path _; do
    install -d "${root}/$(dirname "${path}")"
    curl -fsSL --max-time 60 -o "${root}/${path}" "https://raw.githubusercontent.com/${TOOLS_REPO}/${commit}/${path}"
  done <<<"${blobs}"
  files_match "${root}" "${blobs}" || die "the downloaded files don't match GitHub's hashes for ${commit}"
}

# The commit recorded at install, or "unknown" (setup run from a download by hand).
installed_commit() {
  local commit=""
  if [[ -r ${TOOLS_DIR}/VERSION ]]; then commit="$(<"${TOOLS_DIR}/VERSION")"; fi
  echo "${commit:-unknown}"
}

# The installed version number, from the installed host-lib.sh (or the ghrunner install before 2.0.0).
installed_version() {
  local version=""
  if [[ -r ${TOOLS_DIR}/host/host-lib.sh ]]; then
    version="$(version_from_text <"${TOOLS_DIR}/host/host-lib.sh")"
  elif [[ -r /usr/local/lib/ghrunner/runner-lib.sh ]]; then
    version="$(version_from_text </usr/local/lib/ghrunner/runner-lib.sh)"
  fi
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

# Prints what changed between the installed version and <latest commit>: the changelog entries when
# that version has a changelog, else the commit titles.
whats_new() {
  local latest="$1" commits="$2" changes line
  changes="$(file_at "${latest}" host/CHANGELOG.md 2>/dev/null | changelog_since "$(installed_version)" || true)"
  if [[ -z ${changes} ]]; then changes="$(commits_since "$(installed_commit)" <<<"${commits}")"; fi
  while IFS= read -r line; do note "${line}"; done <<<"${changes}"
}

# ---------------------------------------------------------------------------------------------
# Machine facts and output
# ---------------------------------------------------------------------------------------------

# Total memory in whole gigabytes, rounded to the nearest (a "4 GB" VPS reports about 3.8).
memory_gb() {
  awk '/MemTotal/ { printf "%d", ($2 / 1024 / 1024) + 0.5 }' /proc/meminfo
}

# Number of CPU cores.
cpu_count() {
  nproc
}

# Records something that needs attention under <topic> (e.g. audit, update); shown at every SSH login
# (/etc/update-motd.d/95-hostctl) and by "hostctl doctor" until cleared. Text comes on stdin.
set_attention() {
  install -d -m 0755 "${STATE_DIR}/attention"
  cat >"${STATE_DIR}/attention/$1"
}

# Clears the note under <topic>.
clear_attention() {
  rm -f "${STATE_DIR}/attention/$1"
}

# True for a Pushover user key or application token: 30 letters and digits.
valid_pushover_key() {
  [[ $1 =~ ^[A-Za-z0-9]{30}$ ]]
}

# Prints "<user key>\t<application token>" from the Pushover settings, or nothing when alerts are off.
pushover_settings() {
  [[ -r ${PUSHOVER_FILE} ]] || return 0
  awk -F= '$1 == "PUSHOVER_USER" { user = $2 } $1 == "PUSHOVER_TOKEN" { token = $2 }
    END { if (user != "" && token != "") print user "\t" token }' "${PUSHOVER_FILE}"
}

# Prints one form field as a curl config line, quoted the way curl's config files need.
pushover_field() {
  local value="${2//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf 'form-string = "%s=%s"\n' "$1" "${value}"
}

# Posts the form fields on stdin (pushover_field lines) to Pushover's API at <path> and prints the reply.
# The fields go to curl on stdin, so the token and user key never show in the process list.
pushover_post() {
  curl -sS --max-time 20 -K - "https://api.pushover.net/$1"
}

# True when Pushover's reply on stdin says the request worked ("status": 1).
pushover_ok() {
  [[ "$(jq -r '.status // 0' 2>/dev/null)" == "1" ]]
}

# True when Pushover accepts <user key> with <application token>, and the user has a device to alert.
pushover_valid() {
  { pushover_field token "$2"; pushover_field user "$1"; } | pushover_post 1/users/validate.json 2>/dev/null | pushover_ok
}

# Logs <title> and <message>, and sends them to Pushover when alerts are on. <priority> 1 (high) sounds
# even in quiet hours; the audit uses it. A failed send is logged, never fatal.
send_alert() {
  local title="$1" message="$2" priority="${3:-0}" user="" token=""
  logger -t hostctl "${title}: ${message}"
  IFS=$'\t' read -r user token <<<"$(pushover_settings)"
  [[ -n ${user} && -n ${token} ]] || return 0
  if ! {
    pushover_field token "${token}"
    pushover_field user "${user}"
    pushover_field title "$(hostname -s): ${title}"
    pushover_field message "${message:0:1000}"
    pushover_field priority "${priority}"
  } | pushover_post 1/messages.json 2>/dev/null | pushover_ok; then
    logger -t hostctl "Pushover didn't take the alert"
  fi
}

# True when <unit> is one of the lines of <list> (e.g. the busy units).
unit_in_list() {
  [[ -n $1 ]] && grep -qxF -- "$1" <<<"$2"
}

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
  [[ ${EUID} -eq 0 ]] || die "run with sudo: sudo ${PROGRAM} ${COMMAND_LINE}"
}

# Stops if a command that takes no arguments was given some, so typos don't pass silently.
no_arguments() {
  [[ $# -eq 0 ]] || die "unexpected argument '$1' (see: ${PROGRAM} help)"
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
# Updates and reboots
# ---------------------------------------------------------------------------------------------

# Upgrades system packages the way setup-host.sh does, and prints apt's one-line summary.
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
    echo "needed: run 'sudo reboot' (services and runners restart by themselves)${packages:+; for ${packages}}"
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

# Prints what needs a reboot, for people: a waiting kernel first, as that is the one that matters.
reboot_reason() {
  local kernel
  kernel="$(kernel_waiting)"
  if [[ -n ${kernel} ]]; then
    echo "kernel ${kernel} is installed but $(uname -r) is running: reboot when convenient (sudo reboot; services and runners restart by themselves)"
  elif [[ -f /var/run/reboot-required ]]; then
    reboot_state
  fi
}

# ---------------------------------------------------------------------------------------------
# Audit: has anything changed that nobody accepted?
#
# Setup records a baseline of everything that decides who can get in and what runs as root. The daily
# timer compares the machine with it. A change nobody made is the sign this VM has been tampered with;
# the README says what to do then.
# ---------------------------------------------------------------------------------------------

AUDIT_BASELINE="${STATE_DIR}/audit-baseline"
AUDIT_STATUS="${STATE_DIR}/audit-status"
AUDIT_FORMAT="# hostctl audit baseline, format 2"
# Baselines from before 2.0.0, compared without the sections that moved (tools, previously "ghrunner").
AUDIT_FORMAT_1="# ghrunner audit baseline, format 1"

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

# Services and timers that start by themselves. GitHub runner services are left out: the runner
# component adds and removes those.
audit_services() {
  systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
    awk '$1 !~ /^actions\.runner\./ && $1 ~ /\.(service|timer|socket|path)$/ { printf "services\t%s\t-\n", $1 }'
}

# Programs that run with their owner's rights (setuid or setgid), outside Docker and the GitHub runners'
# work folders (/home/runner).
audit_setuid() {
  find / -xdev \( -path /proc -o -path /sys -o -path /home/runner -o -path /var/lib/docker -o -path /snap \) -prune \
    -o -type f -perm /6000 -print 2>/dev/null | awk '{ printf "setuid\t%s\t-\n", $0 }'
}

# hostctl's own files and command links, by hash: only setup should change them.
audit_tools() {
  local file
  for file in /usr/local/bin/hostctl /usr/local/bin/ghrunner /usr/local/bin/portainerctl \
    /usr/local/bin/networkctl "${TOOLS_DIR}"/*/*.sh; do
    if [[ -f ${file} ]]; then printf 'tools\t%s\t%s\n' "${file}" "$(git_blob_sha "${file}" | cut -c1-16)"; fi
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
    audit_files wireguard /etc/wireguard/wg0.conf /etc/wireguard/hostctl.key "${CONFIG_DIR}/wireguard.conf" || true
    audit_ssh_settings || true
    audit_firewall || true
    audit_listening || true
    audit_files cron /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* \
      /etc/cron.monthly/* /var/spool/cron/crontabs/* || true
    audit_services || true
    audit_setuid || true
    audit_tools || true
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
  install -d -m 0755 "${STATE_DIR}"
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
    rm -f "${STATE_DIR}/audit-alerted"
    return
  fi
  {
    printf 'Audit %s: %s change(s) nobody accepted, e.g.\n' "$(date '+%Y-%m-%d %H:%M')" "${count}"
    head -n 5 <<<"${findings}" | sed 's/\t/ /g; s/^/  /'
    printf 'If you made them: sudo hostctl audit --accept. If not: see "If the VM is compromised" in the README.\n'
  } | set_attention audit
  [[ ${alert} == "yes" ]] || return 0
  digest="$(sha256sum <<<"${findings}" | cut -c1-16)"
  if [[ -f ${STATE_DIR}/audit-alerted ]]; then previous="$(<"${STATE_DIR}/audit-alerted")"; fi
  if [[ ${digest} != "${previous}" ]]; then
    send_alert "audit found ${count} unexpected change(s)" "$(head -n 10 <<<"${findings}" | sed 's/\t/ /g')" 1
    echo "${digest}" >"${STATE_DIR}/audit-alerted"
  fi
}

# Prints audit findings as a table.
audit_table() {
  { printf 'SECTION\tCHANGE\tITEM\n'; printf '%s\n' "$1"; } | print_table
}

# ---------------------------------------------------------------------------------------------
# Doctor checks every host gets
# ---------------------------------------------------------------------------------------------

DOCTOR_ROWS=()
DOCTOR_FAILED=0
DOCTOR_FIXABLE=0

# Records one check's result (PASS, WARN or FAIL) for the doctor table; any FAIL makes doctor exit 1.
# <fix> "fix" marks a problem that running setup again fixes, so "doctor --fix" knows to run it.
record() {
  DOCTOR_ROWS+=("$2"$'\t'"$1"$'\t'"$3")
  if [[ $1 == "FAIL" ]]; then DOCTOR_FAILED=1; fi
  if [[ $1 != "PASS" && ${4:-} == "fix" ]]; then DOCTOR_FIXABLE=1; fi
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

# Scheduled jobs: the weekly Docker clean-up (cron), the weekly update and the daily audit (timers).
check_scheduled_jobs() {
  local problems="" timer
  if [[ ! -x ${PRUNE_SCRIPT} ]]; then problems="${PRUNE_SCRIPT} missing or not executable"; fi
  if ! systemctl is-active --quiet cron 2>/dev/null; then problems="${problems:+${problems}; }cron isn't running"; fi
  for timer in hostctl-update hostctl-audit; do
    if ! systemctl is-active --quiet "${timer}.timer" 2>/dev/null; then
      problems="${problems:+${problems}; }${timer}.timer isn't on"
    elif systemctl is-failed --quiet "${timer}.service" 2>/dev/null; then
      problems="${problems:+${problems}; }${timer} failed last time (journalctl -u ${timer})"
    fi
  done
  if [[ -n ${problems} ]]; then
    record FAIL "Scheduled jobs" "${problems}" fix
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

# From "ufw status" on stdin, prints what is wrong with the rules, one per line: anything let in besides
# SSH and the components' ports, and an SSH port without a rate limit ("LIMIT"). <ssh ports> and
# <allowed> are space-separated lists ("9452", "9443/tcp 9001/tcp").
firewall_problems() {
  awk -v ssh_ports=" $1 " -v allowed=" ${2:-} " '
    NR <= 2 || /^To / || /^--/ || NF < 2 { next }
    {
      line = $0; sub(/ \(v6\)/, "", line); split(line, field, /  +/)
      target = field[1]; action = field[2]
      if (action !~ /^(ALLOW|LIMIT)/) next
      # ufw interface-scoped rules use a target like '9443/tcp on wg0'.
      # The component's dedicated check validates the interface and sources.
      base_target = target; sub(/ on .*/, "", base_target)
      port = base_target; sub(/\/.*/, "", port)
      if (port == "OpenSSH") port = "22"
      if (index(allowed, " " target " ") > 0 || index(allowed, " " base_target " ") > 0) next
      if (index(ssh_ports, " " port " ") == 0) { if (!(target in other)) { other[target] = 1; print "also lets in " target } }
      else if (action ~ /^ALLOW/ && !(target in unlimited)) { unlimited[target] = 1; print target " has no rate limit" }
    }'
}

# The ports sshd listens on (root: sshd itself; others: the config files).
ssh_ports() {
  sshd_auth_settings 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un
}

# Firewall: nothing but SSH (rate-limited) and the components' own ports should come in.
check_firewall() {
  local problems
  if ! firewall_on; then
    record FAIL "Firewall" "ufw off" fix
    return
  fi
  if [[ ${EUID} -ne 0 ]]; then
    record PASS "Firewall" "ufw on (run with sudo to check its rules)"
    return
  fi
  local -a ports
  mapfile -t ports < <(ssh_ports)
  problems="$(ufw status 2>/dev/null | firewall_problems "${ports[*]}" "$(call_hooks firewall_allowed | paste -sd' ' -)" |
    paste -sd, - | sed 's/,/, /g')"
  if [[ -n ${problems} ]]; then
    record WARN "Firewall" "${problems}" fix
  else
    record PASS "Firewall" "ufw on: SSH (rate-limited)$(call_hooks firewall_allowed | awk '{ printf ", %s", $0 }')"
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

# From a config stream on stdin, prints the settings the SSH check needs, as sshd would use them: the first
# value of each wins (every Port line counts), and Match blocks are skipped (they apply to some
# connections only).
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
      if (key == "port") { ports = ports " " field[2]; next }
      if (key == "denyusers") { for (i = 2; i in field; i++) deny = deny " " field[i]; next }
      if (key ~ /^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries)$/ && !(key in first)) first[key] = value
    }
    END {
      print "passwordauthentication " (("passwordauthentication" in first) ? first["passwordauthentication"] : "yes")
      print "kbdinteractiveauthentication " (("kbdinteractiveauthentication" in first) ? first["kbdinteractiveauthentication"] : "yes")
      print "permitrootlogin " (("permitrootlogin" in first) ? first["permitrootlogin"] : "prohibit-password")
      print "maxauthtries " (("maxauthtries" in first) ? first["maxauthtries"] : "6")
      if (deny != "") print "denyusers" deny
      n = split(ports == "" ? " 22" : ports, list, " ")
      for (i = 1; i <= n; i++) if (list[i] != "") print "port " list[i]
    }'
}

# Prints sshd's effective settings for the SSH check: root asks sshd itself (sshd -T), anyone else reads
# the config files. Fails when the files aren't all readable.
sshd_auth_settings() {
  local settings
  if [[ ${EUID} -eq 0 ]] && settings="$(sshd -T 2>/dev/null)"; then
    grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries|denyusers|port) ' <<<"${settings}"
    return
  fi
  sshd_config_stream /etc/ssh/sshd_config /etc/ssh | sshd_first_values
}

# From SSH settings ("<keyword> <value>" lines) on stdin, prints each problem as "<FAIL|WARN> <text>".
# Arguments: service accounts that must be barred from SSH (DenyUsers).
ssh_problems() {
  awk -v must_deny=" $* " '
    $1 == "port" { ports = ports " " $2; count++ }
    $1 == "denyusers" { for (i = 2; i <= NF; i++) denied[$i] = 1 }
    { value[$1] = $2 }
    END {
      if (value["passwordauthentication"] != "no" || value["kbdinteractiveauthentication"] != "no") print "FAIL password login is on"
      if (count > 1) print "WARN listening on ports" ports ": confirm the new one so the old one closes"
      else if (ports == " 22") print "WARN on port 22, which every scanner tries"
      if (value["permitrootlogin"] != "no") print "WARN root can log in (" value["permitrootlogin"] ")"
      n = split(must_deny, user, " ")
      for (i = 1; i <= n; i++) if (user[i] != "" && !(user[i] in denied)) print "WARN the " user[i] " user can log in over SSH"
      if (value["maxauthtries"] + 0 > 3) print "WARN " value["maxauthtries"] " tries per connection"
    }'
}

# SSH: keys only, off port 22, root and service accounts can't log in, few tries per connection.
check_ssh() {
  local settings problems worst detail
  local -a deny
  if ! settings="$(sshd_auth_settings)"; then
    if [[ ${EUID} -eq 0 ]]; then
      record WARN "SSH" "can't read the SSH settings (is openssh-server installed?)"
    else
      record WARN "SSH" "can't read every SSH config file: run with sudo"
    fi
    return
  fi
  mapfile -t deny < <(call_hooks ssh_deny_users)
  problems="$(ssh_problems "${deny[@]}" <<<"${settings}")"
  if [[ -z ${problems} ]]; then
    record PASS "SSH" "keys only, port$(awk '$1 == "port" { printf " %s", $2 }' <<<"${settings}"), root${deny[*]:+ and ${deny[*]}} can't log in"
    return
  fi
  worst="WARN"
  if grep -q '^FAIL' <<<"${problems}"; then worst="FAIL"; fi
  detail="$(cut -d' ' -f2- <<<"${problems}" | paste -sd';' - | sed 's/;/; /g')"
  record "${worst}" "SSH" "${detail}" fix
}

# Prints a kernel setting's current value.
current_kernel_value() {
  cat "/proc/sys/${1//.//}" 2>/dev/null
}

# Kernel network settings: the ones setup writes (KERNEL_SETTINGS) should be in force.
check_kernel_settings() {
  local setting key want have wrong=""
  for setting in "${KERNEL_SETTINGS[@]}"; do
    key="${setting%%=*}"
    want="${setting#*=}"
    have="$(current_kernel_value "${key}" || true)"
    # A setting this kernel doesn't have (IPv6 turned off) can't be wrong.
    if [[ -n ${have} && ${have} != "${want}" ]]; then wrong="${wrong:+${wrong}, }${key}=${have}"; fi
  done
  if [[ -n ${wrong} ]]; then
    record WARN "Kernel settings" "not hardened: ${wrong}" fix
  else
    record PASS "Kernel settings" "no redirects or source routing; kernel addresses hidden"
  fi
}

# Security updates: Ubuntu's daily unattended upgrades, on and scheduled.
check_security_updates() {
  if [[ "$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)" == "install ok installed" ]] &&
    grep -qs 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades &&
    systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
    record PASS "Security updates" "installed daily"
  else
    record WARN "Security updates" "daily unattended upgrades aren't on" fix
  fi
}

# Docker: published ports must bind to 127.0.0.1, because Docker's rules bypass the firewall.
check_docker_local() {
  local address
  address="$(jq -r '.ip // empty' /etc/docker/daemon.json 2>/dev/null || true)"
  if [[ ${address} == "127.0.0.1" ]]; then
    record PASS "Docker ports" "published on 127.0.0.1 only"
  else
    record FAIL "Docker ports" "published ports would be reachable from the internet (daemon.json ip: ${address:-unset})" fix
  fi
}

# Alerts: without them, problems only show when you log in (root only: the settings are root's).
check_alerts() {
  [[ ${EUID} -eq 0 ]] || return 0
  if [[ -n "$(pushover_settings)" ]]; then
    record PASS "Alerts" "Pushover"
  else
    record WARN "Alerts" "off: problems only show at SSH login and here" fix
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
    record WARN "Audit" "hasn't run yet: sudo hostctl audit"
    return
  fi
  IFS=$'\t' read -r when count <"${AUDIT_STATUS}"
  if ((count > 0)); then
    record FAIL "Audit" "${count} change(s) nobody accepted ($(when_was "${when}")): sudo hostctl audit"
  elif (($(date +%s) - when > 2 * 86400)); then
    record WARN "Audit" "last ran $(when_was "${when}"): is hostctl-audit.timer on?"
  else
    record PASS "Audit" "no unexpected changes ($(when_was "${when}"))"
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
    record WARN "Swap" "off with only ${memory} GB of memory" fix
  fi
}

# hostctl itself: a newer version on main may fix problems this machine has.
check_tools_version() {
  local latest blobs
  local -a components folders
  mapfile -t components < <(installed_components)
  mapfile -t folders < <(tool_folders "${components[@]}")
  latest="$(latest_commits 2>/dev/null | head -n 1 | cut -f1 || true)"
  if [[ -z ${latest} ]]; then
    record WARN "hostctl version" "couldn't reach GitHub to check"
    return
  fi
  blobs="$(blobs_at "${latest}" "${folders[@]}" 2>/dev/null || true)"
  if files_match "${TOOLS_DIR}" "${blobs}"; then
    record PASS "hostctl version" "$(installed_version), up to date"
  else
    record WARN "hostctl version" "$(installed_version) installed, newer on main: sudo hostctl self-update"
  fi
}
