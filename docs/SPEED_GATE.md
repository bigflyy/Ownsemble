# Flutter speed gate on Windows: results

Step 2 of the v2 plan, measured on 2026-10-29. The Flutter release build meets
the speed targets (one streamed play of ten was 27 ms over, see below), so no
Tauri comparison is needed.

The first handover was broken: in the installed app no song played and Ctrl+F
did nothing, although every measurement had passed. The benchmark called the
player directly from the build folder and never used the real window. See
"Fixed after the first handover"; the second run below is on the installed
build, and its UI was checked with real mouse and keyboard input.

Machine: Windows 11 (26200), Ryzen 7 7840HS, Radeon 780M + RTX 4070 Laptop,
64 GB RAM, 165 Hz display, home connection. Flutter 3.47.7.

Library: 10,126 songs (126 synced from the test VK account + 10,000 generated
Russian/English songs). Tools: `app/tool/prepare_gate_data.dart` (data),
`app/tool/speed_gate.dart` (harness), `app/lib/bench/speed_bench.dart`
(in-app benchmark, playback muted).

## Results

Second run (installed build, after the fixes). First run in brackets.

| Target | Measured | Result |
|---|---|---|
| Cold start to usable list < 1 s | window visible with the full list at 324 - 381 ms, 6 launches (336 - 405) | pass |
| Idle RAM about 150 MB | 100 - 102 MB working set, 126 - 128 MB private (97 - 99) | pass |
| Search keystroke to results < 50 ms | 17.3 ms median, 22.5 ms max over 56 keystrokes; the substring search itself 1.7 ms (8.7 / 12.4) | pass |
| Scrolling 60 fps | 65 fps at all three speeds, 0 frames over the 16.7 ms budget (165 fps at normal speeds) | pass |
| Cached song to sound < 300 ms | 51 ms median, 78 ms max, 6 plays (79 / 188) | pass |
| Streamed song: app overhead <= 300 ms over network first chunk | 145 ms median; 9 of 10 under 300 ms, one at 327 ms; 10/10 played (127 / 163) | 1 of 10 over |

Streamed songs, for context: click to sound 1,377 ms median = VK link request
294 ms (`audio.getById`) + network first chunk 920 ms (DNS, TLS and server
wait) + app overhead. Every play was confirmed by the decoded sample rate
(44.1 kHz) and the position still advancing after 1 s.

The drop from 165 to 65 fps between the runs is not explained yet. Windows
reported the display at 143 Hz during the second run, so the display mode may
have changed; the higher search latency matches the slower frame pacing.

## Real UI check (installed app, muted, real OS input)

Mouse clicks, key presses with hardware scan codes and typed Unicode
characters were sent to the installed app, with a screenshot after each step:
click a generated song (cached file) and two VK songs (streamed) - all played;
Ctrl+F after clicking a song focuses search; typed Cyrillic text arrives intact
also at 10 ms per character; substring results ("очь" -> 523 songs, "дожд" ->
544); Enter plays the first result; Esc clears the search; the pause button
pauses.

## Fixed after the first handover

- Cached-file paths were stored relative to the folder the data tool ran in,
  so the installed app found no cached file and waited 20 s per click. They
  are now relative to the data folder; a missing file fails at once (VK songs
  stream instead) and mpv errors end the wait.
- Shortcuts only worked while focus was inside the screen, and Ctrl+F matched
  the letter F, which the Russian layout does not produce. They are now
  handled at the keyboard level and match the physical key.
- Switching songs reported 0 - 31 ms to sound: a position from the previous
  song was counted. Positions larger than the time since the click are now
  ignored.
- Search matched word starts only; it now matches inside words.

## How it is measured

- **Start:** the harness launches the release exe and polls (via Win32) for the
  app's visible window. The Flutter runner shows the window only after the first
  frame, and the app reads the whole library before that frame, so "visible" =
  "list usable". The OS file cache was warm (no reboot between launches).
- **RAM:** `Get-Process` working set and private bytes of an idle app with the
  player loaded and a VK token fetched. After the full benchmark (scrolling,
  16 plays) the app sat at 122 MB, peak 138 MB.
- **Search:** the benchmark sets 8 queries one character at a time on the
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
- Why the second run scrolled at 65 fps instead of 165 fps.
- One streamed play's overhead was 327 ms (target 300 ms).
- Cache-while-streaming is not built yet; the proxy only forwards.
- Android and Linux: nothing ran there yet.
- The test library has the same song twice, so 2 of the 3 cached files are
  identical.
