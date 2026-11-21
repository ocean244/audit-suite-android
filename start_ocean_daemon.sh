#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_DIR="${PROJECT_DIR}/dist"
LOG_DIR="${PROJECT_DIR}/logs"
STATE_DIR="${PROJECT_DIR}/state"
DIST_APK="${DIST_DIR}/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
DAEMON_SCRIPT="${PROJECT_DIR}/ocean_suite_daemon.sh"
DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
DAEMON_LOG="${LOG_DIR}/daemon.log"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
EXPECTED_SHA="${EXPECTED_SHA:-107a7e58313c0ef4a3db4c02b6ec01db2a4e43ec2a09784ebee2aab1ecc89344}"
TOKEN_FILE="${HOME}/.gh_token"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

mkdir -p "$DIST_DIR" "$LOG_DIR" "$STATE_DIR"
touch "$DAEMON_LOG"

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || {
    echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2
    exit 1
  }
done

[ -x "$DAEMON_SCRIPT" ] || { echo "BŁĄD: Brak wykonywalnego $DAEMON_SCRIPT" >&2; exit 1; }

existing_pid=""
if [ -f "$DAEMON_PID_FILE" ]; then
  existing_pid="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
fi

if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
  echo "DAEMON_ALREADY_RUNNING: pid=${existing_pid}"
else
  nohup env POLL_INTERVAL="$POLL_INTERVAL" "$DAEMON_SCRIPT" >> "$DAEMON_LOG" 2>&1 < /dev/null &
  new_pid="$!"
  sleep 1
  kill -0 "$new_pid" 2>/dev/null || {
    echo "BŁĄD: Demon nie utrzymał procesu (pid=${new_pid})" >&2
    exit 1
  }
  printf '%s\n' "$new_pid" > "$DAEMON_PID_FILE"
  echo "DAEMON_STARTED: pid=${new_pid} interval=${POLL_INTERVAL}s"
fi

cd "$PROJECT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Start ocean_suite_daemon.sh in background with PID tracking"
  token="$(resolve_gh_token)"
  if [ -n "$token" ]; then
    git push "https://${GH_OWNER}:${token}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi
