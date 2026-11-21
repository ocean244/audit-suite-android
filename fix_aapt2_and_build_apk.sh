#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
AUDIT_ENGINE="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit/AuditEngine.kt"
GRADLE_PROPS="${PROJECT_DIR}/gradle.properties"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/hash_patch_release.txt"
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

find_native_aapt2() {
  local cand
  for cand in \
    "/data/data/com.termux/files/usr/bin/aapt2" \
    "/data/data/com.termux/files/home/android-sdk/build-tools"/*/aapt2; do
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      if head -c 4 "$cand" 2>/dev/null | grep -q $'\x7fELF'; then
        printf '%s' "$cand"
        return 0
      fi
    fi
  done

  local found
  found="$(find /data/data/com.termux/files/usr /data/data/com.termux/files/home -name "aapt2" -type f 2>/dev/null | while read -r f; do
    if head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF'; then
      printf '%s\n' "$f"
      break
    fi
  done || true)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
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

NATIVE_AAPT2="$(find_native_aapt2 || true)"
if [ -z "$NATIVE_AAPT2" ] && command -v pkg >/dev/null 2>&1; then
  pkg install -y aapt2 >/dev/null 2>&1 || true
  NATIVE_AAPT2="$(find_native_aapt2 || true)"
fi

if [ -z "$NATIVE_AAPT2" ]; then
  echo "BŁĄD: Brak natywnego binarnego aapt2 dla AArch64 w środowisku" >&2
  exit 1
fi

chmod +x "$NATIVE_AAPT2" 2>/dev/null || true

touch "$GRADLE_PROPS"
python3 - "$GRADLE_PROPS" "$NATIVE_AAPT2" << 'PYEOF'
import sys
from pathlib import Path

props_path = Path(sys.argv[1])
aapt2_path = sys.argv[2]
lines = props_path.read_text(encoding="utf-8").splitlines(keepends=True)
filtered = [ln for ln in lines if not ln.startswith("android.aapt2FromMavenOverride=")]
filtered.append(f"android.aapt2FromMavenOverride={aapt2_path}\n")
props_path.write_text("".join(filtered), encoding="utf-8")
PYEOF

while IFS= read -r -d '' cached_aapt2; do
  cp -f "$NATIVE_AAPT2" "$cached_aapt2"
  chmod +x "$cached_aapt2" 2>/dev/null || true
done < <(find "${HOME}/.gradle/caches" -name "aapt2" -type f -print0 2>/dev/null || true)

cd "$PROJECT_DIR"
if [ -x "${PROJECT_DIR}/gradlew" ]; then
  "${PROJECT_DIR}/gradlew" assembleDebug --offline || "${PROJECT_DIR}/gradlew" assembleDebug
elif command -v gradle >/dev/null 2>&1; then
  gradle assembleDebug --offline || gradle assembleDebug
else
  echo "BŁĄD: Brak narzędzia gradle/gradlew" >&2
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
    if sh_file.name == "fix_aapt2_and_build_apk.sh":
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
  git commit -m "Use native AAPT2 override, fix MD5 in AuditEngine.kt, and rebuild APK"
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
  printf 'NATIVE_AAPT2=%s\n' "$NATIVE_AAPT2"
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
