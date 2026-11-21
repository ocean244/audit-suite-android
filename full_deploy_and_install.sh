#!/usr/bin/env bash
set -euo pipefail

GH_USER="${1:-ocean244}"
GH_REPO="${2:-audit-suite-android}"
GH_EMAIL="${3:-oceanliev@gmail.com}"
GH_TOKEN="${GH_TOKEN:-}"
PROJECT_DIR="${HOME}/audit_apk_project"
TMP_DIR="${TMPDIR:-${PROJECT_DIR}/.tmp}"
DIST_DIR="${PROJECT_DIR}/dist"
DIST_APK="${DIST_DIR}/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
TOKEN_FILE="${HOME}/.gh_token"

mkdir -p "$TMP_DIR" "$DIST_DIR"
cd "$PROJECT_DIR"

if [ ! -d /sdcard/Download ] && command -v termux-setup-storage >/dev/null 2>&1; then
  termux-setup-storage || true
fi

if [ -z "$GH_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  GH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

if [ -z "$GH_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

GH_TOKEN="$(printf '%s' "$GH_TOKEN" | tr -d '[:space:]')"

if [ ! -d .git ]; then
  git init -b main
fi

git config user.name "$GH_USER"
git config user.email "$GH_EMAIL"

cat << 'GITIGNORE' > .gitignore
.gradle/
build/
app/build/
dist/*.apk
local.properties
*.iml
.tmp/
GITIGNORE

git add .
if ! git diff --cached --quiet; then
  git commit -m "Deploy Ocean Audit Suite APK pipeline"
fi

run_local_fallback() {
  echo "[FALLBACK] Brak ważnego tokenu GitHub (HTTP 401) — uruchamiam lokalną weryfikację i pakowanie projektu..."
  if [ -x ./gradlew ] && [ -n "${ANDROID_HOME:-}" ] && command -v java >/dev/null 2>&1; then
    if ./gradlew assembleDebug --no-daemon; then
      BUILT_APK="app/build/outputs/apk/debug/app-debug.apk"
      if [ -f "$BUILT_APK" ]; then
        cp -f "$BUILT_APK" "$DIST_APK"
        [ -d /sdcard/Download ] && cp -f "$DIST_APK" "$DOWNLOAD_APK" || true
        echo "Zbudowano lokalnie APK: $DIST_APK ($(wc -c < "$DIST_APK") bajtów)"
        return 0
      fi
    fi
  fi
  BUNDLE_TAR="${DIST_DIR}/OceanAuditSuite-source.tar.gz"
  tar -czf "$BUNDLE_TAR" \
    --exclude=".git" \
    --exclude=".gradle" \
    --exclude="build" \
    --exclude="app/build" \
    --exclude=".tmp" \
    --exclude="dist/*.apk" \
    .
  if [ -d /sdcard/Download ]; then
    cp -f "$BUNDLE_TAR" "/sdcard/Download/OceanAuditSuite-source.tar.gz"
    echo "Zapisano paczkę źródłową gotową do kompilacji: /sdcard/Download/OceanAuditSuite-source.tar.gz ($(wc -c < "$BUNDLE_TAR") bajtów)"
  fi
  echo "Zapisano paczkę: $BUNDLE_TAR ($(wc -c < "$BUNDLE_TAR") bajtów)"
  echo "Aby dokończyć build APK w GitHub Actions i pobrać app-debug.apk, podaj ważny PAT (scopes: repo, workflow):"
  echo "  GH_TOKEN=\"ghp_NOWY_TOKEN\" $0 ${GH_USER} ${GH_REPO} ${GH_EMAIL}"
}

if [ -z "$GH_TOKEN" ]; then
  run_local_fallback
  exit 0
fi

AUTH_HEADER="Authorization: Bearer ${GH_TOKEN}"
REMOTE_URL="https://${GH_USER}:${GH_TOKEN}@github.com/${GH_USER}/${GH_REPO}.git"

echo "[1/4] Weryfikacja uwierzytelniania GitHub API..."
USER_OUT="${TMP_DIR}/gh_user.json"
USER_STATUS=$(curl -sS -o "$USER_OUT" -w "%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/user") || USER_STATUS="000"
echo "API /user HTTP: $USER_STATUS"

if [ "$USER_STATUS" != "200" ]; then
  [ -f "$USER_OUT" ] && cat "$USER_OUT" && echo ""
  run_local_fallback
  exit 0
fi

echo "[2/4] Sprawdzanie / tworzenie repozytorium ${GH_USER}/${GH_REPO}..."
REPO_OUT="${TMP_DIR}/gh_repo.json"
REPO_STATUS=$(curl -sS -o "$REPO_OUT" -w "%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GH_USER}/${GH_REPO}") || REPO_STATUS="000"
echo "API /repos HTTP: $REPO_STATUS"

if [ "$REPO_STATUS" = "404" ]; then
  CREATE_OUT="${TMP_DIR}/gh_create.json"
  CREATE_STATUS=$(curl -sS -o "$CREATE_OUT" -w "%{http_code}" -X POST \
    -H "$AUTH_HEADER" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos" \
    -d "{\"name\":\"${GH_REPO}\",\"private\":false}") || CREATE_STATUS="000"
  echo "API create repo HTTP: $CREATE_STATUS"
  if [ "$CREATE_STATUS" -lt 200 ] || [ "$CREATE_STATUS" -ge 300 ]; then
    [ -f "$CREATE_OUT" ] && cat "$CREATE_OUT" && echo ""
    exit 1
  fi
fi

echo "[3/4] Wypychanie gałęzi main do GitHub..."
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"
git push -u origin main --force

printf '%s\n' "$GH_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

echo "[4/4] Oczekiwanie na zbudowanie APK w GitHub Actions i publikację v1.0.0..."
APK_URL=""
for attempt in $(seq 1 45); do
  sleep 10
  RELEASE_JSON=$(curl -sS -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/tags/v1.0.0" || true)
  APK_URL=$(printf '%s' "$RELEASE_JSON" | grep -oE '"browser_download_url"\s*:\s*"[^"]*app-debug\.apk"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [ -n "$APK_URL" ]; then
    break
  fi
  echo "Budowanie APK w toku (próba $attempt/45)..."
done

if [ -n "$APK_URL" ]; then
  curl -fSL -H "$AUTH_HEADER" "$APK_URL" -o "$DIST_APK"
  echo "Pobrano APK: $DIST_APK ($(wc -c < "$DIST_APK") bajtów)"
  if [ -d /sdcard/Download ]; then
    cp -f "$DIST_APK" "$DOWNLOAD_APK"
    echo "Zapisano plik instalacyjny: $DOWNLOAD_APK"
  fi
  if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
    adb install -r "$DIST_APK"
    echo "Zainstalowano na urządzeniu przez ADB."
  elif command -v termux-open >/dev/null 2>&1 && [ -f "$DOWNLOAD_APK" ]; then
    termux-open "$DOWNLOAD_APK" || true
    echo "Uruchomiono instalator Android dla: $DOWNLOAD_APK"
  else
    echo "Zainstaluj z: $DOWNLOAD_APK lub pobierz z: https://github.com/${GH_USER}/${GH_REPO}/releases/tag/v1.0.0"
  fi
else
  echo "Sprawdź postęp budowy: https://github.com/${GH_USER}/${GH_REPO}/actions"
  echo "Release v1.0.0: https://github.com/${GH_USER}/${GH_REPO}/releases/tag/v1.0.0"
fi
