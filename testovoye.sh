#!/usr/bin/env bash
# /usr/local/bin/monitor_test.sh

set -uo pipefail

PROCESS_NAME="test"
MONITOR_URL="https://test.com/monitoring/test/api"

LOG_FILE="/var/log/monitoring.log"
STATE_DIR="/var/lib/monitoring_test"
LAST_PID_FILE="${STATE_DIR}/last_pid"

CURL_BIN="$(command -v curl || true)"
PGREP_BIN="$(command -v pgrep || true)"
DATE_BIN="$(command -v date)"
ECHO_BIN="$(command -v echo)"

if [[ -z "$CURL_BIN" || -z "$PGREP_BIN" || -z "$DATE_BIN" || -z "$ECHO_BIN" ]]; then
  >&2 echo "Required tools missing (curl, pgrep, date). Aborting."
  exit 2
fi
mkdir -p "$STATE_DIR"

touch "$LOG_FILE"
chmod 0644 "$LOG_FILE" || true

timestamp() {
  "$DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

current_pid="$($PGREP_BIN -x "$PROCESS_NAME" | head -n1 || true)"

if [[ -z "$current_pid" ]]; then
  exit 0
fi

last_pid=""
if [[ -f "$LAST_PID_FILE" ]]; then
  last_pid="$(<"$LAST_PID_FILE")" || last_pid=""
fi

if [[ -n "$last_pid" && "$last_pid" != "$current_pid" ]]; then
  log "Process '${PROCESS_NAME}' restarted: old_pid=${last_pid} new_pid=${current_pid}"
fi

printf '%s' "$current_pid" > "$LAST_PID_FILE"

cmdline=""
if [[ -r "/proc/$current_pid/cmdline" ]]; then
  cmdline="$(tr '\0' ' ' < "/proc/$current_pid/cmdline" | sed -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
else
  cmdline="[unknown]"
fi

start_time=""
if [[ -r "/proc/$current_pid/stat" ]]; then
  if [[ -r "/proc/$current_pid/etimes" ]]; then
    etimes="$(<"/proc/$current_pid/etimes")"
    start_time="$(date -u -d "@$(( $(date +%s) - etimes ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")"
  fi
fi

payload=$(cat <<EOF
{
  "pid": "$current_pid",
  "cmdline": "$(printf '%s' "$cmdline" | sed 's/"/\\"/g')",
  "start_time": "${start_time:-unknown}"
}
EOF
)

http_code="$("$CURL_BIN" -sS -m 10 -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$MONITOR_URL" 2>/dev/null || echo "000")"

if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
  exit 0
else
  if [[ "$http_code" == "000" ]]; then
    log "Monitoring server unreachable for process '${PROCESS_NAME}' (pid=${current_pid}): curl error / timeout"
  else
    log "Monitoring server returned HTTP ${http_code} for process '${PROCESS_NAME}' (pid=${current_pid})"
  fi
  exit 1
fi
