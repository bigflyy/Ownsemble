#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$root"
mkdir -p .local/flutter-proof
python scripts/stop-flutter-proof.py
# Run by the user from a normal terminal; agents must never invoke this launcher.
windows_executable='./spikes/vk-flutter/build/windows/x64/runner/Debug/ownsemble_flutter_proof.exe'
# Flutter can rebuild Dart without relinking its native runner. Compare the
# actual Dart payloads, not the .exe timestamps, to select the latest code.
debug_payload='./spikes/vk-flutter/build/windows/x64/runner/Debug/data/flutter_assets/kernel_blob.bin'
release_payload='./spikes/vk-flutter/build/windows/x64/runner/Release/data/app.so'
if [[ -f ./spikes/vk-flutter/build/windows/x64/runner/Release/ownsemble_flutter_proof.exe && "$release_payload" -nt "$debug_payload" ]]; then
  windows_executable='./spikes/vk-flutter/build/windows/x64/runner/Release/ownsemble_flutter_proof.exe'
fi
# The agent already built and tested this executable. Do not rebuild it simply
# to open the private VK browser from the user's normal desktop session.
if [[ ! -f "$windows_executable" ]] && ! bash scripts/flutter-proof.sh build windows --debug --no-pub > .local/flutter-proof/windows-build.log 2>&1; then
  printf "Windows build stopped; its local report is ready for the agent.
"
  exit 1
fi
"$windows_executable" --vk-auto &
printf 'Flutter VK test opened. Sign in privately if needed; tests continue automatically.
'
if [[ "${1:-}" == "--windows-only" ]]; then
  exit 0
fi
printf 'Building the Android test separately; no song/button/error transcription is needed.
'
if bash scripts/flutter-proof.sh build apk --debug --no-pub --dart-define=PROOF_AUTORUN=true > .local/flutter-proof/android-build.log 2>&1; then
  printf '{"stage":"apk_built","passed":true}
' > .local/flutter-proof/android-build-status.json
  python scripts/start-flutter-emulator.py
  python scripts/flutter-android-proof.py install
  python scripts/flutter-android-proof.py start
  python scripts/flutter-android-proof.py wait
else
  printf '{"stage":"android_build_failed","passed":false}
' > .local/flutter-proof/android-build-status.json
  printf 'Android build stopped. Its local build report is ready for the agent.
'
fi
