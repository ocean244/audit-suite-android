#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
EXPECTED_SHA="${EXPECTED_SHA:-107a7e58313c0ef4a3db4c02b6ec01db2a4e43ec2a09784ebee2aab1ecc89344}"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2; exit 1; }
done

if command -v adb >/dev/null 2>&1; then
  if [ -n "${ADB_HOST_PORT:-}" ]; then
    adb connect "$ADB_HOST_PORT" >/dev/null 2>&1 || true
  fi
  if adb get-state >/dev/null 2>&1; then
    adb install -r "$DIST_APK" || true
  fi
fi

if pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
  echo "Pakiet $PKG_NAME zainstalowany — uruchamiam $ACTIVITY_NAME..."
  am start -n "$ACTIVITY_NAME" 2>/dev/null || monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
else
  echo "Pakiet $PKG_NAME nie jest jeszcze zainstalowany — otwieram instalator dla $DOWNLOAD_APK..."
  if command -v termux-open >/dev/null 2>&1; then
    termux-open "$DOWNLOAD_APK" || true
  fi
fi
