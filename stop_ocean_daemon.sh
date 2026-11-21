#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
STATE_DIR="${PROJECT_DIR}/state"
LOG_DIR="${PROJECT_DIR}/logs"
DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
DAEMON_LOG="${LOG_DIR}/daemon.log"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$STATE_DIR" "$LOG_DIR"

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

if [ -f "$DAEMON_PID_FILE" ]; then
  DPID="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
    kill "$DPID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      if ! kill -0 "$DPID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$DPID" 2>/dev/null; then
      kill -9 "$DPID" 2>/dev/null || true
    fi
    printf '[%s] DAEMON_STOPPED: pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DPID" | tee -a "$DAEMON_LOG"
  else
    echo "DAEMON_NOT_RUNNING: stale_pid=${DPID:-none}"
  fi
  rm -f "$DAEMON_PID_FILE"
else
  echo "DAEMON_NOT_RUNNING: brak pliku $DAEMON_PID_FILE"
fi

cd "$PROJECT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add stop_ocean_daemon.sh for controlled background daemon shutdown"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi
