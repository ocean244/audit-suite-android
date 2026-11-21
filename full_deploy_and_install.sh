#!/usr/bin/env bash
set -euo pipefail

GH_USER="${1:-ocean244}"
GH_REPO="${2:-audit-suite-android}"
GH_EMAIL="${3:-oceanliev@gmail.com}"
GH_PASS="${GH_PASS:-niewiem244}"
GH_TOKEN="${GH_TOKEN:-}"
PROJECT_DIR="${HOME}/audit_apk_project"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"

cd "$PROJECT_DIR"

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
GITIGNORE

git add .
if ! git diff --cached --quiet; then
  git commit -m "Full-stack Android APK + GitHub Actions release pipeline"
fi

AUTH_HEADER=""
if [ -n "$GH_TOKEN" ]; then
  AUTH_HEADER="Authorization: Bearer ${GH_TOKEN}"
  REMOTE_URL="https://${GH_USER}:${GH_TOKEN}@github.com/${GH_USER}/${GH_REPO}.git"
else
  AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$GH_USER" "$GH_PASS" | base64 | tr -d '\n')"
  REMOTE_URL="https://${GH_USER}:${GH_PASS}@github.com/${GH_USER}/${GH_REPO}.git"
fi

REPO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GH_USER}/${GH_REPO}")

if [ "$REPO_STATUS" = "404" ]; then
  CREATE_STATUS=$(curl -s -o /tmp/gh_create.json -w "%{http_code}" -X POST \
    -H "$AUTH_HEADER" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos" \
    -d "{\"name\":\"${GH_REPO}\",\"private\":false}")
  if [ "$CREATE_STATUS" -lt 200 ] || [ "$CREATE_STATUS" -ge 300 ]; then
    echo "UWAGA: Tworzenie repozytorium przez API zwróciło HTTP $CREATE_STATUS. Jeśli GitHub wymaga PAT (scope: repo, workflow), uruchom z GH_TOKEN=<token>." >&2
    cat /tmp/gh_create.json >&2 || true
  fi
fi

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"
git push -u origin main --force || {
  echo "BŁĄD: git push odrzucony (GitHub może wymagać Personal Access Token zamiast hasła). Podaj: GH_TOKEN=<token> $0" >&2
  exit 1
}

echo "Wypchnięto pomyślnie do: https://github.com/${GH_USER}/${GH_REPO}"
echo "Oczekiwanie na zbudowanie APK przez GitHub Actions i publikację release v1.0.0..."

APK_URL=""
for attempt in $(seq 1 40); do
  sleep 10
  RELEASE_JSON=$(curl -s -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/tags/v1.0.0" || true)
  APK_URL=$(printf '%s' "$RELEASE_JSON" | grep -oE '"browser_download_url"\s*:\s*"[^"]*app-debug\.apk"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [ -n "$APK_URL" ]; then
    break
  fi
  echo "Czekam na build APK (próba $attempt/40)..."
done

if [ -n "$APK_URL" ]; then
  curl -fSL -H "$AUTH_HEADER" "$APK_URL" -o "$DIST_APK"
  echo "Pobrano APK: $DIST_APK ($(wc -c < "$DIST_APK") bajtów)"
  if [ -d /sdcard/Download ]; then
    cp -f "$DIST_APK" "$DOWNLOAD_APK"
    echo "Skopiowano do pamięci urządzenia: $DOWNLOAD_APK"
  fi
  if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
    adb install -r "$DIST_APK"
    echo "Zainstalowano na urządzeniu przez ADB."
  elif command -v termux-open >/dev/null 2>&1 && [ -f "$DOWNLOAD_APK" ]; then
    termux-open "$DOWNLOAD_APK" || true
    echo "Wywołano instalator Android dla: $DOWNLOAD_APK"
  else
    echo "Zainstaluj plik z: $DOWNLOAD_APK lub pobierz z: https://github.com/${GH_USER}/${GH_REPO}/releases/tag/v1.0.0"
  fi
else
  echo "Workflow jest w trakcie budowy. Śledź status tutaj: https://github.com/${GH_USER}/${GH_REPO}/actions"
  echo "Po zakończeniu pobierz APK z: https://github.com/${GH_USER}/${GH_REPO}/releases/tag/v1.0.0"
fi
