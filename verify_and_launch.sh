#!/usr/bin/env bash
set -euo pipefail

DIST_APK="${HOME}/audit_apk_project/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"

echo "=== WERYFIKACJA PLIKÓW APK ==="
for f in "$DIST_APK" "$DOWNLOAD_APK"; do
  if [ -f "$f" ]; then
    echo "OK: $f ($(wc -c < "$f") bajtów, sha256: $(sha256sum "$f" | awk '{print $1}'))"
  else
    echo "BRAK: $f"
  fi
done

echo "=== INSTALACJA / URUCHOMIENIE ==="
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  adb install -r "$DIST_APK"
  adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1
elif command -v termux-open >/dev/null 2>&1 && [ -f "$DOWNLOAD_APK" ]; then
  termux-open "$DOWNLOAD_APK" || true
  echo "Wywołano instalator dla: $DOWNLOAD_APK"
fi
