# Flutter/Dart VK feasibility probe

Isolated experiment, not the production MVP. The Electron reference at
`../vk-provider` is preserved. See `../../docs/VK_FLUTTER_FEASIBILITY.md` for results.

Shared Dart code handles metadata validation, SQLite, bounded cookie-free audio
downloads, complete local HLS caching, hashes and playback checks. Native plugins
provide Windows WebView2 / Android WebView and libmpv media support. Existing guarded VK
JavaScript readers are bundled by `node bundle-adapter.cjs`.

From repository-root Git Bash, using the project-local toolchain:

```bash
bash scripts/flutter-proof.sh pub get --offline
python scripts/flutter-plugin-links.py
bash scripts/flutter-proof.sh dart format --output=none --set-exit-if-changed lib test
bash scripts/flutter-proof.sh analyze --no-pub
bash scripts/flutter-proof.sh test --no-pub
python scripts/flutter-native-deps.py
bash scripts/flutter-proof.sh build windows --debug --no-pub
bash scripts/flutter-proof.sh build apk --debug --no-pub --dart-define=PROOF_AUTORUN=true
```

If the first `pub get` reports Windows symlink privileges, it has still written
the plugin registry. Run the junction helper, then repeat `pub get --offline`.
The helper creates only workspace-contained plugin directory junctions; it does
not change system privileges. For an online first dependency resolution, omit
`--offline`. Do not run concurrent builds for the same platform.

Windows synthetic run (automatically restarts offline):

```bash
spikes/vk-flutter/build/windows/x64/runner/Debug/ownsemble_flutter_proof.exe --self-test
```

The test uses generated encrypted HLS/audio and a local synthetic WebView page.
It also imports one existing completed reference-cache sample when available,
validates its hash and tests it through Flutter without another download. It
does not open the reference browser profile. SQLite persists the reference
catalog locally; this is not evidence of a new VK import.

Private VK test, from a normal user terminal:

```bash
spikes/vk-flutter/build/windows/x64/runner/Debug/ownsemble_flutter_proof.exe --vk-auto
```

Sign in privately if needed. The new WebView has its own session; no Electron
cookies are copied. Automatic testing is limited to recognized music pages and
stops for login forms without reading field values. Metadata discovery is bounded
to three minutes and a roughly 250-row sample threshold; it is always partial.
One complete audio sample is enough for this probe.
The dedicated Windows session lives under the agent-denied
`.local/vk-proof/app-profile/flutter-webview` directory.

Sanitized Windows outcomes: `.local/flutter-proof/status.json` and `evidence.json`.
The fixed control file accepts only `run`, `selftest`, `stop` or `restart` plus a fresh UUID
nonce. It cannot accept scripts, URLs, coordinates, credentials or track IDs.

Android automation uses only our test package and its public reports:

```bash
python scripts/flutter-android-proof.py devices
python scripts/flutter-android-proof.py install
python scripts/flutter-android-proof.py fresh-start
python scripts/flutter-android-proof.py status
python scripts/flutter-android-proof.py offline-restart
python scripts/flutter-android-proof.py evidence
```

The helper requires the isolated probe emulator on port 5570; it never selects
another emulator or physical device. It never unlocks a device,
reads browser profiles, enters credentials or captures a screen. Cold restart
is offered only after the probe reports `offline_restart_pending`.

Toolchain: Flutter 3.47.7 / Dart 3.13.5, Java 21 (Android Studio JBR), Android SDK 36, AGP 8.11.1,
Gradle 8.14.3, Kotlin 2.2.20, Visual Studio 2022 C++ and WebView2 runtime.
The older stable WebView plugin needs AGP 8 rather than the generated AGP 9
template. Dependency versions and Dart packages are locked in `pubspec.lock`.
`NuGet.Config` uses `.local/nuget-source` for the three pinned native packages
when this machine's NuGet TLS transport cannot access the official feed.
The full native media library is required: the audio-only Windows variant lacks HLS.

Neither background Android audio/media controls nor production release
packaging is implemented. Android VK sign-in/source capture must be tested
separately from synthetic playback and APK compilation.

`Start Flutter Feasibility.cmd` at the repository root opens Windows and runs
Android automation. Android's normal-session synthetic/cold-restart checks passed.
`Restart Flutter VK Test.cmd` reopens only Windows, selecting the newer Debug/Release
executable and skipping Android. These launchers reuse the app's private session;
agent tools must not invoke them or inspect that session. A protected agent cannot
stop the normal-session browser or launch its denied profile.

The host now handles SPA history changes, refreshes the current route before each
VK run and polls as a fallback. Feed redirects once to My music; login routes stay
private. Thirty-one tests pass and analysis is clean. The latest Windows live run
imported a 256-entry partial sample, captured one source, downloaded and strictly
decoded 9,381,093 bytes / 234.527 seconds, checked playback/seek, and passed a
cold restart/offline verification at 18:42:47Z. Android's fresh generated-media
cache/decode/seek/offline restart passed at 18:42:23Z. Actual Android VK remains
unverified. See the feasibility report for exact scope and stage limits.

Build selection compares Flutter's Dart payloads (Debug kernel blob and Release
app.so), because an incremental Dart build can leave the native runner's `.exe`
timestamp unchanged. The updated app records only the fixed revision category
at startup, allowing sanitized reports to identify the code. `adaptive_wait_v1`
established source capture; `hls_metadata_v1` includes the HLS parsing correction.

`restart_decode_v1` adds app-owned Windows restart and fixed decoder diagnostics.
After the user loads that revision once, an agent can request a restart through
`node spikes/vk-flutter/control.cjs restart`. The running app waits for busy work,
selects the newest known checkout build by its Dart payload, closes its own browser
and starts with fixed `--vk-auto`. The bridge rejects executable/argument/URL/script
fields. It returns no session data. A fully closed app still needs a user launch;
external normal-user launchers remain off limits to agent execution. Selection and
control tests pass. A real app-owned restart succeeded at 18:07:09Z, loading the
new `decoder_signals_v1` build without another user relaunch. Keep the app open
for subsequent restart commands; a fully closed app still needs the user.

The tested VK format is encrypted HLS carrying MP3 inside MPEG-TS. Shared Dart
code uses `cryptography` 2.9.0 for ordinary HLS AES transport decryption, validates
and extracts one MPEG-audio PES stream, removes segment metadata and preserves
complete encoded MP3 frames without re-encoding. Strict full native decoding
still gates publication. The raw and TS-wrapped synthetic MP3 produce identical
cached audio hashes on Windows and Android. The app uses no separate ffmpeg
executable or Python audio helper. Current revision: `ts_mp3_v1`.

For a visible offline listening check, double-click repository-root `Listen Offline.cmd` in Windows Explorer, then **Listen to cached sample**. It starts the fixed Release build with `--offline`, without a browser or private session. Agent-launched GUI windows live on the hidden sandbox desktop and are not visible to the user.
