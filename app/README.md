# Ownsemble app

Flutter app (Windows first). Run commands from this folder.

Test data folders (both use the separate test VK account):

- `../.local/v2-test/feel`: only the test account's songs. The installed
  shortcut and the acceptance test use it.
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
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test -d windows \
    --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
    --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json

# Check the "gone from VK" rule against real VK on a copy of a library (the
# folder itself is not written).
dart run tool/check_gone_marks.dart --data-dir ../.local/v2-test/feel \
    --vk-session ../.local/v2-test/session.json

# Speed gate against the release build (playback muted).
dart run tool/speed_gate.dart --data-dir ../.local/v2-test/gate \
    --vk-session ../.local/v2-test/session.json
```

Acceptance test switches (add as `--dart-define`): `OWNSEMBLE_QUICK=true` plays
only 15 songs (for iterating, never for a handover), `OWNSEMBLE_MPV_LOG=true`
writes mpv.log into the copied data folder.

App options: `--data-dir DIR`, `--vk-session FILE`, `--muted`,
`--metrics FILE` (startup timings), `--bench FILE [--bench-parts a,b]`
(parts: search, scroll, playCached, playStream, seekStream),
`--mpv name=value` (mpv option override), `--mpv-log` (mpv log without links),
`--no-stream-cache` (do not save streamed songs; the speed gate uses it).
