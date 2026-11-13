#!/usr/bin/env bash
# Source: https://github.com/vbcloud/sysreport
# Author: https://github.com/vbcloud
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"
THRESHOLD=80
FORMAT="table"
OUTPUT=""
EXIT_CODE=0
WARNINGS=()

# colors (disabled if not a tty or if NO_COLOR is set)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; BLD=""; RST=""
fi

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
# Any unexpected failure exits 2 and names the line, never 1 (1 means "threshold exceeded").
trap 'die "unexpected failure at line $LINENO (exit $?)"' ERR

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION - report on this host's health

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -f, --format FORMAT     Output format: table|json  (default: table)
  -o, --output FILE       Write to FILE instead of stdout
  -t, --threshold N       Warn above N percent for disk, memory, inodes, 0-100  (default: 80)
  -h, --help              This message

Exit codes: 0 all under threshold, 1 a check exceeded it, 2 usage error
USAGE
}

# Called as: need_value "$@"  -- fails with exit 2 if the option has no value after it.
need_value() { [[ $# -ge 2 ]] || die "$1 needs a value"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--format)    need_value "$@"; FORMAT=$2; shift 2 ;;
      -o|--output)    need_value "$@"; OUTPUT=$2; shift 2 ;;
      -t|--threshold) need_value "$@"; THRESHOLD=$2; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage >&2; die "unknown option: $1" ;;
    esac
  done
  [[ $FORMAT == table || $FORMAT == json ]] || die "format must be table or json, got: $FORMAT"
  [[ $THRESHOLD =~ ^[0-9]+$ ]] || die "threshold must be a whole number, got: $THRESHOLD"
  (( 10#$THRESHOLD <= 100 )) || die "threshold must be between 0 and 100, got: $THRESHOLD"
}

# check_threshold NAME VALUE -- records a warning and sets EXIT_CODE=1 if VALUE > THRESHOLD
check_threshold() {
  if awk -v v="$2" -v t="$THRESHOLD" 'BEGIN {exit !(v > t)}'; then
    WARNINGS+=("$1 at ${2}% (threshold ${THRESHOLD}%)")
    EXIT_CODE=1
  fi
}

collect_host() {
  HOST_NAME=$(hostname)
  KERNEL=$(uname -r)
  DISTRO=$(awk -F= '$1 == "PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
  DISTRO=${DISTRO:-unknown}
  UPTIME=$(uptime -p)
  NOW_UTC=$(date -u +%FT%TZ)
}

collect_cpu() {
  CORES=$(nproc)
  read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
  LOAD_PER_CORE=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN {printf "%.2f", l/c}')
}

collect_memory() {
  local mt ma st sf
  read -r mt ma st sf < <(awk '
    /^MemTotal:/     {t=$2}
    /^MemAvailable:/ {a=$2}
    /^SwapTotal:/    {st=$2}
    /^SwapFree:/     {sf=$2}
    END {print t, a, st, sf}' /proc/meminfo)
  MEM_TOTAL_GB=$(awk -v v="$mt" 'BEGIN {printf "%.1f", v/1048576}')
  MEM_USED_GB=$(awk -v t="$mt" -v a="$ma" 'BEGIN {printf "%.1f", (t-a)/1048576}')
  MEM_AVAIL_GB=$(awk -v v="$ma" 'BEGIN {printf "%.1f", v/1048576}')
  SWAP_USED_GB=$(awk -v t="$st" -v f="$sf" 'BEGIN {printf "%.1f", (t-f)/1048576}')
  MEM_PCT=$(awk -v t="$mt" -v a="$ma" 'BEGIN {printf "%.1f", (t-a)*100/t}')
  check_threshold "memory" "$MEM_PCT"
}

collect_disk() {
  DISK_ROWS=()
  INODE_ROWS=()
  local size used pct mount
  local excl=(--exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=squashfs --exclude-type=overlay --exclude-type=efivarfs)

  while read -r _ size used _ pct mount; do
    pct=${pct%\%}
    DISK_ROWS+=("$mount|$size|$used|$pct")
    check_threshold "disk $mount" "$pct"
  done < <(df -PH "${excl[@]}" | tail -n +2)

  while read -r _ _ _ _ pct mount; do
    pct=${pct%\%}
    [[ $pct == "-" ]] && continue
    INODE_ROWS+=("$mount|$pct")
    check_threshold "inodes $mount" "$pct"
  done < <(df -Pi "${excl[@]}" | tail -n +2)
}

collect_procs() {
  PROC_TOTAL=$(ps -e --no-headers | wc -l)
  ZOMBIES=$(ps -eo stat --no-headers | awk '/^Z/ {n++} END {print n+0}')
  TOP_CPU=()
  TOP_MEM=()
  local pid cpu mem comm
  while read -r pid cpu mem comm; do
    TOP_CPU+=("$pid|$cpu|$mem|$comm")
  done < <(ps -eo pid,%cpu,%mem,comm --no-headers --sort=-%cpu | awk '$4 != "ps" && c < 5 {print; c++}')
  while read -r pid cpu mem comm; do
    TOP_MEM+=("$pid|$cpu|$mem|$comm")
  done < <(ps -eo pid,%cpu,%mem,comm --no-headers --sort=-%mem | awk '$4 != "ps" && c < 5 {print; c++}')
}

collect_net() {
  LISTENERS=()
  if ! command -v ss >/dev/null 2>&1; then
    log "WARN: ss not found, skipping network section"
    return 0
  fi
  local row
  while IFS= read -r row; do
    LISTENERS+=("$row")
  done < <(ss -H -tlnp 2>/dev/null | awk '{p="-"; if (match($0, /users:\(\("[^"]+"/)) p=substr($0, RSTART+9, RLENGTH-10); print $4 "|" p}')
}

collect_systemd() {
  FAILED_UNITS=()
  if ! command -v systemctl >/dev/null 2>&1; then
    log "WARN: systemctl not found, skipping systemd section"
    return 0
  fi
  local unit
  while read -r unit _; do
    [[ -n $unit ]] && FAILED_UNITS+=("$unit")
  done < <(systemctl --failed --no-legend --plain 2>/dev/null || true)
  if (( ${#FAILED_UNITS[@]} > 0 )); then
    WARNINGS+=("${#FAILED_UNITS[@]} failed systemd unit(s)")
    EXIT_CODE=1
  fi
}

collect_logins() {
  LOGINS=()
  local line
  while IFS= read -r line; do
    LOGINS+=("$line")
  done < <(who)
}

section() { printf '\n%s%s%s\n' "$BLD" "$1" "$RST"; }

# pct_color VALUE -- prints red if VALUE is over the threshold, green if not
pct_color() {
  if awk -v v="$1" -v t="$THRESHOLD" 'BEGIN {exit !(v > t)}'; then
    printf '%s' "$RED"
  else
    printf '%s' "$GRN"
  fi
}

render_table() {
  local row mount size used pct pid cpu mem comm addr proc lc zc
  printf '%ssysreport %s%s  %s\n' "$BLD" "$VERSION" "$RST" "$NOW_UTC"

  section "Host"
  printf '  %-15s %s\n' "Hostname:" "$HOST_NAME"
  printf '  %-15s %s\n' "Kernel:" "$KERNEL"
  printf '  %-15s %s\n' "Distro:" "$DISTRO"
  printf '  %-15s %s\n' "Uptime:" "$UPTIME"

  section "CPU"
  lc=$GRN
  if awk -v v="$LOAD_PER_CORE" 'BEGIN {exit !(v >= 1)}'; then lc=$YEL; fi
  printf '  %-15s %s\n' "Cores:" "$CORES"
  printf '  %-15s %s / %s / %s\n' "Load (1/5/15):" "$LOAD1" "$LOAD5" "$LOAD15"
  printf '  %-15s %s%s%s\n' "Load per core:" "$lc" "$LOAD_PER_CORE" "$RST"

  section "Memory"
  printf '  %-15s %s GB\n' "Total:" "$MEM_TOTAL_GB"
  printf '  %-15s %s GB\n' "Used:" "$MEM_USED_GB"
  printf '  %-15s %s GB\n' "Available:" "$MEM_AVAIL_GB"
  printf '  %-15s %s GB\n' "Swap used:" "$SWAP_USED_GB"
  printf '  %-15s %s%s%%%s\n' "Used percent:" "$(pct_color "$MEM_PCT")" "$MEM_PCT" "$RST"

  section "Disk"
  printf '  %-24s %7s %7s %6s\n' "Mount" "Size" "Used" "Use%"
  for row in "${DISK_ROWS[@]}"; do
    IFS='|' read -r mount size used pct <<<"$row"
    printf '  %-24s %7s %7s %s%5s%%%s\n' "$mount" "$size" "$used" "$(pct_color "$pct")" "$pct" "$RST"
  done

  section "Inodes"
  printf '  %-24s %6s\n' "Mount" "Use%"
  for row in "${INODE_ROWS[@]}"; do
    IFS='|' read -r mount pct <<<"$row"
    printf '  %-24s %s%5s%%%s\n' "$mount" "$(pct_color "$pct")" "$pct" "$RST"
  done

  section "Processes"
  zc=$GRN
  if (( ZOMBIES > 0 )); then zc=$YEL; fi
  printf '  %-15s %s\n' "Total:" "$PROC_TOTAL"
  printf '  %-15s %s%s%s\n' "Zombies:" "$zc" "$ZOMBIES" "$RST"
  printf '\n  Top 5 by CPU\n  %-8s %6s %6s  %s\n' "PID" "CPU%" "MEM%" "COMMAND"
  for row in "${TOP_CPU[@]}"; do
    IFS='|' read -r pid cpu mem comm <<<"$row"
    printf '  %-8s %6s %6s  %s\n' "$pid" "$cpu" "$mem" "$comm"
  done
  printf '\n  Top 5 by memory\n  %-8s %6s %6s  %s\n' "PID" "CPU%" "MEM%" "COMMAND"
  for row in "${TOP_MEM[@]}"; do
    IFS='|' read -r pid cpu mem comm <<<"$row"
    printf '  %-8s %6s %6s  %s\n' "$pid" "$cpu" "$mem" "$comm"
  done

  section "Listening TCP ports"
  if (( ${#LISTENERS[@]} == 0 )); then printf '  none\n'; fi
  for row in "${LISTENERS[@]}"; do
    IFS='|' read -r addr proc <<<"$row"
    printf '  %-28s %s\n' "$addr" "$proc"
  done

  section "Failed systemd units"
  if (( ${#FAILED_UNITS[@]} == 0 )); then printf '  none\n'; fi
  for row in "${FAILED_UNITS[@]}"; do
    printf '  %s%s%s\n' "$RED" "$row" "$RST"
  done

  section "Logged-in users"
  if (( ${#LOGINS[@]} == 0 )); then printf '  none\n'; fi
  for row in "${LOGINS[@]}"; do
    printf '  %s\n' "$row"
  done

  section "Result"
  if (( ${#WARNINGS[@]} == 0 )); then
    printf '  %sAll checks under threshold (%s%%)%s\n' "$GRN" "$THRESHOLD" "$RST"
  else
    for row in "${WARNINGS[@]}"; do
      printf '  %sWARN%s %s\n' "$RED" "$RST" "$row"
    done
  fi
}

# rows_json ARRAYNAME JQ_FILTER -- turns an array of "a|b|c" strings into a JSON array
rows_json() {
  local -n _rows=$1
  if (( ${#_rows[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${_rows[@]}" | jq -R "$2" | jq -s .
}

render_json() {
  local disks inodes top_cpu top_mem listeners failed logins warns
  disks=$(rows_json DISK_ROWS 'split("|") | {mount: .[0], size: .[1], used: .[2], used_pct: (.[3] | tonumber)}')
  inodes=$(rows_json INODE_ROWS 'split("|") | {mount: .[0], used_pct: (.[1] | tonumber)}')
  top_cpu=$(rows_json TOP_CPU 'split("|") | {pid: (.[0] | tonumber), cpu_pct: (.[1] | tonumber), mem_pct: (.[2] | tonumber), command: .[3]}')
  top_mem=$(rows_json TOP_MEM 'split("|") | {pid: (.[0] | tonumber), cpu_pct: (.[1] | tonumber), mem_pct: (.[2] | tonumber), command: .[3]}')
  listeners=$(rows_json LISTENERS 'split("|") | {address: .[0], process: .[1]}')
  failed=$(rows_json FAILED_UNITS '.')
  logins=$(rows_json LOGINS '.')
  warns=$(rows_json WARNINGS '.')

  jq -n \
    --arg version "$VERSION" \
    --arg timestamp "$NOW_UTC" \
    --arg host "$HOST_NAME" \
    --arg kernel "$KERNEL" \
    --arg distro "$DISTRO" \
    --arg uptime "$UPTIME" \
    --argjson threshold "$THRESHOLD" \
    --argjson exit_code "$EXIT_CODE" \
    --argjson cores "$CORES" \
    --argjson load1 "$LOAD1" \
    --argjson load5 "$LOAD5" \
    --argjson load15 "$LOAD15" \
    --argjson load_per_core "$LOAD_PER_CORE" \
    --argjson mem_total "$MEM_TOTAL_GB" \
    --argjson mem_used "$MEM_USED_GB" \
    --argjson mem_avail "$MEM_AVAIL_GB" \
    --argjson swap_used "$SWAP_USED_GB" \
    --argjson mem_pct "$MEM_PCT" \
    --argjson proc_total "$PROC_TOTAL" \
    --argjson zombies "$ZOMBIES" \
    --argjson disks "$disks" \
    --argjson inodes "$inodes" \
    --argjson top_cpu "$top_cpu" \
    --argjson top_mem "$top_mem" \
    --argjson listeners "$listeners" \
    --argjson failed "$failed" \
    --argjson logins "$logins" \
    --argjson warns "$warns" \
    '{
       version:    $version,
       timestamp:  $timestamp,
       threshold:  $threshold,
       exit_code:  $exit_code,
       warnings:   $warns,
       host:       {name: $host, kernel: $kernel, distro: $distro, uptime: $uptime},
       cpu:        {cores: $cores, load1: $load1, load5: $load5, load15: $load15, load_per_core: $load_per_core},
       memory:     {total_gb: $mem_total, used_gb: $mem_used, available_gb: $mem_avail, swap_used_gb: $swap_used, used_pct: $mem_pct},
       disks:      $disks,
       inodes:     $inodes,
       processes:  {total: $proc_total, zombies: $zombies, top_cpu: $top_cpu, top_mem: $top_mem},
       listeners:  $listeners,
       failed_units: $failed,
       logins:     $logins
     }'
}

render() {
  if [[ $FORMAT == json ]]; then render_json; else render_table; fi
}

main() {
  parse_args "$@"
  if [[ $FORMAT == json ]]; then need jq; fi
  for cmd in awk df ps who uptime nproc hostname uname date tail wc; do need "$cmd"; done
  collect_host; collect_cpu; collect_memory; collect_disk
  collect_procs; collect_net; collect_systemd; collect_logins
  if [[ -n $OUTPUT ]]; then
    RED=""; YEL=""; GRN=""; BLD=""; RST=""
    : 2>/dev/null > "$OUTPUT" || die "cannot write to $OUTPUT"
    render > "$OUTPUT"
    log "wrote $OUTPUT"
  else
    render
  fi
  exit "$EXIT_CODE"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
