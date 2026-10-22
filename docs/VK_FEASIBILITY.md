# VK feasibility evidence

Status: **real VK download, complete decoding, cached playback/seek and a network-blocked restart have passed automatically; the user also confirms audible cached playback and correct songs**. Personal My music navigation is verified; 2,147 entries are retained from confirmed personal-page runs; the exact provider total remains unknown. Earlier general-view entries are not proof of the account library. Full personal coverage and automatic addition detection remain unverified.

## Latest bounded run (2026-10-18)

The user reports 1,000+ songs. The initial short waits stopped early. Loading now observes music ID changes, adapts to arrival times, waits through reported loading and retries stalled scrolling. Full scans require at least a minute without new entries before a quiet stop and have a five-minute feasibility budget. A budget or quiet stop never claims completeness.

At `09:25:24Z`, the metadata-only scan observed 2,102 entries over 109 viewports and retained 2,108 after merging earlier personal-page rows. It stopped at the time budget with `complete: false`. A subsequent two-viewport incremental refresh observed 2,141 entries and retained **2,147**, including 39 new-to-local rows while preserving all previous entries. This proves live incremental discovery of previously unseen rows; it does not establish that those songs had just been added to the VK account. The diagnostic flag `providerAdditionObserved` has this narrower new-to-local meaning. Normal scheduled background refresh and actual account-addition detection remain unverified.

Existing cached samples were reused. Online and offline decoding/hash/playback/seek passed again at `09:25:33Z`. No VK account changes were made. Core playback/cache feasibility and large paginated metadata discovery are demonstrated for this session; exact catalog coverage remains open.

## Automated checks and corrected music view (2026-10-18)

After being asked to play cached audio in Ownsemble's main window, which had been left in offline mode, the user reported: "works audible correct songs". This closes the listening and song-identity checks for the tested cached songs. It is user-reported evidence, separate from the muted automated test; it does not verify the entire catalog.

The user requested tests without repeated manual actions and launched `npm run proof:auto` once. Live evidence confirms bounded test attempts, command-file stop handling, and automatic app restart/retry after source edits. The restricted bridge admits only `run`/`stop` with a nonce, with sanitized status in `.local/vk-proof/automation-status.json`. It accepts no JavaScript, URLs, credentials, track IDs or input coordinates. No general debug port or agent access to the retained browser profile was added.

The runner tries up to three personal tracks. For the first successful audio asset it performs complete decoding and hash verification, muted browser playback/time progression and seek/resume, then automatically relaunches with remote requests blocked and repeats local verification and browser playback/seek. At `2026-10-18T08:35:49Z`, these online and offline checks passed on real cached VK audio, with playback advancing beyond the ten-second seek position in both phases. Muted technical advancement cannot confirm speaker output or song identity; those status fields describe automation only. The user has now separately confirmed both native playback and audible cached playback with the correct songs. Automatic catalog refresh is suspended during this mode to avoid interfering with playback tests. The runner waits for rendered music rather than assuming `did-finish-load` means the page is ready, and now exercises bounded personal-library pagination before playback checks.

The user then clarified that startup always opened a different music view and required another click on My music. The runner now opens that tab itself and requires a selected personal navigation target, matching personal route, or top-level personal heading. Live evidence at `2026-10-18T07:52:44Z` confirms automatic navigation, one selected My music target, and a matching personal route. The earlier 1,492 entries were from an unconfirmed general view: they are preserved separately under `.local/vk-proof/unverified-library.json` and excluded from the corrected personal catalog. The corrected initial personal view supplied 118 metadata entries; the full personal total is unknown.

Scripted control activation initially produced zero audio/CDN candidates. The native-input implementation now targets the observed playback region of the exact requested track in a visible, focused music window. It hit-tests the region, requires the same track when a pointer-transparent wrapper forwards the hit, and excludes links, credential fields, menus and library mutations. It rechecks the personal music/form gate before activation. No sign-in window is inspected or automated. Browser event-handler presence, geometry, request categories and fixed error codes are the only diagnostics exported.

The automated run at `2026-10-18T08:04Z` captured one HLS candidate on each of two attempts. Those attempts then failed during download/validation. This proves that source capture can now progress beyond metadata, but not that the candidate is a complete playable track. The helper now classifies HLS stderr internally into fixed HTTP/protocol/extension/key/TLS/data categories; signed URLs and raw stderr are never returned. Native capture still rejects multiple candidates rather than silently assigning one.

The HLS issue was MP3 audio being copied into an incompatible M4A container. The helper now stages HLS without transcoding, detects the codec locally, remuxes to a compatible browser container, fully decodes the result and publishes atomically. Three real MP3 tracks passed download/full decoding; one measured 10,180,527 bytes and 254.484898 seconds. Cached playback initially failed because Chromium paused muted background media. The automated local window now stays active for that check; the cache protocol explicitly serves MIME types, byte ranges and seek responses.

Syntax checks and all **63 Node tests and 11 Python tests** pass. Tests cover command-schema restrictions, bounded attempts, source-error sanitization, offline resume, synthetic browser progression/seek failures, byte-range response bodies/headers, personal-view navigation and guarded native hit testing. Personal-library completeness and actual provider additions remain open; use the live sanitized runner status for the newest result.

At `2026-10-18T08:37:38Z`, the unattended personal scan observed 138 distinct rows over eight viewports and retained 142 entries after merging earlier confirmed personal rows. It stopped after repeated viewports produced no new rows, with `complete: false`. This verifies pagination beyond the initial personal view and removes the old 30-row limitation; it does not establish the provider total. The same run then passed online and offline playback/seek again at `08:37:43Z`. Automatic addition detection has synthetic coverage only; the user's disabled sync preference was preserved, and no account library additions were made for testing.

## Current implementation

### Update resistance: proposed boundary, not a production implementation

The user wants resistance to VK layout changes without excessive engineering. A browser-based provider adapter can still break when VK changes its data or playback behavior. The practical design is one isolated VK adapter, one supported fallback for an observed layout, and focused contract tests. A supported music API would be preferred if usable; this proof does not establish availability of one.

- Keep provider operations small: list/refresh metadata, resolve audio for a track ID, and report availability. Keep the local library, cache, player and Piles independent of VK markup.
- Prefer explicit track identifiers and named music data. Use semantic controls and scoped music attributes for browser actions; avoid absolute DOM paths, child indexes and generated CSS hashes. HTML restructuring can then leave the music contract intact, while changed field formats still require an adapter update.
- Validate track identity, required metadata, recognized music context and audio-source ambiguity. Unknown formats produce a fixed error category and retain all previous local data. An empty or partial response never deletes the library.
- Observe music-row identity changes and loading state through the browser's [MutationObserver API](https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver). A virtualized list may replace IDs without increasing its element count. Adapt the wait to observed arrival times, retry a stalled scroll boundary and enforce a total budget. A quiet timeout is an incomplete scan, not proof of the account total.
- Keep synthetic fixtures for the supported page variants, delayed arrivals, stuck loading, virtualized rows and sign-in interruption. Fix the adapter against these tests when an actual VK change is observed.

This protects local features and makes provider repairs narrower; it does not make VK's web interface a stable public contract. Normal background sync still needs its own live acceptance check. The feasibility runner suppresses background throttling so VK pagination remains active during the unattended test.

The [probe](../spikes/vk-provider/README.md) uses a dedicated VK sign-in window with a persistent Chromium session, as authorized by the user. No extension or local import server is required. Music extraction follows an explicit import, enabling sync, or the user-authorized automated test, on a recognized music page; login field values are never read. Account cookies are not exported to the helper or logs.

Agent privacy instructions exclude the session profile and sign-in window. The [sandbox launcher](CODEX_PRIVACY.md) passed synthetic private-file denial, repository access, networking, and Git Bash checks with project-local Codex CLI 0.163.0. After removing a redundant CLI override, interactive startup succeeded and an ephemeral app-server thread confirmed the `ownsemble` profile with escalation disabled. On 2026-10-18, work resumed in `C:/Users/User/Ownsemble`: project configuration selects `ownsemble`, and the active session enforces the matching private-path denials with approval policy `never`. The earlier unrestricted chat is no longer the current working session.

## Completed checks

- JavaScript syntax, Python compilation, and dependency consistency passed.
- Eleven Node tests passed: credential-field rejection, allowed CDN destinations, encoded-link validation, schema bounds, music-page/login guards, class-independent array rows, object rows and audio refresh, count-only failure diagnostics, deduplication, and the 30-track limit.
- Eight Python tests passed: full local decode, invalid/short audio rejection, credential rejection/redaction, lack of ambient credentials, and destination restrictions.
- Private data and dependencies are excluded from Git; search and agent rules exclude session data.

The decoding test uses synthetic audio. No credentials were used in these tests.

On 2026-10-18, `npm run check`, all seven Node tests, and all eight Python tests passed again in the protected session. The sanitized evidence available at that check contained startup events only; real VK import, download, and playback remain pending. The next live action is to launch the harness from a separate normal Git Bash terminal and open My music after private sign-in if needed.

### Live attempt on 2026-10-18

The user reports successful private sign-in and opening music. Clicking **Import my music** returned “No supported music rows found.” This establishes a failed import attempt, not an empty music library. No page HTML, account session, or sign-in UI was inspected by the agent.

The adapter previously required `.audio_row`/`.audio_item` classes and array-shaped `data-audio`. It now accepts music attributes independently of those classes and projects explicit music fields from either arrays or objects. The object field shape is supported by the public [vk_api parser source](https://github.com/python273/vk_api/blob/master/vk_api/audio.py); this is a compatibility hypothesis, not confirmation of this user's page format. Imports now record only allowlisted numeric row counts in `music_rows_examined`, including on an unsupported-format failure. No HTML, attribute contents, track names, account identifiers, or audio links enter those diagnostics.

Syntax checks and all eleven Node tests passed after the change. Four new synthetic tests cover the compatibility changes and diagnostics. A fresh app launch and explicit **Import my music** action are required to test the update; the saved sign-in session is retained by the harness.

The retry also failed. Sanitized evidence confirms zero `data-audio` elements, zero legacy row elements, and zero `data-full-id` candidates. The object/array compatibility hypothesis did not resolve this page. The user has requested direct diagnosis of the music page structure.

The harness now produces `music_dom_diagnosed` after an explicit import fails: bounded element counts and music-related CSS component names with hashes/IDs stripped. It reads no HTML, text, field values, script contents, URLs, cookies, or framework state; login forms stop before this inspection. This will distinguish component layouts, frames, and open shadow roots without exporting the full page. All fourteen Node tests and syntax checks pass, including privacy tests for the structural report. One restart is needed to load this instrumentation. After that, page adapters reload on each explicit import, avoiding restarts for subsequent adapter edits. Actual structural evidence is still pending.

### Structural evidence and modern reader

The subsequent report at `2026-10-18T05:57:34Z` found 118 `data-audio-id` elements and 118 `AudioCellCompositeRowsLayout` components, with zero legacy row markers. It also counted one iframe and zero open shadow roots. This confirms that the legacy selector strategy does not match the rendered music cells; it does not confirm playable audio.

The page reader now targets those modern cells. It projects only named music props (`audio`, `track`, `audioData`, `item`) from the row's own React props or up to eight nearby component ancestors, requires an exact match to the row's track ID, and stops at an outer DOM boundary. It does not inspect global stores, hooks, session state, or authentication responses. Displayed metadata can also be read from explicit `MusicTrackRow_Title`, `MusicTrackRow_Authors`, and `MusicTrackRow_Duration` markers (also used in the public [VK Music List Copier source](https://greasyfork.org/id/scripts/587484-vk-music-list-copier/code)). Missing audio links remain missing; metadata import alone does not establish playback feasibility.

Syntax checks and all seventeen Node tests pass. New tests cover modern DOM metadata, row component audio links with forbidden-state access traps, and mismatched/malformed track identifiers. The reader is self-contained and loads through the already running app's per-import reload mechanism. No restart is needed for this retry. The actual import/link outcome remains pending.

### Metadata success and follow-up scope

Evidence at `2026-10-18T06:36:14Z` records `library_imported` with **30 tracks, 0 playable URLs**. The user confirms seeing names and being unable to play or cache. This proves metadata listing only. The user also requested automatic updates and loading beyond the 30-track sample; those changes remain inside the provider feasibility harness.

The latest implementation adds a persisted **Enable automatic sync** action, an initial scrolling scan, and two-viewport refreshes every two minutes while running. The retained Chromium session is reopened in a background window on later starts after the user enables this mode. Music URL/form guards still apply; no sign-in field values are read. A scan collects virtualized viewports, merges additions without deleting unseen existing entries, supports cancellation, and reports its stop reason. The 30-track limit is gone. Operational bounds are 250 viewports/50,000 distinct tracks and four idle viewports. A provider total has not been established, so no scan is labeled complete.

An uncached Play action now attempts to activate only a known play control within the exact requested music row. The app briefly mutes the native VK player and observes allowlisted audio destinations through [Electron's request hook](https://www.electronjs.org/docs/latest/api/web-request#webrequestonbeforerequestfilter-listener), scoped to that window and the pending action. It reads no request headers, cookies, bodies, authentication responses, or token stores. Zero or multiple distinct audio sources cause a failure; a single source is a **candidate**, not independent proof of track identity. The live test must confirm that the downloaded audio is the correct selected track, in addition to full decoding/duration, audible playback, seeking, and offline restart. The Python helper still receives no account cookies. Temporary audio links stay in app memory.

All thirty Node tests, syntax checks, and eight Python tests pass after these changes. New controls/request hooks require one restart. Their behavior on the actual VK page is not yet tested. The modern CSS/test-id report can guide further play-control adaptation without dumping page HTML or authentication state.

### Larger scan and playback-control mismatch

Live evidence at `2026-10-18T07:22:27Z` records **1,492 metadata entries**, 214 viewports, zero playable URLs, and stop reason `no_new_rows`. This verifies discovery beyond the 30-track sample, but not the provider's full library total. A subsequent automatic refresh encountered a temporary zero-row page and failed; automatic addition detection has not passed a live test.

The native playback attempt at `07:22:42Z` recorded `activated: false` and zero source candidates. The DOM report contains `MusicTrackRow_PlaybackControls`, which was missing from the adapter's control selectors. The action reader now supports that observed playback region: it hovers the exact requested row, activates the region's sole button if present (otherwise the specific region itself), and rejects multiple buttons rather than choosing a potentially unrelated action. Generic row/menu/delete clicks remain prohibited.

Syntax checks and all 33 Node tests pass. Three new tests cover the observed playback region, its sole nested button, and rejection of ambiguous controls. The action reader reloads on each Play attempt, so **no restart is needed for this fix**. Activation, media-source capture, download and correct-track playback still require a live retry.

## Live acceptance

| Check | Result |
| --- | --- |
| Sign in privately | Passed, user reported |
| Import personal music | 2,147 retained entries; bounded full scan plus incremental refresh passed beyond 1,000 rows; exact provider total unverified |
| Resolve audio links | Single HLS candidates captured and downloaded without account cookies; song identity unconfirmed |
| Save full audio and validate decoding/duration | Passed on three real tracks, with full-file decode |
| Native VK speaker output | Passed, user reported; separate from cached playback |
| Cached player progression and seeking | Passed automatically; audible cached playback and correct songs confirmed by the user |
| Restart offline; verify/play/seek | Passed automatically with remote requests blocked and matching file hash |

No feasibility claim should be made until the corresponding live outcomes are observed.
