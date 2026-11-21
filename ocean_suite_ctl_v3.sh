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

trigger_gh_dispatch_if_requested() {
  if [ "${TRIGGER_GH_BUILD:-0}" != "1" ]; then
    return 0
  fi
  local token
  token="$(resolve_gh_token)"
  [ -n "$token" ] || { log_msg "BŁĄD: TRIGGER_GH_BUILD=1 wymaga tokenu GH_TOKEN lub ~/.gh_token"; exit 1; }
  command -v curl >/dev/null 2>&1 || { log_msg "BŁĄD: Brak curl"; exit 1; }

  local wf_json wf_id
  wf_json="$(curl -fsSL -H "Authorization: Bearer ${token}" \
    "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/actions/workflows")"
  wf_id="$(printf '%s' "$wf_json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  [ -n "$wf_id" ] || { log_msg "BŁĄD: Nie znaleziono workflow_id w ${GH_OWNER}/${GH_REPO}"; exit 1; }

  curl -fsSL -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -d '{"ref":"main"}' \
    "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/actions/workflows/${wf_id}/dispatches" >> "$RUN_LOG" 2>&1
  log_msg "GH_DISPATCH_SENT: workflow_id=${wf_id} ref=main"
}

fetch_latest_release_apk_if_requested() {
  if [ "${FETCH_LATEST_RELEASE:-0}" != "1" ]; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { log_msg "BŁĄD: Brak curl"; exit 1; }

  local token rel_json download_url tmp_apk
  token="$(resolve_gh_token)"
  if [ -n "$token" ]; then
    rel_json="$(curl -fsSL -H "Authorization: Bearer ${token}" \
      "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/releases/latest")"
  else
    rel_json="$(curl -fsSL \
      "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/releases/latest")"
  fi

  download_url="$(printf '%s' "$rel_json" | grep -oE 'https://[^"]+\.apk' | head -n 1 || true)"
  [ -n "$download_url" ] || { log_msg "BŁĄD: Brak assetu .apk w najnowszym wydaniu"; exit 1; }

  tmp_apk="${DIST_DIR}/release-download.apk"
  if [ -n "$token" ]; then
    curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: application/octet-stream" \
      -o "$tmp_apk" "$download_url"
  else
    curl -fsSL -o "$tmp_apk" "$download_url"
  fi

  [ -s "$tmp_apk" ] || { log_msg "BŁĄD: Pobrany plik APK jest pusty"; exit 1; }
  cp -f "$tmp_apk" "$DIST_APK"
  cp -f "$tmp_apk" "$DOWNLOAD_APK"
  rm -f "$tmp_apk"

  EXPECTED_SHA="$(sha256sum "$DIST_APK" | awk '{print $1}')"
  log_msg "RELEASE_APK_UPDATED: url=${download_url} sha256=${EXPECTED_SHA}"
}

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
  adb logcat --pid="$app_pid" -d -t 30 >> "$RUN_LOG" 2>&1 || true
  log_msg "APP_RUNNING: pkg=${PKG_NAME} activity=${ACTIVITY_NAME} pid=${app_pid}"
}

sync_git_repo() {
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Update Ocean Audit Suite controller v3" >> "$RUN_LOG" 2>&1
    local token
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
}

trigger_gh_dispatch_if_requested
fetch_latest_release_apk_if_requested
verify_apks
discover_and_connect_adb
install_and_launch_app
sync_git_repo
log_msg "COMPLETE: 100%"
