#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
AUDIT_ENGINE="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit/AuditEngine.kt"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
REPORT_FILE="${INTERNAL_DIR}/reinstall_hash_report.txt"
DAEMON_PID_FILE="${PROJECT_DIR}/state/daemon.pid"
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

[ -f "$AUDIT_ENGINE" ] || { echo "BŁĄD: Brak pliku $AUDIT_ENGINE" >&2; exit 1; }
grep -q '32 -> "MD5"' "$AUDIT_ENGINE" || { echo "BŁĄD: Brak 32 -> \"MD5\" w AuditEngine.kt" >&2; exit 1; }
mkdir -p "$INTERNAL_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
done

APK_SHA="$(sha256sum "$INTERNAL_APK" | awk '{print $1}')"
for copy in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  c_sha="$(sha256sum "$copy" | awk '{print $1}')"
  [ "$c_sha" = "$APK_SHA" ] || {
    echo "BŁĄD: Niezgodny SHA-256 w kopii $copy" >&2
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
UNINSTALL_OUT="skipped"
INSTALL_OUT="skipped"

if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb shell am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
    UNINSTALL_OUT="$(adb uninstall "$PKG_NAME" 2>&1 || true)"
    INSTALL_OUT="$(adb install -r -t -d "$INTERNAL_APK" 2>&1 || true)"
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
      adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

cd "$PROJECT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add clean uninstall and reinstall script for MD5 APK fix"
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
  printf 'SHA256=%s\n' "$APK_SHA"
  printf 'DIST_APK=%s\n' "$DIST_APK"
  printf 'DOWNLOAD_APK=%s\n' "$DOWNLOAD_APK"
  printf 'INTERNAL_APK=%s\n' "$INTERNAL_APK"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$STATUS_FILE"

{
  printf '=== REINSTALL HASH REPORT (%s) ===\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$APK_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'UNINSTALL_OUT=%s\n' "$UNINSTALL_OUT"
  printf 'INSTALL_OUT=%s\n' "$INSTALL_OUT"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$REPORT_FILE"

echo "REINSTALL_HASH_OK: pkg=${PKG_NAME} adb=${ADB_STATE} app_pid=${APP_PID} head=${HEAD_SHA} sha256=${APK_SHA}"
