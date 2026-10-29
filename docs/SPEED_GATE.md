# Flutter speed gate on Windows: results

Step 2 of the v2 plan, measured on 2026-10-29. The Flutter release build passes
every speed target, so no Tauri comparison is needed.

Machine: Windows 11 (26200), Ryzen 7 7840HS, Radeon 780M + RTX 4070 Laptop,
64 GB RAM, 165 Hz display, home connection. Flutter 3.47.7.

Library: 10,126 songs (126 synced from the test VK account + 10,000 generated
Russian/English songs). Tools: `app/tool/prepare_gate_data.dart` (data),
`app/tool/speed_gate.dart` (harness), `app/lib/bench/speed_bench.dart`
(in-app benchmark, playback muted).

## Results

| Target | Measured | Result |
|---|---|---|
| Cold start to usable list < 1 s | window visible with the full list at 336 - 405 ms (6 launches) | pass |
| Idle RAM about 150 MB | 97 - 99 MB working set, 123 - 125 MB private (10 s and 30 s idle) | pass |
| Search keystroke to results < 50 ms | 8.7 ms median, 12.4 ms max (56 keystrokes); SQLite query 0.6 ms median | pass |
| Scrolling 60 fps | 165 fps at 1,500 and 6,000 px/s; 65 fps at 20,000 px/s; 0 frames over the 16.7 ms budget | pass |
| Cached song to sound < 300 ms | 79 ms median, 188 ms max (6 plays, first play after start is the slowest) | pass |
| Streamed song: app overhead <= 300 ms over network first chunk | overhead 127 ms median, 163 ms max (10 random VK songs, 10/10 played) | pass |

Streamed songs, for context: click to sound 1,169 ms median (1,539 max) =
VK link request 274 ms median (`audio.getById`) + network first chunk 752 ms
median (DNS, TLS and server wait) + app overhead. Every play was confirmed by
the decoded sample rate (44.1 kHz) and the position still advancing after 1 s.

## How it is measured

- **Start:** the harness launches the release exe and polls (via Win32) for the
  app's visible window. The Flutter runner shows the window only after the first
  frame, and the app reads the whole library before that frame, so "visible" =
  "list usable". The OS file cache was warm (no reboot between launches).
- **RAM:** `Get-Process` working set and private bytes of an idle app with the
  player loaded and a VK token fetched. After the full benchmark (scrolling,
  16 plays) the app sat at 122 MB, peak 138 MB.
- **Search:** the benchmark types 8 queries one character at a time into the
  real search controller and times each keystroke until the engine reports the
  frame with the results rasterized. Both timestamps come from the same
  monotonic clock (checked: skew <= 0.4 ms). Keystrokes are set
  programmatically, so OS input latency is not included.
- **Scroll:** the list is moved every frame at a constant speed for 4 s; build
  and raster times come from the engine's frame timings.
- **Playback:** muted mpv (libmpv through media_kit), real WASAPI output.
  "Sound" is the first advance of mpv's playback position.

## Decisions made during the gate

- **Skia instead of Impeller on Windows.** With Impeller (OpenGL ES backend,
  the default in Flutter 3.47) the engine took about 1.2 s to initialize and
  the window appeared at 1.3 - 1.5 s. With Skia it appears at about 0.35 s.
  Skia also rendered at the display's 165 Hz, while Impeller was held at about
  66 fps. Set in `app/windows/runner/main.cpp`.
- **Streams go through a local proxy in the app** (`stream_proxy.dart`).
  Opening VK links directly in mpv cost 450 - 750 ms of overhead (mpv's own
  DNS and mbedtls handshake, and one play stalled for 20 s). Now the app
  fetches the audio itself and mpv reads it from `127.0.0.1`. This makes the
  network time measurable on the same request, puts timeouts under app
  control, keeps stream links out of mpv, its logs and the disk, and is the
  natural place to save the file to the cache while it plays.
- **Songs are loaded with mpv's `loadfile`**, not media_kit's `Player.open`,
  which writes the URI to a temporary playlist file.

## Not verified / known gaps

- True cold start after a reboot (cold OS file cache).
- Very fast flings (20,000 px/s) drop from 165 to about 65 fps on this
  display. That is still above the 60 fps target.
- Search matches word prefixes only ("tallica" does not find "Metallica").
- Cache-while-streaming is not built yet; the proxy only forwards.
- Android and Linux: nothing ran there yet.
- The test library has the same song twice, so 2 of the 3 cached files are
  identical.
