#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Label compiled app payloads automatically without reading any runtime/private files.
if [[ "${1:-}" == build || "${1:-}" == run ]]; then
  # Distinguish the reviewed commit from any unpublished public source changes.
  task_build_revision="$(bash "$task_root/scripts/build-revision.sh")"
  set -- "$@" "--dart-define=OWNSEMBLE_BUILD_REVISION=$task_build_revision"
fi
task_windows_root="$(cd -- "$task_root" && pwd -W)"
export APPDATA="$task_windows_root/.local/flutter-config"
export LOCALAPPDATA="$task_windows_root/.local/flutter-config/local"
export PUB_CACHE="$task_windows_root/.local/pub-cache"
export GRADLE_USER_HOME="$task_windows_root/.local/gradle-cache"
export ANDROID_HOME="$task_windows_root/.local/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"
export ANDROID_USER_HOME="$task_windows_root/.local/android-user"
export NUGET_HTTP_CACHE_PATH="$task_windows_root/.local/nuget-http"
export NUGET_PACKAGES="$task_windows_root/.local/nuget-packages"
export NUGET_SCRATCH="$task_windows_root/.local/nuget-tmp"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=true
# Use this SDK's pinned release artifacts, including from native build children.
# Flutter officially supports this override for reproducible CI/bootstrap runs.
task_engine_version="$(tr -d '\r\n' < "$task_root/.local/toolchains/flutter/bin/internal/engine.version")"
if [[ ! "$task_engine_version" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'The local Flutter engine version is invalid.\n' >&2
  exit 1
fi
export FLUTTER_PREBUILT_ENGINE_VERSION="$task_engine_version"
export PATH="/c/MyProgramms/Git/cmd:$task_root/.local/toolchains:$task_root/.local/toolchains/flutter/bin:$PATH"
cd -- "$task_root/app"
if [[ "${1:-}" == "gradle" ]]; then
  shift
  cd android
  exec ./gradlew.bat "$@"
fi
if [[ "${1:-}" == "dart" ]]; then
  shift
  exec "$task_root/.local/toolchains/flutter/bin/cache/dart-sdk/bin/dart.exe" "$@"
fi
exec "$task_root/.local/toolchains/flutter/bin/cache/dart-sdk/bin/dart.exe" \
  "$task_root/.local/toolchains/flutter/bin/cache/flutter_tools.snapshot" "$@"
