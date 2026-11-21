#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
DIST_DIR="${PROJECT_DIR}/dist"
LOG_DIR="${PROJECT_DIR}/logs"
STATE_DIR="${PROJECT_DIR}/state"
DIST_APK="${DIST_DIR}/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
DEFAULT_ADB_TARGET="192.168.1.157:42079"
EXPECTED_SHA="${EXPECTED_SHA:-ae8ddce3251d15fff40bd7fe0041ca36940e50da4ab5b6e1eda26f479ff6a66a}"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$DIST_DIR" "$LOG_DIR" "$STATE_DIR"
RUN_LOG="${LOG_DIR}/last_run.log"
PKG_DUMP="${STATE_DIR}/package_dump.txt"

log_msg() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$RUN_LOG"
}

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

cd "$PROJECT_DIR"

for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
  [ -f "$apk" ] || { log_msg "BŁĄD: Brak pliku $apk"; exit 1; }
  actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
  [ "$actual_sha" = "$EXPECTED_SHA" ] || {
    log_msg "BŁĄD: Niezgodny SHA-256 dla $apk: $actual_sha"
    exit 1
  }
  log_msg "APK_OK: $apk sha256=${actual_sha}"
done

command -v adb >/dev/null 2>&1 || { log_msg "BŁĄD: Brak binarki adb"; exit 1; }

saved_target=""
if [ -f "${STATE_DIR}/active_adb_target" ]; then
  saved_target="$(tr -d '[:space:]' < "${STATE_DIR}/active_adb_target")"
fi

for cand in "${ADB_TARGET:-}" "$saved_target" "$DEFAULT_ADB_TARGET"; do
  if [ -n "$cand" ]; then
    adb connect "$cand" >/dev/null 2>&1 || true
    if adb get-state >/dev/null 2>&1; then
      break
    fi
  fi
done

if ! adb get-state >/dev/null 2>&1 && [ -r /proc/net/tcp ]; then
  while read -r _ local_addr _ st _; do
    if [ "$st" = "01" ]; then
      hex_port="${local_addr##*:}"
      dec_port=$((16#$hex_port))
      if [ "$dec_port" -ge 30000 ] && [ "$dec_port" -le 65535 ]; then
        candidate="192.168.1.157:${dec_port}"
        if adb connect "$candidate" 2>/dev/null | grep -q "connected"; then
          log_msg "ADB_DISCOVERED: $candidate"
          break
        fi
      fi
    fi
  done < /proc/net/tcp
fi

adb wait-for-device
active_dev="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
[ -n "$active_dev" ] || { log_msg "BŁĄD: Brak aktywnego urządzenia ADB"; exit 1; }
printf '%s\n' "$active_dev" > "${STATE_DIR}/active_adb_target"
log_msg "ADB_ACTIVE: ${active_dev}"

if ! adb shell pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
  log_msg "INSTALL_PKG: $PKG_NAME"
  adb install -r -t -d "$DIST_APK" >> "$RUN_LOG" 2>&1
fi

app_pid="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$app_pid" ]; then
  log_msg "RESTART_ACTIVITY: $ACTIVITY_NAME"
  adb shell am start -n "$ACTIVITY_NAME" >> "$RUN_LOG" 2>&1 || \
    adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >> "$RUN_LOG" 2>&1
  sleep 1
  app_pid="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
fi

[ -n "$app_pid" ] || { log_msg "BŁĄD: Brak aktywnego PID dla $PKG_NAME"; exit 1; }
printf '%s\n' "$app_pid" > "${STATE_DIR}/last_pid"
adb shell dumpsys package "$PKG_NAME" 2>/dev/null | grep -E 'versionCode|versionName|codePath|lastUpdateTime' > "$PKG_DUMP" || true
adb logcat --pid="$app_pid" -d -t 20 >> "$RUN_LOG" 2>&1 || true
log_msg "APP_RUNNING: pkg=${PKG_NAME} pid=${app_pid}"

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Add ocean_suite_recover_and_sync.sh" >> "$RUN_LOG" 2>&1
  token="$(resolve_gh_token)"
  if [ -n "$token" ]; then
    git push "https://${GH_OWNER}:${token}@github.com/${GH_OWNER}/${GH_REPO}.git" main >> "$RUN_LOG" 2>&1 || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main >> "$RUN_LOG" 2>&1 || true
  fi
  log_msg "GIT_SYNC: head=$(git rev-parse --short HEAD)"
else
  log_msg "GIT_CLEAN: head=$(git rev-parse --short HEAD)"
fi
