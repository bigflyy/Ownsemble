# Ownsemble desktop app

Flutter/Dart/SQLite implementation, separate from both preserved feasibility probes.
This is the first Windows candidate. Actual Android VK access and VK playlist
membership are still acceptance gates; this is not a claim of a finished release.

## Open on this PC

Double-click repository-root **Start Ownsemble.cmd** in Windows Explorer. Click
**Connect VK** once to consent to connection and automatic refresh. The app uses
the retained Flutter WebView session internally; sign in privately only if VK
requires it: Settings → Sign in privately. Both VK music pages stay hidden during
ordinary playback and refresh. No repeated Import clicks are needed.

Agents use generated-data checks by default. User-authorized live testing uses
fixed application controls and sanitized outcomes. Never inspect profiles,
sign-in UI, credentials or cookies. See the latest handoff for current evidence.

## Implemented behavior

- Additional keyboard controls share their bindings with hover hints and an F1
  reference beside Settings. Playback shortcuts yield to text editing and modal
  routes; focused buttons retain normal Space activation. See the [key reference
  and validation scope](../docs/KEYBOARD_USABILITY.md).

- Search accepts spaces while the global Space shortcut remains available outside
  text editing. The speaker toggles mute and remembers the previous volume across
  restart. SAVED uses one centered status, duration/header columns align, and cached
  thumbnails open a zoomable local preview. See [controls/UI evidence](../docs/CONTROLS_UI_FIXES.md).

- Optional artwork, recording details, separate import/upload dates and a cached
  lyrics panel. Visible covers use dwell/viewport demand, discard obsolete work,
  deduplicate images and load through a bounded background cache. Old visible
  metadata is looked up lazily without background lyrics or blocking Play. Current
  live VK lyric retrieval remains unproven; see [metadata coverage](../docs/METADATA_ENRICHMENT.md).
- Recording identity is now required before playback/cache publication. A source
  seen after clicking may be the next song's prefetch and is insufficient. Legacy
  downloads need an online identity check before offline eligibility; originals
  are preserved during verified replacement. See [repair evidence](../docs/RECORDING_INTEGRITY.md).

- SQLite transactions, local Cyrillic-aware search, progressive metadata merging,
  All/VK/Offline/Recent/Most played views and saved settings/queue.
- Play/pause, seeking, volume, next/previous, queue addition/selection, shuffle and
  repeat. Playback prefers verified complete local assets.
- Playback can start while the same approved audio downloads into the cache.
  The native player reads a private loopback relay; HLS requests and complete
  cache writes share upstream resources. MP3 in MPEG-TS is extracted per segment
  without re-encoding. Seeking waits for needed data on slow connections.
- Complete cookie-free downloads using the proven HLS/AES/TS/MP3 path. Strict
  decoding, hashes and atomic publication gate offline-ready state. Temporary
  source URLs remain in memory. Failed or cancelled downloads remain retryable.
- Default 2 GiB LRU budget for automatic audio. Track pins and Pile snapshot pins
  stay outside that budget. Other pins, current audio and active downloads are
  protected. Later Pile additions extend pinned snapshots; removing an occurrence
  does not silently release those retention references.
- Several named Piles; each addition has its own occurrence ID. Repeated songs
  remain separate and removing one occurrence leaves the track and others intact.
- One-time automatic-sync consent. Existing catalogs use a short newest-first
  check on startup and every two minutes. A local checkpoint of up to 128 ordered
  music IDs survives restart. Checks stop at a consecutive known block (12 IDs,
  or the whole saved block for a smaller library). Reading stops at 256 unique
  rows, eight pages, or a 15-second scanning budget; navigation is separate.
  An incomplete check preserves its checkpoint and all saved tracks.
- Initial import and manual **Refresh VK** use deeper, bounded 90-second slices.
  Continuations keep the current viewport; initial-import pending state persists.
  Coverage remains partial without a reliable provider end/total witness.
  Automatic checks reload the guarded personal-library document so they examine
  fresh entries rather than stale rows at the previous scroll position.
- One separate hidden playback page resolves independently. Muted metadata-only
  pages can be retained; activated or cancelled documents are destroyed. Playback
  does not paginate or await metadata refresh.
- Recent uses playback starts; Most played qualifies at 30 seconds or half the
  duration, whichever is shorter. Seeking does not count as listening time.

VK playlists are explicitly unavailable in Settings until listing and membership
are verified. Local Pile pins do not fulfill the VK-playlist pinning requirement.
Uncached playback uses streaming. Normal uncached Library Play/Next measured
2216/1663 ms after fixing provider order. Six fixed old-tail selections also
played with complete caches and nonzero output; five uncached starts took
2723-4755 ms. Their VK upload/addition metadata buckets were 2015-2019 (five)
and unknown (one); these are not composition release dates. Known-age old audio
passed controls/replay and fresh Release offline playback/seek at 721 ms first
audio with no provider connection or received bytes. Final ordinary Release
cached Play measured 942 ms. Cold uncached VK startup can still take 10-20 seconds.
Every-track availability is not established; the original restricted recording
still does not play in this VK session. Empty capture is separately unresolved.
Only complete validated assets are labelled offline-ready. Restricted recordings
remain saved. Library order follows observed VK positions; partial scans never
delete unseen tracks. See [current evidence](../docs/PLAYBACK_REPAIR.md).

## Development

Prerequisites: the pinned Flutter 3.47.7 / Dart 3.13.5 SDK under
`.local/toolchains/flutter`, Visual Studio 2022 C++/Windows SDK, WebView2 Runtime,
and Git Bash. Standalone runtime also needs Microsoft Visual C++ x64 runtime (already present on this PC). Python/Node are developer tools only. Runtime playback uses Dart
and bundled native libraries, with no Python/FFmpeg executable or Ownsemble server.

Follow the [tests-first Git workflow](../docs/GIT_WORKFLOW.md): write a behavioral
regression test and observe its failure before implementing a behavior change.
Run from repository-root Git Bash:

```bash
bash scripts/app.sh pub get
python scripts/app-plugin-links.py
python scripts/app-native-deps.py
bash scripts/app.sh pub get --offline
node app/bundle-adapter.cjs
node --test app/adapter/music.test.cjs
bash scripts/app.sh dart format --output=none --set-exit-if-changed lib test
bash scripts/app.sh analyze --no-pub
bash scripts/app.sh test --no-pub
bash scripts/app.sh build windows --release --no-pub
```

The first dependency resolution can report unavailable symlink privileges after
writing the plugin registry. The junction helper creates workspace-only plugin
links for each present Windows/Linux desktop project, then the second resolution
completes. Flutter prepares both projects even for a Windows build. No Developer Mode or ACL changes
are required. Dependencies are pinned in `pubspec.lock` and native input helpers.
The build wrapper scopes caches/environment to the workspace.
`windows/webview_windowed.cmake` compiles a scoped adaptation of the pinned
Windows plugin: ordinary browser windows do not initialize its unused texture
capture/compositor subsystem. A SHA-256 guard requires review if the dependency
source changes. It also mutes each WebView natively before navigation, covering
detached Audio and WebAudio. The app checks a read-only native mute boolean before
using a page; unsupported muting stops playback. It does not edit the package
cache or either feasibility probe.

The VK reader/action/diagnostic sources are snapshotted under `app/adapter/`.
The bundle script regenerates `assets/vk_adapter.js`; production builds do not
depend on either spike. The guarded readers include a music-only readiness check
for delayed track rows. Node's built-in test runner checks 48 guard/known-page fixtures with no npm
dependencies and no real account interaction.

For development with Flutter's runner (local data, no automatic consent):

```bash
bash scripts/app.sh run -d windows
```

Don't launch the real signed-in session from an agent sandbox. For automated
native/rendering tests, run only the isolated generated-data mode:

```bash
app/build/windows/x64/runner/Release/ownsemble.exe --smoke-test
```

It uses `.local/ownsemble-smoke`, 1,200 generated records and a generated tone,
then cold-restarts as `--smoke-resume`. Reports and a rendered screenshot are
written there. `--demo` uses its own `.local/ownsemble-demo` data. Neither mode
opens a browser or merges fixtures with the user's catalog.

`--browser-smoke` uses `.local/ownsemble-browser-smoke` and an isolated empty
WebView environment. It serves a generated loopback page/tone and tests two
hidden documents, trusted renderer input and request observation while the other
document progresses. It never connects to VK or authenticates. Its numeric
outcomes are written to `browser-smoke.json`; never inspect the runtime profile.

`--streaming-smoke` uses `.local/ownsemble-streaming-smoke`, generated AES
MP3-in-TS, and a deliberately delayed loopback source. It checks playback before
completion, seeking, shared fetching, complete validation, and local replay. It
never opens a browser or contacts VK. `tool/generate_preview.dart` reproduces the
checked-in generated preview MP3/TS; it does not read account audio.

Normal checkout data lives in `.local/ownsemble`, outside build outputs. A
standalone extracted bundle uses the platform application-support directory.
The browser session stays in a private WebView directory and is never exported.

## Automated follow-up after the normal-user launch

```bash
node scripts/app-control.cjs status
node scripts/app-control.cjs check
node scripts/app-control.cjs restart
```

Status exposes fixed categories/counts only. Check defers until connected and
idle, then prefers one uncached sample and checks the main player through
Play/Pause/Resume/Seek/Stop, complete cache and local replay. It does not claim full library coverage or genuine new-addition
detection. Restart uses only known Debug/Release outputs, selecting by Dart
payload timestamp. Commands accept a fixed action and fresh nonce only, with no
executable, URL, script, credentials or track input. Build the other output mode
while an app is running; the build command does not kill normal-session apps.

Playback preparation publishes its loading state before native work. The main
button becomes Stop while loading; row buttons show progress, and the selected
row toggles play/pause. Stop cancels the pending renderer/relay. Activated, failed or cancelled resolving pages close; unused muted
metadata-only documents can return to one standby slot. Progress updates do not re-query the whole
library; unchanged scan rows do not trigger repeated writes/rebuilds. Fixed-type
runtime outcomes are saved in `runtime-error.json`, with no raw exception text,
stack trace, track identifiers or temporary URLs. None of these controlled checks
substitutes for successful playback in the normal signed-in session.

See [implementation status](../docs/IMPLEMENTATION_STATUS.md) for completed
checks and remaining live acceptance work.

To make a local portable ZIP after a successful Release build, run `python scripts/package-app.py`. It includes only the executable, runtime DLLs and Flutter data; it excludes local catalog/cache/session files. The SHA-256 sidecar confirms byte equality of that archive, not safety or feature validation.

With explicit user authorization to test the real app, `--offline-check` starts
a fresh process with all provider scheduling disabled before startup. It verifies
the last accepted cached sample through the main player, writes only sanitized
`offline-check.json`, restores the queue and exits. It does not persist offline
mode, create a VK browser or add listening events. Do not run it concurrently
with the normal app. Generated smoke modes remain the default for agent tests.

Local packed MP3 HLS segments include a generated ID3 PRIV 90 kHz timestamp per
RFC 8216 section 3.4. Removing transport timestamps without replacing them made
seek appear to jump without resuming. Complete cache audio keeps its original
frames. Stop unloads native media before closing its relay; pausing is insufficient
when replacing a stream with a local file. Safe live check reports include phase,
elapsed time, received byte count and cancellation reason, never source URLs.

## Architecture and platform gates

See [architecture](../docs/ARCHITECTURE.md), [ADR0001](../docs/decisions/0001-platform-boundaries.md)
and [platform acceptance](../docs/PLATFORM_PORTABILITY.md). Construction lives in
`lib/bootstrap`; interfaces live in `lib/contracts`; native mechanisms live in
`lib/platform`. Shared provider policy has no transitive Flutter/native-IO dependency.
Run `bash scripts/app.sh dart tool/provider_contract_probe.dart` for its generated
VM probe; the same file runs with Linux Dart. This does not instantiate a Linux
browser or certify a Linux/Android release. Architecture/browser tests and native
browser/media acceptance are separate gates. Windows browser dependency/patch
remains pinned.

## Linux generated UI preview

A standard GTK host now lives in `linux/`. See [Linux proof](../docs/LINUX_PROOF.md)
for actual results, dependencies and limitations. From Git Bash, the prepared WSLg
preview opens with `bash scripts/start-linux-preview.sh release` at repository root.
On ordinary Linux, `bash scripts/linux-app.sh build release` stages an isolated
source-only workspace; `preview`, `smoke` and `streaming` run generated-data modes.
Live Linux VK and broader distribution packaging are still pending.
