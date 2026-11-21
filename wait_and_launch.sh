#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
TOKEN_FILE="${HOME}/.gh_token"
EXPECTED_SHA="f1bc6f679321e3bf5991600e0a37f90709286a8c4c642dfe10a28be6ea172d4b"

cd "$PROJECT_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2; exit 1; }
done

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add wait_and_launch.sh"
  if [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  elif [ -f "$TOKEN_FILE" ]; then
    SAVED_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    if [ -n "$SAVED_TOKEN" ]; then
      git push "https://ocean244:${SAVED_TOKEN}@github.com/ocean244/audit-suite-android.git" main || true
    fi
  fi
fi

INSTALLED=0
for _ in $(seq 1 30); do
  if pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
    INSTALLED=1
    break
  fi
  sleep 2
done

if [ "$INSTALLED" -eq 1 ]; then
  echo "Pakiet $PKG_NAME wykryty — uruchamiam $ACTIVITY_NAME..."
  am start -n "$ACTIVITY_NAME" 2>/dev/null || monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
else
  echo "Pakiet $PKG_NAME nadal nie jest zainstalowany — wywołuję instalator dla $DOWNLOAD_APK..."
  if command -v termux-open >/dev/null 2>&1; then
    termux-open "$DOWNLOAD_APK" || true
  fi
fi
