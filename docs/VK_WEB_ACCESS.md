# VK web access: experiment results

Step 1 of the v2 plan. Measured on 2026-10-29 against the separate test account
(126 tracks), on Windows over a home connection. Tools: `experiments/vk-web/`
(one-time login and request discovery) and `experiments/vk-probe/` (Dart probe).

## How it works

VK moved to `vk.ru`; `vk.com` redirects there and the session cookies live on
`.vk.ru`. After one login in a browser window, no browser is needed:

1. `POST https://login.vk.ru/?act=web_token` with the session cookies and
   `app_id=6287487` (VK's public web client) returns a web API token, its expiry
   (about 15 minutes) and the user id.
2. `POST https://web.api.vk.ru/method/<method>?v=5.289&client_id=6287487` with
   `access_token` in the form body calls the web API.
3. Useful methods:
   - `audio.get` (owner_id, count, offset): the library, newest first.
   - `audio.getById` (audios=`owner_id`_`id`_`access_key`): fresh stream URL
     for one track.
   - `audio.search` (q, count): VK catalog search.
   - `catalog.getAudio`: what the web music page itself loads.
4. A track carries artist, title, duration, date added, album with covers up to
   1200 px, `has_lyrics`, `is_explicit`, `access_key`, `track_code` and a
   direct stream `url` (plain MP3 on an `okcdn.ru` host, not HLS).

## Measurements

| Check | Result |
|---|---|
| Token from session | OK, 0.9 s |
| Full sync, one request | 126/126 tracks, 2.0 s; 3 tracks have no URL (blocked) |
| Playback, 20 random tracks | 20/20 decoded real audio (ffmpeg, no sound output) |
| Network first bytes | 0.74 - 1.01 s per new connection |
| ffmpeg first decoded audio | 1.5 - 2.6 s (new process and connection per track; not the app's player) |
| `audio.getById`, 5 tracks | 5/5 fresh URL, 0.25 - 0.28 s |
| `audio.search` | "кино", "kino", "metallica": 20/20 playable each, 0.74 - 1.5 s |

## Rules the real sync must follow

- **Paged replies omit blocked tracks but still count them in the offset.**
  With `count=50`, pages returned 48, 50 and 25 items; the 3 missing were
  exactly the 3 tracks without a URL. Advance the offset by the requested page
  size, never by the number of items received, and stop at the declared count.
- **A track missing from a page may be blocked, not removed.** Before marking a
  track "gone from VK", check it with `audio.getById`.
- Stream URLs expire; resolve a fresh one with `audio.getById` at play time
  instead of re-syncing.

## Not yet verified

- Libraries larger than one page of 200, and the maximum page size.
- How long the session cookies keep producing tokens, and how VK reacts to
  frequent syncs.
- Startup latency with the real player (libmpv) and connection reuse: step 2.
- Android: the same HTTP calls should work, but nothing ran there yet.
