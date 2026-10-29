# Ownsemble app

Flutter app (Windows first). Run commands from this folder; the data folder
for agent checks is `../.local/v2-test/gate`.

```sh
flutter test
flutter build windows --release

# Data for the speed gate: sync the test VK account, cache 3 songs as local
# files, add 10,000 generated songs.
dart run tool/prepare_gate_data.dart --data-dir ../.local/v2-test/gate \
    --vk-session ../.local/v2-test/session.json

# Speed gate against the release build (playback muted).
dart run tool/speed_gate.dart --data-dir ../.local/v2-test/gate \
    --vk-session ../.local/v2-test/session.json
```

# Acceptance test before every handover: the real app on the test library,
# muted, in an off-screen window that never takes focus (~3 min).
OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test -d windows     --dart-define=OWNSEMBLE_DATA=<abs path>/.local/v2-test/feel     --dart-define=OWNSEMBLE_SESSION=<abs path>/.local/v2-test/session.json
```

Data folders: `feel` holds only the test account's songs (the user's
shortcut uses it); `gate` adds 10,000 generated filler songs for speed
measurements only.

App options: `--data-dir DIR`, `--vk-session FILE`, `--muted`,
`--metrics FILE` (startup timings), `--bench FILE [--bench-parts a,b]`,
`--mpv name=value` (mpv option override), `--mpv-log` (mpv log without links).
