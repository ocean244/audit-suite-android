#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_DIR="${PROJECT_DIR}/dist"
LOG_DIR="${PROJECT_DIR}/logs"
STATE_DIR="${PROJECT_DIR}/state"
DIST_APK="${DIST_DIR}/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
START_SCRIPT="${PROJECT_DIR}/start_ocean_daemon.sh"
DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
DAEMON_LOG="${LOG_DIR}/daemon.log"
PKG_NAME="com.oceansuite.audit"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
EXPECTED_SHA="${EXPECTED_SHA:-ae8ddce3251d15fff40bd7fe0041ca36940e50da4ab5b6e1eda26f479ff6a66a}"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$DIST_DIR" "$LOG_DIR" "$STATE_DIR"
cd "$PROJECT_DIR"

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

[ -x "$START_SCRIPT" ] || { echo "BŁĄD: Brak wykonywalnego $START_SCRIPT" >&2; exit 1; }

"$START_SCRIPT"

[ -f "$DAEMON_PID_FILE" ] || { echo "BŁĄD: Brak pliku PID $DAEMON_PID_FILE" >&2; exit 1; }
DAEMON_PID="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
[ -n "$DAEMON_PID" ] || { echo "BŁĄD: Pusty plik $DAEMON_PID_FILE" >&2; exit 1; }
kill -0 "$DAEMON_PID" 2>/dev/null || {
  echo "BŁĄD: Proces demona PID=$DAEMON_PID nie jest aktywny" >&2
  exit 1
}

APP_PID=""
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add restart_and_verify_daemon.sh and refresh daemon PID"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi

echo "DAEMON_VERIFIED: daemon_pid=${DAEMON_PID} app_pid=${APP_PID:-unknown} head=$(git rev-parse --short HEAD)"
