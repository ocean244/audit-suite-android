#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
STATE_DIR="${PROJECT_DIR}/state"
LOG_DIR="${PROJECT_DIR}/logs"
DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
DAEMON_LOG="${LOG_DIR}/daemon.log"
PKG_NAME="com.oceansuite.audit"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$STATE_DIR" "$LOG_DIR"
cd "$PROJECT_DIR"

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

REMOTE_URL="https://github.com/${GH_OWNER}/${GH_REPO}.git"
TOKEN="$(resolve_gh_token)"
if [ -n "$TOKEN" ]; then
  REMOTE_URL="https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git"
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Sync local audit suite state and scripts"
fi

git fetch "$REMOTE_URL" main
if ! git rebase FETCH_HEAD; then
  git rebase --abort || true
  git merge --no-edit FETCH_HEAD
fi

git push "$REMOTE_URL" HEAD:main
echo "GIT_PUSH_OK: head=$(git rev-parse --short HEAD) branch=main"

if [ -f "$DAEMON_PID_FILE" ]; then
  DPID="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
    echo "DAEMON_ALIVE: pid=${DPID}"
  else
    echo "DAEMON_DOWN: pid=${DPID:-none}"
  fi
fi

if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  APID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  echo "APP_ALIVE: pkg=${PKG_NAME} pid=${APID:-none}"
fi
