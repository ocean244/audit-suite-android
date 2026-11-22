#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/full_stack_release.txt"
PKG_NAME="com.oceansuite.audit"
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

cd "$PROJECT_DIR"
git add -A
PUSH_STATE="CLEAN_NO_CHANGES"
if ! git diff --cached --quiet; then
  git commit -m "Track sync_and_install_v2.sh in repository"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main && PUSH_STATE="PUSHED_OK" || PUSH_STATE="PUSH_FAILED"
  else
    git push origin main && PUSH_STATE="PUSHED_OK" || PUSH_STATE="PUSH_FAILED"
  fi
fi

HEAD_SHA="$(git rev-parse --short HEAD)"
APK_SHA="$(sha256sum "$INTERNAL_APK" | awk '{print $1}')"
APP_PID="none"
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$APP_PID" ] || APP_PID="none"
fi

NET_OK="NO"
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || curl -I -s --max-time 4 https://github.com >/dev/null 2>&1; then
  NET_OK="YES"
fi

TS="$(date '+%Y-%m-%d %H:%M:%S')"
{
  printf 'TIMESTAMP=%s\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$APK_SHA"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  printf 'GIT_PUSH=%s\n' "$PUSH_STATE"
  printf 'NET_REACHABLE=%s\n' "$NET_OK"
} > "$STATUS_FILE"

cat "$STATUS_FILE"
git status -s
