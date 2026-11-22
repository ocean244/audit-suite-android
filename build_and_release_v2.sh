#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
PKG_PATH="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit"
ENGINE_FILE="${PKG_PATH}/AuditEngine.kt"
MAIN_FILE="${PKG_PATH}/MainActivity.kt"
GRADLE_PROPS="${PROJECT_DIR}/gradle.properties"
LOCAL_PROPS="${PROJECT_DIR}/local.properties"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/full_stack_release.txt"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
DEFAULT_ADB_TARGET="192.168.1.157:42079"
NATIVE_AAPT2="/data/data/com.termux/files/usr/bin/aapt2"
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

mkdir -p "$PKG_PATH" "$(dirname "$DIST_APK")" "$INTERNAL_DIR"

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/android-sdk}}"
[ -d "$SDK_DIR" ] || { echo "BLAD: Brak katalogu Android SDK ($SDK_DIR)" >&2; exit 1; }
[ -x "$NATIVE_AAPT2" ] || { echo "BLAD: Brak natywnego aapt2 ($NATIVE_AAPT2)" >&2; exit 1; }
[ -f "$ENGINE_FILE" ] || { echo "BLAD: Brak pliku $ENGINE_FILE" >&2; exit 1; }
[ -f "$MAIN_FILE" ] || { echo "BLAD: Brak pliku $MAIN_FILE" >&2; exit 1; }

printf 'sdk.dir=%s\n' "$SDK_DIR" > "$LOCAL_PROPS"
touch "$GRADLE_PROPS"
python3 - "$GRADLE_PROPS" "$NATIVE_AAPT2" << 'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
aapt2 = sys.argv[2]
lines = [
    ln for ln in p.read_text(encoding="utf-8").splitlines(keepends=True)
    if not ln.startswith("android.aapt2FromMavenOverride=")
]
lines.append(f"android.aapt2FromMavenOverride={aapt2}\n")
p.write_text("".join(lines), encoding="utf-8")
PYEOF

cd "$PROJECT_DIR"
if [ -x "${PROJECT_DIR}/gradlew" ]; then
  "${PROJECT_DIR}/gradlew" assembleDebug --rerun-tasks --offline || "${PROJECT_DIR}/gradlew" assembleDebug --rerun-tasks
else
  gradle assembleDebug --rerun-tasks --offline || gradle assembleDebug --rerun-tasks
fi

BUILT_APK="${PROJECT_DIR}/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$BUILT_APK" ] || BUILT_APK="$(find "${PROJECT_DIR}/app/build/outputs/apk" -name '*.apk' -type f | head -n 1)"
[ -f "$BUILT_APK" ] || { echo "BLAD: Brak zbudowanego APK" >&2; exit 1; }

cp -f "$BUILT_APK" "$DIST_APK"
cp -f "$DIST_APK" "$INTERNAL_APK"
cp -f "$DIST_APK" "$DOWNLOAD_APK"

NEW_SHA="$(sha256sum "$DIST_APK" | awk '{print $1}')"
for copy in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  [ "$(sha256sum "$copy" | awk '{print $1}')" = "$NEW_SHA" ] || {
    echo "BLAD: Niezgodny SHA-256 w $copy" >&2
    exit 1
  }
done

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb shell am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
    adb uninstall "$PKG_NAME" >/dev/null 2>&1 || true
    adb install -r -t -d "$INTERNAL_APK" >/dev/null 2>&1 || true
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || true
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Upgrade Ocean Audit Suite v2.0 and generate release artifacts"
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
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'DIST_APK=%s\n' "$DIST_APK"
  printf 'DOWNLOAD_APK=%s\n' "$DOWNLOAD_APK"
  printf 'INTERNAL_APK=%s\n' "$INTERNAL_APK"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$STATUS_FILE"

{
  printf '=== FULL STACK RELEASE (%s) ===\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  ls -lh "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"
} > "$RELEASE_LOG"

echo "FULL_STACK_RELEASE_OK: pkg=${PKG_NAME} adb=${ADB_STATE} app_pid=${APP_PID} head=${HEAD_SHA} sha256=${NEW_SHA}"
