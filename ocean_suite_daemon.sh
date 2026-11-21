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
POLL_INTERVAL="${POLL_INTERVAL:-15}"
MAX_CYCLES="${MAX_CYCLES:-0}"

mkdir -p "$DIST_DIR" "$LOG_DIR" "$STATE_DIR"
DAEMON_LOG="${LOG_DIR}/daemon.log"

log_event() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$DAEMON_LOG"
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

verify_apks() {
  for apk in "$DIST_APK" "$DOWNLOAD_APK"; do
    [ -f "$apk" ] || { log_event "BŁĄD: Brak pliku $apk"; return 1; }
    local actual_sha
    actual_sha="$(sha256sum "$apk" | awk '{print $1}')"
    [ "$actual_sha" = "$EXPECTED_SHA" ] || {
      log_event "BŁĄD: Niezgodny SHA-256 dla $apk: $actual_sha"
      return 1
    }
  done
  return 0
}

ensure_adb_connection() {
  command -v adb >/dev/null 2>&1 || { log_event "BŁĄD: Brak binarki adb"; return 1; }

  local saved_target=""
  if [ -f "${STATE_DIR}/active_adb_target" ]; then
    saved_target="$(tr -d '[:space:]' < "${STATE_DIR}/active_adb_target")"
  fi

  for cand in "${ADB_TARGET:-}" "$saved_target" "$DEFAULT_ADB_TARGET"; do
    if [ -n "$cand" ]; then
      adb connect "$cand" >/dev/null 2>&1 || true
      if adb get-state >/dev/null 2>&1; then
        printf '%s\n' "$cand" > "${STATE_DIR}/active_adb_target"
        return 0
      fi
    fi
  done

  if [ -r /proc/net/tcp ]; then
    while read -r _ local_addr _ st _; do
      if [ "$st" = "01" ]; then
        local hex_port dec_port candidate
        hex_port="${local_addr##*:}"
        dec_port=$((16#$hex_port))
        if [ "$dec_port" -ge 30000 ] && [ "$dec_port" -le 65535 ]; then
          candidate="192.168.1.157:${dec_port}"
          if adb connect "$candidate" 2>/dev/null | grep -q "connected"; then
            printf '%s\n' "$candidate" > "${STATE_DIR}/active_adb_target"
            log_event "ADB_RECOVERED: $candidate"
            return 0
          fi
        fi
      fi
    done < /proc/net/tcp
  fi

  return 1
}

ensure_app_alive() {
  if ! adb shell pm list packages 2>/dev/null | grep -qF "$PKG_NAME"; then
    log_event "INSTALL_PKG: $PKG_NAME"
    adb install -r -t -d "$DIST_APK" >/dev/null 2>&1
  fi

  local app_pid
  app_pid="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$app_pid" ]; then
    log_event "RESTART_ACTIVITY: $ACTIVITY_NAME"
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || \
      adb shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 1
    app_pid="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  fi

  if [ -n "$app_pid" ]; then
    printf '%s\n' "$app_pid" > "${STATE_DIR}/last_pid"
    log_event "HEARTBEAT_OK: pkg=${PKG_NAME} pid=${app_pid}"
  else
    log_event "HEARTBEAT_WARN: Brak aktywnego PID dla ${PKG_NAME}"
  fi
}

sync_repo_once() {
  cd "$PROJECT_DIR"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Add ocean_suite_daemon.sh continuous monitor" >> "$DAEMON_LOG" 2>&1
    local token
    token="$(resolve_gh_token)"
    if [ -n "$token" ]; then
      git push "https://${GH_OWNER}:${token}@github.com/${GH_OWNER}/${GH_REPO}.git" main >> "$DAEMON_LOG" 2>&1 || true
    elif [ -n "${GH_TOKEN:-}" ]; then
      git push origin main >> "$DAEMON_LOG" 2>&1 || true
    fi
    log_event "GIT_SYNC: head=$(git rev-parse --short HEAD)"
  fi
}

verify_apks
sync_repo_once

cycle=0
while true; do
  cycle=$((cycle + 1))
  if ensure_adb_connection; then
    ensure_app_alive
  else
    log_event "ADB_OFFLINE: oczekiwanie na połączenie bezprzewodowe ADB"
  fi

  if [ "$MAX_CYCLES" -gt 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done
