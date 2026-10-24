# Opaque VK audio endpoints

The Windows investigation on 2026-10-23 found exact music-row URLs on HTTPS
`okcdn.ru` endpoints without `.mp3` or `.m3u8` filenames. The older destination
and filename rules rejected those rows, forcing browser activation. A browser
activation could time out or return an older source whose transfer was rejected;
the native relay then hid the cause behind `decoder_open_failed`.

The shared provider now accepts that fixed CDN suffix with the same HTTPS,
authority, port, redirect and exact-recording checks as existing media CDNs.
Lookalike domains remain rejected. URL query values are neither interpreted as
format hints nor exported. The player relay inspects at most 64 initial response
bytes to distinguish an opaque HLS manifest from progressive audio. It shares
that transfer with complete-cache publication; format detection does not require
the entire progressive file. Conventional filename behavior remains unchanged.
The cache reuses classification bytes and still requires full decode, recording
duration and identity receipt before publishing an offline asset. Existing data
and legacy verification requirements remain intact.

Tests first reproduced rejection of the new authority, unsupported opaque cache
publication and incorrect HLS routing. A subsequent regression reproduced a
duplicate manifest fetch before its removal. Generated tests cover HTTPS/host
boundaries, progressive delivery while the response tail is held, opaque HLS,
offline integrity verification and shared request counts. Final validation:
222 Flutter tests, 65 adapter tests and clean analysis; Windows Debug and Release
builds; native generated browser/privacy and encrypted streaming/cache/seek/offline
checks passed. The generated streaming check still records its existing nonfatal
decoder signal 4096 while strict complete decoding passes.
The generated 1,200-row catalog, SQLite integrity and cold-restart check also passed.

Live app-owned controls tested five uncached samples, without inspecting titles,
recording IDs, audio contents, private browser storage or temporary URLs:

| Sample | First native playback | Source resolution |
| --- | ---: | ---: |
| First uncached after restart | 15,210 ms | 8,059 ms |
| Deep library | 10,522 ms | 1,933 ms |
| Tenth from old end | 3,613 ms | 2,108 ms |
| Hundredth from old end | 5,121 ms | 3,096 ms |
| 250th from old end | 3,983 ms | 2,140 ms |

All bound their exact row metadata and reached cache publication. The first
sample was already playing with 64 KB received while its 7.3 MB download was
incomplete. The hundredth-old sample continued playing while its download was
still incomplete at 27 seconds. A subsequent real-player check passed pause,
resume, seek, stop and local-cache reopening with zero new upstream bytes.
After a fresh final Release restart, the 250th-old saved sample passed those same
controls with local playback starting in 483 ms, no relay and no upstream bytes.
A separate selected recording returned `audio_restricted`; the player failed
closed rather than substituting a different recording.

These samples establish the repaired path, not availability of every recording
or physical sound quality on every device. Cold startup and variable CDN latency
remain performance work. Complete VK membership reconciliation and ordinary
Linux desktop audio acceptance remain separate gates; WSL stays stopped.
