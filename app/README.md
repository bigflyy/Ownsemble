# Ownsemble app

Flutter app (Windows first). Run commands from this folder.

Test data folders (both use the separate test VK account):

- `../.local/v2-test/feel`: only the test account's songs. The acceptance test
  copies it.
- `../.local/v2-test/gate`: the same plus 10,000 generated filler songs (made-up
  names, borrowed audio), for speed measurements only.

```sh
flutter test
flutter build windows --release

# Sync the test VK account into a data folder and cache 3 songs as local
# files; --songs adds that many generated filler songs (0 for feel).
dart run tool/prepare_gate_data.dart --data-dir ../.local/v2-test/feel \
    --vk-session ../.local/v2-test/session.json --songs 0

# Acceptance test before every handover: the real app on a fresh copy of the
# test library (feel-acceptance, with one made-up song the sync must mark
# gone), muted, in an off-screen window that never takes focus (about 3 min).
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/acceptance_test.dart \
    -d windows --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
    --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json

# Login check: the real app logged out on an empty folder (feel-login, replaced
# on every run), the real login window off-screen, real VK. The agent never types into a login page, so
# the test account's cookies are put into the window (--vk-login-seed);
# everything after that is the real path. Writes a picture of the page.
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/login_test.dart \
    -d windows --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
    --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json \
    --dart-define=OWNSEMBLE_SHOT=<absolute path>/login-page.png

# Several accounts check: an empty folder (<data dir>-accounts, replaced on every
# run), two real accounts logged in through the real window off-screen, one
# library. The second account's session is only read; prints counts, no titles.
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/accounts_test.dart \
    -d windows --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/accounts \
    --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json \
    --dart-define=OWNSEMBLE_SESSION_2=<absolute path>/.local/v2-test/session-2.json

# Search VK check (TEST ACCOUNT ONLY: adds one song and removes it again):
# the real app on a copy of the library (<data dir>-catalog, replaced on
# every run), off-screen and muted. Types a Cyrillic query, waits for the On
# VK part, plays a found song (stream, decoded), adds it with +, syncs (one
# row), then deletes it on VK, marks it removed and syncs back to the start.
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/catalog_test.dart \
    -d windows --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
    --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json

# Check the "gone from VK" rule against real VK on a copy of a library (the
# folder itself is not written).
dart run tool/check_gone_marks.dart --data-dir ../.local/v2-test/feel \
    --vk-session ../.local/v2-test/session.json

# Speed gate against the release build (playback muted). Run it with
# OWNSEMBLE_BACKGROUND_WINDOW=1 unless a window on screen is wanted. It also
# restarts the real app: saved volume, window size and place, real Windows key
# messages (Right, Up, Space), and the last song across a real window close.
# --only-restart runs just those checks, about 1 min.
dart run tool/speed_gate.dart --data-dir ../.local/v2-test/gate \
    --vk-session ../.local/v2-test/session.json

# Closes the release through its window many times while a song plays and
# counts the exit codes: only 0 is a clean close. Works on any test folder.
dart run tool/close_check.dart --exe build/windows/x64/runner/Release/ownsemble.exe \
    --data-dir ../.local/v2-test/close-check-old --runs 20
```

The Windows icon (`windows/runner/resources/app_icon.ico`) is drawn by
`dart run tool/make_icon.dart` from the "Overlap" design (add `--png-dir DIR`
to also get each size as a PNG file).

Screenshots of the main window with made-up songs (real fonts, dark, light,
bottom bar, narrow), to check the look without opening the app:
`flutter test tool/screenshots_test.dart --dart-define=OWNSEMBLE_SHOTS=<folder>`.

Acceptance test switches (add as `--dart-define`): `OWNSEMBLE_QUICK=true` plays
only 15 songs (for iterating, never for a handover), `OWNSEMBLE_MPV_LOG=true`
writes mpv.log into the copied data folder.

Without options the app keeps everything in `%APPDATA%\Ownsemble\v2` and logs
in through its own window; the session is `session.dpapi`, encrypted by Windows
for this Windows user. Agent checks always pass `--data-dir` and `--vk-session`.

App options: `--data-dir DIR`, `--vk-session FILE` (the test account's session
file, instead of the login window), `--vk-login-seed FILE` (login check only),
`--muted`,
`--metrics FILE` (startup timings), `--bench FILE [--bench-parts a,b]
[--bench-volume N]` (parts: search, scroll, scrollCovers, playCached,
playStream, seekStream; volume under mute, default 100, never saved),
`--mpv name=value` (mpv option override), `--mpv-log` (mpv log without links),
`--no-stream-cache` (do not save streamed songs; the speed gate uses it).
Bench parts `saveVolume`, `savedVolume`, `playToCloseCached`, `playToCloseStream`,
`savedSong` and `keysProbe` run only when named: the speed gate uses them for its
checks across a real restart.

Between runs the app keeps its settings in the library's `settings` table
(`ui.*`, `player.*`: theme, layout, view, volume, shuffle, repeat, the last song
with its position, list and queue) and the window's size and place in
`window-placement.txt` in the data folder. A restored song is not loaded until
Play, so a start costs no network. A close saves, then ends the process at once
(`lib/platform/end_process.dart`): the engine's own shutdown crashes or hangs
while mpv runs.
