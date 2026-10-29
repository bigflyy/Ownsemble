# Flutter/Dart VK feasibility

Updated 2026-10-19. **Completed step 1 evidence.** The user authorized production implementation on 2026-10-19; see `IMPLEMENTATION_STATUS.md` and `../app/README.md`.

The isolated Flutter probe now passes the real Windows VK import/source/cache/
playback/seek/offline-restart sequence for one fresh sample. Its shared media,
storage and browser plumbing also passes synthetic Android emulator tests.
Actual Android VK access remains unverified.

## Current evidence

| Check | Result |
| --- | --- |
| Dart/Flutter tests | **31 passed**: policy, controls/restart selection, navigation/progress budgets, HLS tags/AES/IV/key rotation, MP3 frame preservation, TS/PES completeness/ambiguity, cache/hash/offline/SQLite and real native decoding/seek |
| Static analysis | Clean |
| Windows build | Debug and Release builds succeeded; current revision `ts_mp3_v1` |
| Windows private session | User signed in privately; My music confirmation and SPA/feed recovery work in the new host |
| Fresh Windows metadata | 256-entry bounded sample, `complete:false`, stop `sample_budget` |
| Native source activation | Exactly one approved source observed around the guarded track-control action |
| Fresh Windows real audio | Complete cookie-free download, strict full decode, local playback/seek: **9,381,093 bytes, 234.527 seconds** |
| Windows cold restart/offline | Passed at **2026-10-18T18:42:47Z**: hash/full-decode verification, local progression/seek, SQLite persistence |
| Windows Flutter listening | User confirmed **"yes works"** on 2026-10-19 after opening `Listen Offline.cmd` and using **Listen to cached sample** |
| Android APK | Built successfully using the scoped cached toolchain; no ACL/permission changes |
| Android synthetic runtime | Passed at **18:42:23Z** on isolated Android 15 x86_64 emulator5570: trusted WebView input/resource hook, AES HLS cache, native decode/play/seek, SQLite, zero offline HTTP requests and cold restart/offline seek |
| Android real VK | **Unverified**: synthetic browser/media checks do not establish real provider access |
| Physical-device audibility, Android background/media controls, production packaging | Outside this proof; unverified |

Windows SQLite retained 2,151 rows, including reference catalog and generated
fixtures. This is **not** a verified personal-library total. Scans merge without
deleting unseen entries. Full coverage, playlist membership, scheduled background
refresh and detection of a genuinely new account addition remain unverified.
The probe does not download the whole library.

The prior Electron/Python reference remains intact. The user confirmed audible,
correct songs there. Flutter's automated local-player checks are muted; the user
has now separately confirmed audible cached playback through `Listen Offline.cmd`.
Reference data was used in
earlier local tests, but the latest Windows result above used a fresh native
source/download and must not be confused with that reference copy.

## Reopening the cached sample

Double-click root `Listen Offline.cmd` from Windows Explorer to open the cached-audio window on the user desktop. Agent-launched GUI processes run on a hidden sandbox desktop and cannot be treated as visible.

The proof window's **Listen to cached sample** button plays local real audio.
Launch the Windows executable with `--offline` to open that window without
creating a browser or accessing a private session. It verifies the cache before
showing the offline success message. Disconnecting the internet is optional for
a manual listening check.

Fixed a repeat-launch bug: a completed checkpoint used to drop its sample ID.
Completed checkpoints now retain it; legacy ID-less checkpoints select an
existing real cache before generated fixtures. An explicitly missing sample
still fails. Regression coverage includes two consecutive complete native
offline verifications of the same generated encrypted-media cache.

## What changed in the media path

VK's tested source is AES-128 HLS containing MP3 inside MPEG-TS. The pinned native
decoder reported MP3 header errors on the original segmented representation.
Generated audio reproduced the failure; merely joining segments did not solve it.
The native library also lacks the output muxer needed by its recording feature.

The shared Dart cache now downloads the complete approved resources, handles
standard AES transport keys/explicit or sequence-derived IVs using pinned
`cryptography` 2.9.0, extracts one recognized MPEG-audio PES stream when necessary,
and removes segment ID3/Xing/Info/VBRI metadata. Complete encoded MP3 audio frames
are preserved byte-for-byte. It performs no re-encoding and needs no separate
Python helper or FFmpeg executable. Other supported audio keeps its native
transport path.

Malformed/truncated frames or PES data, multiple audio streams and unsupported
encryption/transport features fail explicitly. The normalized file must pass
strict full native decoding and duration checks before atomic publication.
Only then are generated transport files/keys removed and hashes committed.
Raw and TS-wrapped synthetic MP3 normalize to identical **64,783-byte, 4.048-second**
files; the Android cold-restart test verifies the latter.

Optional/unrecognized HLS tags are discarded rather than forwarded with unknown
URI attributes, following [RFC 8216 section 6.3.1](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.3.1).
Known unsupported ranged/partial/encrypted features still fail. Encryption uses
the package's [AES-CBC implementation](https://pub.dev/documentation/cryptography/latest/cryptography/AesCbc-class.html),
not a custom cipher. Framing is validated; the native library still decodes audio.

## Loading and adapter boundaries

The host handles SPA history updates and polls the current route as a fallback.
Feed/root recovery opens the fixed music URL once per visit; extraction requires
the guarded recognized music context and My music witness. Login forms are
rejected by presence without reading field values.

Waits use monotonic elapsed time, observed row/readiness/CDN progress, loading
state, backoff and hard caps. Progress extends the quiet window; a stuck loader
cannot extend the overall budget indefinitely. Navigation allows up to 90 seconds,
initial rows up to 120, metadata up to three minutes with a roughly 250-row sample
threshold, and source capture up to 90 seconds per bounded attempt. An alternate
track may be tried after a transient source timeout; ambiguous sources stop.
Limits produce explicit partial/stopped results, never a claimed complete library.

VK-specific selectors and semantic fallbacks remain in one guarded JavaScript
adapter. Storage, cache, playback and future library organization do not depend
on that hierarchy. These boundaries reduce maintenance; they cannot make VK
updates harmless or establish Android provider compatibility by themselves.

## Restarting and reproducing

App-owned Windows restarts were verified repeatedly without user relaunches:

```bash
node spikes/vk-flutter/control.cjs status
node spikes/vk-flutter/control.cjs restart
```

The nonce-only bridge accepts fixed run/selftest/stop/restart actions and no
executable, arguments, script, URL or track input. The running app waits until
not busy, chooses only this checkout's known Debug/Release outputs by their Dart
payload timestamps, closes its own browser and starts with fixed arguments.
A fully closed app still needs the normal-user `Restart Flutter VK Test.cmd`.
Agent tools must not invoke that external private-session launcher.

Run from repository-root Git Bash:

```bash
bash scripts/flutter-proof.sh test --no-pub
bash scripts/flutter-proof.sh analyze --no-pub
bash scripts/flutter-proof.sh build windows --release --no-pub
bash scripts/flutter-proof.sh build apk --debug --no-pub --dart-define=PROOF_AUTORUN=true
python scripts/flutter-android-proof.py install
python scripts/flutter-android-proof.py fresh-start
python scripts/flutter-android-proof.py wait
```

Build the other Windows mode when preserving a running probe. Android helpers
target only emulator5570 and the Ownsemble test package. Fresh-start resets only
its public test checkpoint; it avoids mistaking a resumed older offline result
for new coverage. Successful checks need not be repeated without a relevant change.

Sanitized reports are `.local/flutter-proof/status.json`, `evidence.json` and
`android-evidence.json`. They contain counts/categories, not raw native messages,
credentials, cookies or temporary source URLs. Dedicated browser profiles remain
denied to agent access. No account/library mutations or production work were done.
