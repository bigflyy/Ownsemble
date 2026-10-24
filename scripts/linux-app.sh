#!/usr/bin/env bash
# Linux-native generated-data harness. Works on ordinary Linux and WSLg.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
proof_root="${OWNSEMBLE_LINUX_PROOF_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/ownsemble-linux-proof}"
workspace="$proof_root/workspace"
action="${1:-preview}"
mode="${2:-debug}"
if [[ "$proof_root" == "$repo_root" || "$workspace" == "$repo_root" ]]; then
  printf 'The proof workspace must be separate from the source checkout.\n' >&2
  exit 2
fi
export PUB_CACHE="$proof_root/pub-cache"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=true
if [[ -n "${OWNSEMBLE_FLUTTER_SDK:-}" ]]; then
  flutter_cli="$OWNSEMBLE_FLUTTER_SDK/bin/flutter"
  engine_version="$(tr -d '\r\n' < "$OWNSEMBLE_FLUTTER_SDK/bin/internal/engine.version")"
  [[ "$engine_version" =~ ^[0-9a-f]{40}$ ]] || exit 2
  export FLUTTER_PREBUILT_ENGINE_VERSION="$engine_version"
else
  flutter_cli="$(command -v flutter)"
fi
case "$action" in
  build)
    [[ "$mode" == debug || "$mode" == release ]] || exit 2
    # Preserve the original source identity before staging a source-only build workspace.
    build_revision="$(bash "$repo_root/scripts/build-revision.sh")"
    mkdir -p -- "$proof_root" "$workspace"
    python3 "$repo_root/scripts/linux-proof-source.py" "$proof_root/source.tar"
    tar -xf "$proof_root/source.tar" -C "$workspace"
    cd -- "$workspace/app"
    "$flutter_cli" pub get
    if [[ -z "${OWNSEMBLE_CEF_ROOT:-}" ]]; then
      export OWNSEMBLE_CEF_ROOT
      OWNSEMBLE_CEF_ROOT="$(python3 "$repo_root/scripts/prepare-linux-browser.py" "$proof_root/cef-runtime")"
    fi
    "$flutter_cli" build linux "--$mode" --no-pub "--dart-define=OWNSEMBLE_BUILD_REVISION=$build_revision"
    ;;
  preview|smoke|streaming|browser)
    [[ "$mode" == debug || "$mode" == release ]] || exit 2
    cd -- "$workspace"
    case "$action" in
      preview) flag=--demo ;;
      smoke) flag=--smoke-test ;;
      streaming) flag=--streaming-smoke ;;
      browser) flag=--browser-smoke ;;
    esac
    exec "$workspace/app/build/linux/x64/$mode/bundle/ownsemble" "$flag"
    ;;
  *) printf 'Use build, preview, smoke, streaming or browser, followed by debug/release.\n' >&2; exit 2 ;;
esac
