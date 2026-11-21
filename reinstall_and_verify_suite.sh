#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
FINAL_REPORT="${INTERNAL_DIR}/final_audit_report.txt"
DAEMON_PID_FILE="${PROJECT_DIR}/state/daemon.pid"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
DEFAULT_ADB_TARGET="192.168.1.157:42079"
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

for src in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  [ -f "$src" ] || { echo "BŁĄD: Brak pliku $src" >&2; exit 1; }
  actual_sha="$(sha256sum "$src" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || {
    echo "BŁĄD: Niezgodny SHA-256 dla $src ($actual_sha)" >&2
    exit 1
  }
done

cp -f "$DIST_APK" "$INTERNAL_APK"
cp -f "$DIST_APK" "$DOWNLOAD_APK"

DAEMON_PID="none"
if [ -f "$DAEMON_PID_FILE" ]; then
  cand_dpid="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$cand_dpid" ] && kill -0 "$cand_dpid" 2>/dev/null; then
    DAEMON_PID="$cand_dpid"
  fi
fi

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb install -r -t -d "$INTERNAL_APK" >/dev/null 2>&1
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
      adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

cd "$PROJECT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add reinstall_and_verify_suite.sh for internal APK reinstall and audit"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi

HEAD_SHA="$(git rev-parse --short HEAD)"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

{
  printf 'TIMESTAMP=%s\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$EXPECTED_SHA"
  printf 'DIST_APK=%s\n' "$DIST_APK"
  printf 'DOWNLOAD_APK=%s\n' "$DOWNLOAD_APK"
  printf 'INTERNAL_APK=%s\n' "$INTERNAL_APK"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$STATUS_FILE"

{
  printf '=== REINSTALL & VECTOR AUDIT (%s) ===\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$EXPECTED_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  ls -lh "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"
} > "$FINAL_REPORT"

echo "REINSTALL_AUDIT_OK: pkg=${PKG_NAME} adb=${ADB_STATE} daemon_pid=${DAEMON_PID} app_pid=${APP_PID} head=${HEAD_SHA}"
