#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
VERIFY_LOG="${INTERNAL_DIR}/final_verification_log.txt"
DAEMON_PID_FILE="${PROJECT_DIR}/state/daemon.pid"
PKG_NAME="com.oceansuite.audit"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
TOKEN_FILE="${HOME}/.gh_token"
EXPECTED_SHA="${EXPECTED_SHA:-ae8ddce3251d15fff40bd7fe0041ca36940e50da4ab5b6e1eda26f479ff6a66a}"

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

mkdir -p "$INTERNAL_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || {
    echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2
    exit 1
  }
done

DAEMON_PID="none"
if [ -f "$DAEMON_PID_FILE" ]; then
  cand_dpid="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$cand_dpid" ] && kill -0 "$cand_dpid" 2>/dev/null; then
    DAEMON_PID="$cand_dpid"
  fi
fi

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  ADB_STATE="device"
  APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$APP_PID" ] || APP_PID="none"
fi

cd "$PROJECT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add verify_final_state.sh for final state check"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi

HEAD_SHA="$(git rev-parse --short HEAD)"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

printf '[%s] VERIFY_FINAL_OK pkg=%s adb=%s daemon_pid=%s app_pid=%s head=%s sha256=%s\n' \
  "$TS" "$PKG_NAME" "$ADB_STATE" "$DAEMON_PID" "$APP_PID" "$HEAD_SHA" "$EXPECTED_SHA" >> "$VERIFY_LOG"

echo "VERIFY_FINAL_OK: pkg=${PKG_NAME} adb=${ADB_STATE} daemon_pid=${DAEMON_PID} app_pid=${APP_PID} head=${HEAD_SHA}"
