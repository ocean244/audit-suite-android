#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/full_stack_release.txt"
PENDING_PUSH_FILE="${INTERNAL_DIR}/pending_git_push.txt"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
DEFAULT_ADB_TARGET="192.168.1.157:42079"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
TOKEN_FILE="${HOME}/.gh_token"

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
[ -f "$INTERNAL_APK" ] || { echo "BLAD: Brak pliku $INTERNAL_APK" >&2; exit 1; }

NEW_SHA="$(sha256sum "$INTERNAL_APK" | awk '{print $1}')"
for copy in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  if [ -f "$copy" ]; then
    [ "$(sha256sum "$copy" | awk '{print $1}')" = "$NEW_SHA" ] || {
      echo "BLAD: Niezgodny SHA-256 w $copy" >&2
      exit 1
    }
  fi
done

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb shell am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
    adb install -r -t -d "$INTERNAL_APK" >/dev/null 2>&1 || true
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || true
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

cd "$PROJECT_DIR"
HEAD_SHA="$(git rev-parse --short HEAD)"
PUSH_STATUS="PENDING_DNS_OR_NETWORK"

if getent hosts github.com >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    if git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main >/dev/null 2>&1; then
      PUSH_STATUS="PUSHED_OK"
      rm -f "$PENDING_PUSH_FILE"
    else
      PUSH_STATUS="PUSH_FAILED_AUTH_OR_REMOTE"
    fi
  elif git push origin main >/dev/null 2>&1; then
    PUSH_STATUS="PUSHED_OK"
    rm -f "$PENDING_PUSH_FILE"
  else
    PUSH_STATUS="PUSH_SKIPPED_NO_TOKEN"
  fi
else
  printf 'HEAD=%s\nTIMESTAMP=%s\nREPO=https://github.com/%s/%s.git\n' \
    "$HEAD_SHA" "$(date '+%Y-%m-%d %H:%M:%S')" "$GH_OWNER" "$GH_REPO" > "$PENDING_PUSH_FILE"
fi

TS="$(date '+%Y-%m-%d %H:%M:%S')"

{
  printf 'TIMESTAMP=%s\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'DIST_APK=%s\n' "$DIST_APK"
  printf 'DOWNLOAD_APK=%s\n' "$DOWNLOAD_APK"
  printf 'INTERNAL_APK=%s\n' "$INTERNAL_APK"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  printf 'GIT_PUSH=%s\n' "$PUSH_STATUS"
} > "$STATUS_FILE"

{
  printf '=== FULL STACK RELEASE (%s) ===\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  printf 'GIT_PUSH=%s\n' "$PUSH_STATUS"
  ls -lh "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"
} > "$RELEASE_LOG"

echo "SYNC_INSTALL_DONE: pkg=${PKG_NAME} adb=${ADB_STATE} app_pid=${APP_PID} head=${HEAD_SHA} push=${PUSH_STATUS}"
