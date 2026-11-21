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
DEFAULT_ADB_TARGET="192.168.1.157:42079"
EXPECTED_SHA="${EXPECTED_SHA:-107a7e58313c0ef4a3db4c02b6ec01db2a4e43ec2a09784ebee2aab1ecc89344}"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$DIST_DIR" "$LOG_DIR" "$STATE_DIR"
RUN_LOG="${LOG_DIR}/last_run.log"
: > "$RUN_LOG"

log_msg() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$RUN_LOG"
}

cd "$PROJECT_DIR"

verify_apks() {
  for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
    [ -f "$apk" ] || { log_msg "BŁĄD: Brak pliku $apk"; exit 1; }
    local actual_sha
    actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
    [ "$actual_sha" = "$EXPECTED_SHA" ] || {
      log_msg "BŁĄD: Niezgodny SHA-256 dla $apk: $actual_sha"
      exit 1
    }
    log_msg "APK_OK: $apk sha256=${actual_sha}"
  done
}

sync_git_repo() {
  git add .
  if ! git diff --cached --quiet; then
    git commit -m "Update Ocean Audit Suite controller and directory layout" >> "$RUN_LOG" 2>&1
    if [ -n "${GH_TOKEN:-}" ]; then
      git push origin main >> "$RUN_LOG" 2>&1 || true
    elif [ -f "$TOKEN_FILE" ]; then
      local saved_token
      saved_token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
      if [ -n "$saved_token" ]; then
        git push "https://ocean244:${saved_token}@github.com/ocean244/audit-suite-android.git" main >> "$RUN_LOG" 2>&1 || true
      fi
    fi
    log_msg "GIT_SYNC: head=$(git rev-parse --short HEAD)"
  else
    log_msg "GIT_CLEAN: head=$(git rev-parse --short HEAD)"
  fi
}

discover_and_connect_adb() {
  command -v adb >/dev/null 2>&1 || { log_msg "BŁĄD: Brak binarki adb"; exit 1; }

  if [ -n "${ADB_TARGET:-}" ]; then
    adb connect "$ADB_TARGET" >> "$RUN_LOG" 2>&1 || true
  fi

  if ! adb get-state >/dev/null 2>&1; then
    adb connect "$DEFAULT_ADB_TARGET" >> "$RUN_LOG" 2>&1 || true
  fi

  if ! adb get-state >/dev/null 2>&1 && [ -r /proc/net/tcp ]; then
    while read -r _ local_addr _ st _; do
      if [ "$st" = "01" ]; then
        local hex_port dec_port candidate
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
  local active_dev
  active_dev="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  [ -n "$active_dev" ] || { log_msg "BŁĄD: Brak aktywnego urządzenia ADB w stanie device"; exit 1; }
  printf '%s\n' "$active_dev" > "${STATE_DIR}/active_adb_target"
  log_msg "ADB_ACTIVE: ${active_dev}"
}

install_and_launch_app() {
  adb install -r -t -d "$DIST_APK" >> "$RUN_LOG" 2>&1
  adb shell pm list packages | grep -qF "$PKG_NAME" || {
    log_msg "BŁĄD: Pakiet $PKG_NAME nieobecny po instalacji"
    exit 1
  }

  adb shell am start -n "$ACTIVITY_NAME" >> "$RUN_LOG" 2>&1 || \
    adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >> "$RUN_LOG" 2>&1
  sleep 1

  local app_pid
  app_pid="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$app_pid" ] || {
    log_msg "BŁĄD: Brak aktywnego PID dla $PKG_NAME po uruchomieniu"
    exit 1
  }

  printf '%s\n' "$app_pid" > "${STATE_DIR}/last_pid"
  adb logcat --pid="$app_pid" -d -t 25 >> "$RUN_LOG" 2>&1 || true
  log_msg "APP_RUNNING: pkg=${PKG_NAME} activity=${ACTIVITY_NAME} pid=${app_pid}"
}

verify_apks
discover_and_connect_adb
install_and_launch_app
sync_git_repo
log_msg "COMPLETE: 100%"
