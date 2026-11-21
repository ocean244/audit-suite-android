#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
TOKEN_FILE="${HOME}/.gh_token"

cd "$PROJECT_DIR"

EXPECTED_SHA="f1bc6f679321e3bf5991600e0a37f90709286a8c4c642dfe10a28be6ea172d4b"
for target in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$target" ] || { echo "BŁĄD: Brak pliku $target" >&2; exit 1; }
  ACTUAL_SHA="$(sha256sum "$target" | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $target" >&2; exit 1; }
done

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add verify_and_launch.sh and finalize release pipeline"
  if [ -n "${GH_TOKEN:-}" ]; then
    git push origin main
  elif [ -f "$TOKEN_FILE" ]; then
    SAVED_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    if [ -n "$SAVED_TOKEN" ]; then
      git push "https://ocean244:${SAVED_TOKEN}@github.com/ocean244/audit-suite-android.git" main || true
    fi
  fi
fi

if pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
  echo "Pakiet $PKG_NAME jest już zainstalowany — uruchamiam..."
  am start -n "$ACTIVITY_NAME" || monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 || true
else
  echo "Pakiet $PKG_NAME nie jest jeszcze zainstalowany w systemie — otwieram instalator dla $DOWNLOAD_APK..."
  if command -v termux-open >/dev/null 2>&1; then
    termux-open "$DOWNLOAD_APK" || true
  fi
  echo "Po zatwierdzeniu instalacji w oknie Android uruchom ponownie ten skrypt, aby włączyć aplikację."
fi
