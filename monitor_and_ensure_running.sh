#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
ADB_TARGET="${ADB_TARGET:-192.168.1.157:42079}"
TOKEN_FILE="${HOME}/.gh_token"
EXPECTED_SHA="${EXPECTED_SHA:-107a7e58313c0ef4a3db4c02b6ec01db2a4e43ec2a09784ebee2aab1ecc89344}"

cd "$PROJECT_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2; exit 1; }
done

command -v adb >/dev/null 2>&1 || { echo "BŁĄD: Brak binarki adb w środowisku." >&2; exit 1; }

adb connect "$ADB_TARGET" >/dev/null 2>&1 || true
adb wait-for-device

if ! adb shell pm list packages | grep -qF "$PKG_NAME"; then
  adb install -r -t -d "$DIST_APK"
fi

APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$APP_PID" ]; then
  adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
    adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 1
  APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
fi

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add monitor_and_ensure_running.sh"
  if [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  elif [ -f "$TOKEN_FILE" ]; then
    SAVED_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    if [ -n "$SAVED_TOKEN" ]; then
      git push "https://ocean244:${SAVED_TOKEN}@github.com/ocean244/audit-suite-android.git" main || true
    fi
  fi
fi

echo "STATUS: pkg=${PKG_NAME} installed=yes pid=${APP_PID:-unknown} target=${ADB_TARGET}"
