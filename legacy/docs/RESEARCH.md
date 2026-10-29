# Ownsemble research

Research date: 2026-10-16. Scope: existing products, VK integration, useful library views, and a Windows-to-Android architecture.

Update 2026-10-18: real VK metadata/download/offline checks passed in the Electron reference probe; see [current evidence](VK_FEASIBILITY.md). The user subsequently prioritized Android portability and authorized a separate [Flutter/Dart feasibility probe](VK_FLUTTER_FEASIBILITY.md). The [MVP proposal](MVP.md) follows that direction, subject to its runtime gates. Production implementation has not started.

## Findings

Murglar is the closest overall match found: it already advertises multiple providers, Windows and Android, offline caching, and downloads. The combination worth investigating further is a personal library with repeatable additions to Piles and independent listening views. This search did not establish an exact match for that behavior; it is not an exhaustive market survey.

These are documentation and source-code findings. No candidate application was installed, and no authenticated VK listing, playback, or download was tested.

## Existing products

| Product | Relevant published functionality | Fit for Ownsemble |
| --- | --- | --- |
| [Murglar](https://murglar.app/docs/en/en-index.html) | Windows and Android, VK and other providers, unified library, cross-service search, offline library/playback, downloads, and list export. Some features require supporting the project. | Closest overall product reference. Its public feature list does not establish Piles with repeated additions and occurrence-specific deletion. |
| [muffon](https://github.com/staniel359/muffon) | Multiple sources including VK, cross-source search, library, playlists, history, and offline listening; Windows supported. Its README separately says it has no download feature. | Broad open-source reference. Offline listening should not be interpreted as exportable files. Its stated features do not establish Piles or their deletion semantics. |
| [Music M](https://github.com/Werhes/Music-M) | VK player for Windows using WinUI 3; search, track downloads, playlist generation, multiple accounts. | Relevant VK playback/download reference. Its source tree includes specialized audio-access code; this is not evidence that a generic VK login provides music access. |
| [Meridius](https://github.com/PurpleHorrorRus/Meridius) | VK desktop player with music and playlist search, Windows and Linux support. | Useful product/UI reference. The inspected repository does not provide enough application source to treat it as a ready foundation. |
| [KissVK](https://kissvk.com/index.html) | Says it offers VK sign-in, a user's audio list, search, and downloads. Its access instructions discuss public audio visibility. | Confirms a similar user-facing workflow is offered. Download success and account compatibility remain untested here. |
| [Strawberry](https://www.strawberrymusicplayer.org/) | Local music collection management, playlist formats, smart and dynamic playlists, metadata editing. | Reference for organizing files you control; the published feature list does not establish a VK integration. |

Recommendation: use these as references before deciding to fork. Music M's Windows-specific UI and muffon's desktop client plus [separate REST backend](https://github.com/staniel359/muffon-api) would need substantial evaluation for this scope. Their existence alone does not establish the fastest implementation route.

## What Murglar changes

Its [FAQ](https://murglar.app/docs/en/en-faq.html) explicitly describes cache-size limits with least-recently-played eviction. It distinguishes app-managed cache from downloads to a user-selected directory; downloaded files are not reused as cache. The same FAQ currently lists creating/editing playlists among future features. Permanent pins and Pile semantics were not verified.

The main app is the closed solution identified by the user; the public [plugin SDK](https://github.com/badmannersteam/murglar-plugins) and [sample](https://github.com/badmannersteam/murglar-plugin-sample) expose service/source extension contracts. They do not establish access to Murglar's built-in VK adapter or arbitrary changes to its main UI and library behavior.

**Practical recommendation:** evaluate Murglar as an existing solution before investing heavily. If its actual behavior meets the need, using it is the fastest result. If independent ownership and Piles remain unmet, build Ownsemble around those differences. A Murglar plugin is an option to investigate, not a proven shortcut for implementing those changes.

## How KissVK appears to work

Its [public JavaScript bundle](https://kissvk.com/scripts/main.min.ver_260809072917.js), fetched during research, contains a VK OAuth authorization URL and calls to KissVK-owned song-list and download endpoints. I did not invoke those authenticated endpoints.

Inference: the browser handles authorization and presentation while KissVK's server participates in supplying song and download data. The public frontend does not reveal the complete VK-access mechanism behind its server. We cannot claim to reproduce its implementation from the homepage, or treat its private endpoints as a supported integration API.

## A concrete VK implementation reference

[VKpyMusic](https://github.com/issamansur/vkpymusic/blob/main/README_EN.md) documents listing user tracks, searching, playlists, and local downloads. Its [service implementation](https://github.com/issamansur/vkpymusic/blob/main/vkpymusic/service.py) handles both direct audio URLs and HLS playlists when saving music.

Its authentication is an important qualification: the documented token receiver uses login/password, and its [client definitions](https://github.com/issamansur/vkpymusic/blob/main/vkpymusic/client.py) contain identifiers for existing mobile clients. This is a third-party implementation reference, not proof of a supported Ownsemble authentication flow or current account compatibility.

First investigate a VK-owned sign-in flow. Verify that the resulting authorization actually permits music listing and audio retrieval; ordinary identity login is not sufficient evidence. A standalone account test should settle the provider route before choosing dependencies around it. Keep credentials out of chat and logs.

## Useful song views

[Navidrome's smart-playlist documentation](https://www.navidrome.org/docs/usage/smartplaylists/) demonstrates filters using last-played time, play count, date added, favorites, and other metadata. Based on those capabilities and this product's needs, proposed Ownsemble views are:

| View | Definition | Priority |
| --- | --- | --- |
| All music / VK | Unique library tracks, optionally filtered by provider. | MVP |
| Available offline | Tracks with complete, readable local audio. | MVP |
| Recently played | Unique tracks ordered by latest playback. | MVP |
| Piles | Repeated additions retained as individual entries. | MVP, minimal version |
| Most played | Qualified plays over 7 days, 30 days, or all time. | Next |
| Recently added again | Addition events, including repeated tracks. | Next |
| Rediscover | Previously played tracks absent from recent listening. | Later |
| Unplayed / favorites / unavailable | New discoveries, explicit favorites, or broken provider references. | Later |

These are product recommendations, not claims that every referenced app implements all of them.

## Technology recommendation

The judgments below are architectural estimates, not measured performance comparisons.

| Option | Windows MVP | Android path | Main tradeoff |
| --- | --- | --- | --- |
| Flutter + Dart + SQLite | Shared UI and domain logic; audio backend requires validation. | Same framework and much of the same code. | New SDK setup; desktop audio/auth plugins need a practical spike. |
| Tauri 2 + React + Rust + SQLite | Web UI with native storage/backend. | Shared UI/core with mobile plugins. | Background audio and native media integration require deliberate platform work. |
| Electron + React + SQLite | Likely shortest initial setup here because Node/npm are already available. | Requires an additional mobile shell or UI adaptation. | Bundles Chromium and Node; desktop packaging does not carry over to Android. |

Both [Flutter](https://docs.flutter.dev/reference/supported-platforms) and [Tauri 2](https://v2.tauri.app/start/) support Windows and Android. Tauri uses [system webviews](https://v2.tauri.app/reference/webview-versions/); [Electron](https://www.electronjs.org/docs/latest/) embeds its own runtime and targets desktop platforms.

**Provisional recommendation: Flutter + SQLite if Android remains a real goal.** Use [Drift](https://drift.simonbinder.eu/platforms/) for shared database access. Evaluate [just_audio](https://pub.dev/packages/just_audio) with a Windows backend, or [media_kit](https://pub.dev/packages/media_kit) with its audio-only libraries. The [WinRT just_audio backend](https://pub.dev/packages/just_audio_windows) lists HLS and file playback but lacks request-header support, which could affect provider playback. [audio_service](https://pub.dev/packages/audio_service) supplies Android background/media controls; Windows system controls require separate evaluation.

Choose the audio backend using actual VK direct/HLS streams and cached files. Do not ship a Python helper solely because the research reference is Python. Flutter/Dart and Rust were not found on the current shell PATH, so toolchain setup must be included in implementation planning.

## Decision before implementation

Confirm the VK account-to-audio route first. Then implement the small product described in [MVP.md](MVP.md), with a polished UI and real offline verification. Spotify/YouTube capability and download behavior must be researched independently when those providers enter scope.
