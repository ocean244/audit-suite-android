#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
TOKEN_FILE="${HOME}/.gh_token"
EXPECTED_SHA="${EXPECTED_SHA:-ae8ddce3251d15fff40bd7fe0041ca36940e50da4ab5b6e1eda26f479ff6a66a}"

cd "$PROJECT_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { echo "BŁĄD: Brak pliku $apk" >&2; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 dla $apk ($actual_sha)" >&2; exit 1; }
done

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add start_audit_app.sh"
  if [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  elif [ -f "$TOKEN_FILE" ]; then
    SAVED_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    if [ -n "$SAVED_TOKEN" ]; then
      git push "https://ocean244:${SAVED_TOKEN}@github.com/ocean244/audit-suite-android.git" main || true
    fi
  fi
fi

if pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
  echo "Pakiet $PKG_NAME zainstalowany — uruchamiam $ACTIVITY_NAME..."
  am start -n "$ACTIVITY_NAME" 2>/dev/null || monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
else
  echo "Pakiet $PKG_NAME oczekuje na zatwierdzenie instalacji — otwieram $DOWNLOAD_APK..."
  if command -v termux-open >/dev/null 2>&1; then
    termux-open "$DOWNLOAD_APK" || true
  fi
fi
