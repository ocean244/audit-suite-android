#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
EXPECTED_SHA="f1bc6f679321e3bf5991600e0a37f90709286a8c4c642dfe10a28be6ea172d4b"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($sha)" >&2; exit 1; }
done

if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  adb install -r "$DIST_APK" || true
elif command -v pm >/dev/null 2>&1; then
  pm install -r "$DOWNLOAD_APK" 2>/dev/null || true
fi

if pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
  echo "Pakiet $PKG_NAME zainstalowany. Uruchamiam $ACTIVITY_NAME..."
  am start -n "$ACTIVITY_NAME" 2>/dev/null || monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
else
  echo "Pakiet $PKG_NAME oczekuje na instalację z $DOWNLOAD_APK — wywołuję instalator Android..."
  if command -v termux-open >/dev/null 2>&1; then
    termux-open "$DOWNLOAD_APK" || true
  fi
fi
