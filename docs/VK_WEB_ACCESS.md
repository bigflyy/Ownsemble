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
   direct stream `url` (plain MP3 on an `okcdn.ru` host). About 1 link in 160
   is an HLS playlist instead: the path ends in `.m3u8`, the reply is `206`,
   `application/vnd.apple.mpegurl`, 1.3-1.7 KB, about every second segment
   AES-128 encrypted. Which song gets one looks random (3 of 492 links, 3
   different songs in 4 passes over the library). A new `audio.getById` gave the
   MP3 15 times of 15, so the app asks again instead of playing the playlist.

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

## Session

The login page's session is the `.vk.ru` cookie `remixsid` plus the rest of the
web client's cookies; `act=web_token` tells whether VK takes them. A dead session
answers with a type other than `okay`. Access keys change more often than daily
(seen twice within an hour), which makes a sync report every song as updated.

## Rules the real sync must follow

- **Paged replies omit blocked tracks but still count them in the offset.**
  With `count=50`, pages returned 48, 50 and 25 items; the 3 missing were
  exactly the 3 tracks without a URL. Advance the offset by the requested page
  size, never by the number of items received, and stop at the declared count.
- **A track missing from a page may be blocked, not removed.** Before marking a
  track "gone from VK", check it with `audio.getById`.
- Stream URLs expire; resolve a fresh one with `audio.getById` at play time
  instead of re-syncing.

## Cover images (test account, 2026-10-30)

A cover comes in seven sizes, `photo_34` to `photo_1200`, and each size has its
own signed link. Two faults, both seen on the same 3 of 108 covers:

- **One size is missing.** A single size answers 404 or 424 every time while the
  others answer 200, so a client needs more than one size to try.
- **The image is only on some hosts.** The host in a link changes with every
  request, and not every host has every image: in about 1 sync in 4 all sizes of
  those 3 images failed, and the next sync's links worked. A link that failed once
  is worth replacing, so store the newest link.

## Album titles (test account, 2026-11-02)

A song's `album` object has three shapes in the 126 test songs: a real title (92),
the word "unnamed" (16), and an empty title (3, the withdrawn songs). 15 songs have
no `album` object at all: user uploads with nothing to show.

- **"unnamed" is not a name.** Those albums are real and have real covers.
  `audio.getPlaylistById` with the object's `owner_id`, `id` and `access_key` gave
  the true title for 16 of 16, in 236-326 ms each. A batched `audio.getById` on the
  songs' `release_audio_id` keys says "unnamed" again, so it takes one call per
  album. The app stores each title once, by `owner_id` + `id`.
- **Pace.** 300 calls with 150 ms between them took 131 s and hit no rate limit. 7
  calls failed, all with errors 100 and 15 (refused, not limited): among the 88
  albums of the test library a few cannot be read at all.

## Answers that are not the song (test account, 2026-10-30)

`206` for `Range: bytes=0-` is normal: 305 of 738 whole-file answers were 206 with
the full file. Two kinds of bad answer on songs that play a moment later: a single
504 (1 of 738; the same link then answered at once) and a 206 of 1.7 KB followed
by the end of the connection (twice in about 300 plays; not caught by the probe).

## Songs that do not play (test account, 2026-10-30)

123 of 126 songs have a link. All but one of those answer with audio.

- **No link, withdrawn (3 songs).** `content_restricted: 1`, `is_licensed:
  false`, empty `url`, no `release_audio_id`. `audio.getRestrictionPopup`
  (`audio_id` = `owner_id`_`id`) gives VK's reason: "Аудиозапись недоступна. Так
  решил музыкант или его представитель." Nothing to fix; the app says so.
- **Link, but the file is broken (1 song).** The copy's audio server answers
  504 with an HTML page in about 0.4 s, not a real gateway timeout: every try
  since at least 2026-10-29, with fresh links, with or without Range, a browser
  User-Agent, Referer and Origin. Other copies of the same recording play.
- **`track_id` names the recording and `release_audio_id` its official
  release.** Each copy in a library is its own file (`file_id` differs), and
  the release can be requested with `audio.getById` with no access key. The
  app uses it only after the copy's audio server fails, and only if the
  release has the same `track_id`.
- The catalog has licensed songs with the same artist and title as all 3
  withdrawn ones, but with a different `track_id`, and for 2 of them a
  different length (223 s vs 194 s, 212 s vs 199 s), so they are not known
  to be the same recording. The app does not substitute them.

## One song in two accounts (2026-11-03)

Measured with `tool/probe_duplicate_layers.dart`.

- An account's list holds its own copy: the same song never had the same
  `owner_id` + `id` in two accounts.
- `track_id` finds nearly all shared songs, but it is not proof by itself: about
  15% of the groups sharing one disagree on the title or the length. Some are one
  recording labeled differently, others clearly are not the same song.
- `release_audio_id` has the same faults and finds nothing more.
- The same artist and title with another length is often another cut.

So two songs count as one when they have the same `track_id` and lengths within
2 s, or the same text and exact length if they do not both have a `track_id`.
A wrong merge hides a song and a missed one only shows it twice, so doubtful
cases stay apart.

## Not yet verified

- The maximum page size.
- How long the session cookies keep producing tokens, and how VK reacts to
  frequent syncs.
- Startup latency with the real player (libmpv) and connection reuse: step 2.
- Android: the same HTTP calls should work, but nothing ran there yet.
