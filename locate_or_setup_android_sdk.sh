#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
AUDIT_ENGINE="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit/AuditEngine.kt"
LOCAL_PROPS="${PROJECT_DIR}/local.properties"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/hash_patch_release.txt"
SDK_REPORT="${INTERNAL_DIR}/sdk_env_report.txt"
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

find_existing_sdk() {
  local d
  for d in \
    "${ANDROID_HOME:-}" \
    "${ANDROID_SDK_ROOT:-}" \
    "${HOME}/android-sdk" \
    "${HOME}/Android/Sdk" \
    "/data/data/com.termux/files/usr/opt/android-sdk" \
    "/data/data/com.termux/files/usr/lib/android-sdk" \
    "/sdcard/android-sdk" \
    "/sdcard/Android/Sdk"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      if [ -d "${d}/platforms" ] || find "$d" -maxdepth 4 -name "android.jar" 2>/dev/null | head -n 1 | grep -q .; then
        printf '%s' "$d"
        return 0
      fi
    fi
  done

  local jar
  jar="$(find /data/data/com.termux/files "${HOME}" -maxdepth 5 -name "android.jar" 2>/dev/null | head -n 1 || true)"
  if [ -n "$jar" ]; then
    local cur
    cur="$(dirname "$jar")"
    while [ "$cur" != "/" ] && [ "$cur" != "." ]; do
      if [ "$(basename "$cur")" = "platforms" ]; then
        dirname "$cur"
        return 0
      fi
      cur="$(dirname "$cur")"
    done
  fi
  return 1
}

[ -f "$AUDIT_ENGINE" ] || { echo "BŁĄD: Brak pliku $AUDIT_ENGINE" >&2; exit 1; }
mkdir -p "$(dirname "$DIST_APK")" "$INTERNAL_DIR"

python3 - "$AUDIT_ENGINE" << 'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
updated = src.replace('32 -> "MD-5"', '32 -> "MD5"').replace('"MD-5"', '"MD5"')
if updated != src:
    path.write_text(updated, encoding="utf-8")
PYEOF

SDK_DIR="$(find_existing_sdk || true)"

if [ -z "$SDK_DIR" ] && command -v unzip >/dev/null 2>&1 && (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1); then
  SDK_TARGET="${HOME}/android-sdk"
  CMDLINE_TMP="${HOME}/cmdline_tools_dl.zip"
  mkdir -p "${SDK_TARGET}/cmdline-tools"
  DL_OK=0
  for url in \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
    "https://dl.google.com/android/repository/commandlinetools-linux-10406996_latest.zip"; do
    if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 -o "$CMDLINE_TMP" "$url"; then
      DL_OK=1
      break
    elif command -v wget >/dev/null 2>&1 && wget -q -T 60 -O "$CMDLINE_TMP" "$url"; then
      DL_OK=1
      break
    fi
  done

  if [ "$DL_OK" -eq 1 ] && [ -s "$CMDLINE_TMP" ]; then
    unzip -q -o "$CMDLINE_TMP" -d "${SDK_TARGET}/cmdline-tools" || true
    if [ -d "${SDK_TARGET}/cmdline-tools/cmdline-tools" ] && [ ! -d "${SDK_TARGET}/cmdline-tools/latest" ]; then
      mv "${SDK_TARGET}/cmdline-tools/cmdline-tools" "${SDK_TARGET}/cmdline-tools/latest"
    fi
    rm -f "$CMDLINE_TMP"
    SDKMANAGER="${SDK_TARGET}/cmdline-tools/latest/bin/sdkmanager"
    if [ -x "$SDKMANAGER" ]; then
      yes | "$SDKMANAGER" --sdk_root="$SDK_TARGET" "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/dev/null 2>&1 || true
    fi
  else
    rm -f "$CMDLINE_TMP"
  fi

  SDK_DIR="$(find_existing_sdk || true)"
fi

if [ -z "$SDK_DIR" ]; then
  {
    printf '=== ANDROID SDK ENV REPORT (%s) ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'ARCH=%s\n' "$(uname -m)"
    printf 'JAVA=%s\n' "$(command -v java || echo missing)"
    printf 'GRADLE=%s\n' "$(command -v gradle || echo missing)"
    printf 'ANDROID_HOME=%s\n' "${ANDROID_HOME:-unset}"
    printf 'LOCAL_PROPS_EXISTS=%s\n' "$([ -f "$LOCAL_PROPS" ] && echo yes || echo no)"
    ls -la "${HOME}" /data/data/com.termux/files/usr/opt 2>/dev/null || true
  } > "$SDK_REPORT"
  echo "SDK_MISSING: Brak zainstalowanego Android SDK (szczegóły w /sdcard/OceanAuditSuite/sdk_env_report.txt)" >&2
  exit 1
fi

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
ESCAPED_SDK="$(printf '%s' "$SDK_DIR" | sed 's/\\/\\\\/g; s/:/\\:/g')"
printf 'sdk.dir=%s\n' "$ESCAPED_SDK" > "$LOCAL_PROPS"

cd "$PROJECT_DIR"
if [ -x "${PROJECT_DIR}/gradlew" ]; then
  "${PROJECT_DIR}/gradlew" assembleDebug --offline || "${PROJECT_DIR}/gradlew" assembleDebug
elif command -v gradle >/dev/null 2>&1; then
  gradle assembleDebug --offline || gradle assembleDebug
else
  echo "BŁĄD: Brak gradle/gradlew" >&2
  exit 1
fi

BUILT_APK=""
for cand in \
  "${PROJECT_DIR}/app/build/outputs/apk/debug/app-debug.apk" \
  "${PROJECT_DIR}/build/outputs/apk/debug/app-debug.apk"; do
  if [ -f "$cand" ]; then
    BUILT_APK="$cand"
    break
  fi
done

if [ -z "$BUILT_APK" ]; then
  BUILT_APK="$(find "${PROJECT_DIR}/app/build/outputs/apk" -name '*.apk' -type f 2>/dev/null | head -n 1 || true)"
fi

[ -n "$BUILT_APK" ] && [ -f "$BUILT_APK" ] || {
  echo "BŁĄD: Nie znaleziono zbudowanego pliku APK" >&2
  exit 1
}

cp -f "$BUILT_APK" "$DIST_APK"
cp -f "$DIST_APK" "$INTERNAL_APK"
cp -f "$DIST_APK" "$DOWNLOAD_APK"

NEW_SHA="$(sha256sum "$DIST_APK" | awk '{print $1}')"
for copy in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  c_sha="$(sha256sum "$copy" | awk '{print $1}')"
  [ "$c_sha" = "$NEW_SHA" ] || {
    echo "BŁĄD: Niezgodny SHA-256 w kopii $copy" >&2
    exit 1
  }
done

python3 - "$PROJECT_DIR" "$NEW_SHA" << 'PYEOF'
import sys
from pathlib import Path

proj_dir = Path(sys.argv[1])
new_sha = sys.argv[2]

for sh_file in proj_dir.glob("*.sh"):
    if sh_file.name == "locate_or_setup_android_sdk.sh":
        continue
    text = sh_file.read_text(encoding="utf-8")
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("EXPECTED_SHA="):
            lines.append(f'EXPECTED_SHA="${{EXPECTED_SHA:-{new_sha}}}"\n')
        else:
            lines.append(line)
    sh_file.write_text("".join(lines), encoding="utf-8")
PYEOF

DAEMON_PID="none"
if [ -f "$DAEMON_PID_FILE" ]; then
  cand_dpid="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$cand_dpid" ] && kill -0 "$cand_dpid" 2>/dev/null; then
    DAEMON_PID="$cand_dpid"
  fi
fi

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb install -r -t -d "$INTERNAL_APK" >/dev/null 2>&1 || true
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
      adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Configure Android SDK, fix MD5 in AuditEngine.kt, and rebuild APK"
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
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$STATUS_FILE"

{
  printf '=== HASH PATCH & RELEASE (%s) ===\n' "$TS"
  printf 'SDK_DIR=%s\n' "$SDK_DIR"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  grep -nE '32 ->|"MD5"|MessageDigest\.getInstance' "$AUDIT_ENGINE" || true
  ls -lh "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"
} > "$RELEASE_LOG"

echo "HASH_PATCH_RELEASE_OK: pkg=${PKG_NAME} adb=${ADB_STATE} daemon_pid=${DAEMON_PID} app_pid=${APP_PID} head=${HEAD_SHA} sha256=${NEW_SHA}"
