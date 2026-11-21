#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
ADB_TARGET="${ADB_TARGET:-192.168.1.157:42079}"
TOKEN_FILE="${HOME}/.gh_token"
EXPECTED_SHA="f1bc6f679321e3bf5991600e0a37f90709286a8c4c642dfe10a28be6ea172d4b"

cd "$PROJECT_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2; exit 1; }
done

command -v adb >/dev/null 2>&1 || { echo "BŁĄD: Brak binarki adb w środowisku." >&2; exit 1; }

adb connect "$ADB_TARGET" >/dev/null 2>&1 || true
adb wait-for-device
adb install -r -t -d "$DIST_APK"

adb shell pm list packages | grep -qF "$PKG_NAME" || {
  echo "BŁĄD: Pakiet $PKG_NAME nie pojawił się po adb install." >&2
  exit 1
}

adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
  adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add adb_install_and_launch.sh for wireless ADB deployment"
  if [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  elif [ -f "$TOKEN_FILE" ]; then
    SAVED_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    if [ -n "$SAVED_TOKEN" ]; then
      git push "https://ocean244:${SAVED_TOKEN}@github.com/ocean244/audit-suite-android.git" main || true
    fi
  fi
fi

echo "SUKCES: Zainstalowano i uruchomiono $PKG_NAME ($ACTIVITY_NAME) na $ADB_TARGET."
