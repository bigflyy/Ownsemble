# VK provider feasibility test

A dedicated VK window handles sign-in and retains its Chromium session locally. No browser extension is required. The app does not read password fields, export account cookies, or pass session credentials to the Python helper.

## Run in your own Git Bash terminal

Launch outside Codex's sandbox so the application can access its private session profile:

```bash
cd /c/Users/User/Ownsemble/spikes/vk-provider
npm start
```

Dependencies have been prepared locally. On a fresh checkout, create `.venv-vk` at the repository root, install this directory's `requirements.txt`, and run `npm ci` here. FFmpeg and FFprobe must be on PATH.

## Automated feasibility checks

The 2026-10-18 real-audio checks passed for full downloads, cached progression/seek and a network-blocked restart. The user subsequently confirmed audible cached playback and correct songs. Automated tests remain muted and never manufacture a listening confirmation.

Close an older probe instance, then launch once from a normal Git Bash terminal:

```bash
cd /c/Users/User/Ownsemble/spikes/vk-provider
npm run proof:auto
```

The runner reuses the app's retained session, opens **My music** automatically, and requires a selected personal tab, a matching personal route, or a personal page heading before collecting tracks. A login page pauses the test for private sign-in. It scans successive personal-library viewports, then tries up to three personal tracks: resolve audio, save/fully decode it, verify its hash, and test muted browser playback and seeking. After the first successful track, it restarts itself with remote requests blocked and repeats local decoding, hash, playback and seek checks. Browser advancement is not confirmation of speaker output or song identity; those remain separate unconfirmed outcomes.

The runner watches a fixed list of harness source files, restarts, and retries after edits. Playback retries prefer existing cached samples. Metadata pagination observes new IDs, including replacements in a virtualized list, instead of assuming a fixed wait is enough. It does not watch or expose the browser profile. A restricted command file admits only `run` and `stop` with a nonce; it accepts no JavaScript, URLs, track IDs, credentials or input coordinates. Agent-side controls from this directory are:

```bash
npm run proof:status
npm run proof:run
npm run proof:stop
```

Status and evidence contain only test stages, counts, booleans and fixed error categories. Stop is cooperative between stages; it does not forcibly terminate an ongoing decoder. Automatic library refresh is suspended in automated-proof mode to avoid page reloads during a playback test. Native input is limited to a visible, unobscured playback area of the exact selected track after the music/form gate, and can briefly focus the dedicated VK window. Sign-in windows are not automated.

Earlier entries collected from an unconfirmed general music view are preserved in `.local/vk-proof/unverified-library.json` when the source is corrected. They are excluded from the newly confirmed personal catalog. This preserves the earlier metadata without claiming it represents the user's library.

## Manual live test

1. Click **Connect VK** and complete sign-in privately in the dedicated VK window.
2. Return to Ownsemble and click **Enable automatic sync** once. The app opens and verifies **My music** itself. The preference persists; later starts reconnect in a background VK window using the retained session. **Connect VK** shows that window if private sign-in is needed again.
3. Sync reads recognized music pages and rejects login forms without reading field values. It collects successive viewports, retaining rows that disappear due to virtualization. Automatic refresh checks the top two viewports for additions every two minutes while the app runs. **Sync now** runs another longer scan; **Disable automatic sync** stops automatic refresh and requests cancellation of the current scan.
4. Choose **Resolve, play & cache** (or **Play & cache** if a URL is already available). The probe asks VK's native play control for the selected track, briefly mutes the VK window, and observes only allowlisted audio destinations in memory. It rejects missing or multiple source candidates. The helper receives the audio link and browser user-agent, never account cookies. Confirm the saved track is the correct song, is audible, and seeking works. Native source resolution and full downloads have passed automated live tests; the user has confirmed correct songs for the cached listening sample.
5. Choose **Restart offline**, then **Verify** and **Play**. The restarted app blocks remote requests and verifies the saved audio using file-only decoding.

This is download-first playback: a normal Play action also saves and validates complete audio. Real automated checks passed on 2026-10-18: three HLS downloads fully decoded, followed by cached browser progression/seek and a network-blocked restart with matching file hash and repeated playback/seek. The user confirms audible native VK playback and audible cached playback with the correct songs. The earlier 1,492 entries came from an unconfirmed general view. The app now opens and verifies personal My music automatically; the latest bounded metadata scan and incremental refresh retained 2,147 entries. Incremental refresh discovered 39 previously unseen rows while retaining earlier entries; this does not prove that those songs had just been added on VK. Full personal coverage and automatic additions remain unverified. No production application is being implemented here.

The old 30-track sample limit has been removed. A scan has bounds of 250 viewports and 50,000 distinct tracks. The feasibility run also has a five-minute budget. Full scans observe row-identity changes and loading state, adapt waits to arrival times and retry stalled scrolling; a quiet stop requires at least a minute without new entries. Partial or timed-out scans never establish the provider total. Its evidence reports the stop reason and always marks the provider total as unverified: a stalled page is not proof of a complete library. Existing entries and cached files survive partial scans; provider deletions are not propagated by this probe.

## Private data

The dedicated session lives under `.local/vk-proof/app-profile/`. The user has authorized retaining it for normal app features. Chromium manages it; the app does not save the account password separately. Agent instructions prohibit inspecting this directory or the sign-in window.

The app returns music metadata and temporary audio links. The latter remain in memory and are excluded from evidence. Downloads accept allowlisted HTTPS VK audio CDN links without account cookies. Full duration/decoding is checked before publishing a completed file.

Use the [Codex privacy profile](../../docs/CODEX_PRIVACY.md) for sandbox-enforced file denial. Its launcher and project profile have been verified with CLI 0.163.0. Protection applies to sessions opened through the launcher; an existing unrestricted chat does not change retroactively. Use the [session handoff](../../docs/SESSION_HANDOFF.md) to carry the project context into a new chat.

## Local tests

```bash
npm run check
npm test
../../.venv-vk/Scripts/python.exe -m unittest -v test_provider.py
```

Fifty-two Node and ten Python tests pass. They cover music/login guards, personal-view navigation, music rows, pagination and merges, cancellation, playback controls and hit testing, source ambiguity, command-schema restrictions, bounded automatic runs, offline resumption, browser-player checks with synthetic media states, sanitized diagnostics, CDN restrictions, malformed/incomplete audio, redaction, and full local decoding. Tests use synthetic data and do not establish VK feasibility. See [evidence](../../docs/VK_FEASIBILITY.md).

Modern `[data-audio-id]` rows are read through explicit music text markers and named row component music props with matching track IDs. The reader does not inspect global stores, hook state, or authentication data. If a row supplies metadata without an audio link, it remains unplayable until a supported link-resolution method is established.

If music rows are unsupported, Import saves a structural report in the sanitized evidence: element counts and music-related CSS component names with hashes/IDs removed. It excludes HTML, text, field values, script contents, URLs, and session state. Page adapters reload on each explicit import, so subsequent adapter edits do not require restarting the application.
