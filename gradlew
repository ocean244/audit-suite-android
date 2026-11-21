#!/usr/bin/env sh
set -eu

APP_HOME="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLASSPATH="$APP_HOME/gradle/wrapper/gradle-wrapper.jar"

if [ ! -f "$CLASSPATH" ]; then
  mkdir -p "$APP_HOME/gradle/wrapper"
  curl -fsSL "https://raw.githubusercontent.com/gradle/gradle/v8.10.2/gradle/wrapper/gradle-wrapper.jar" -o "$CLASSPATH"
fi

exec java -Xmx3072m -Dfile.encoding=UTF-8 -cp "$CLASSPATH" org.gradle.wrapper.GradleWrapperMain "$@"
