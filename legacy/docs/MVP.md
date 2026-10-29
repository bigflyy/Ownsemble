# Proposed Ownsemble MVP

Updated 2026-10-19. **Approved for implementation on 2026-10-19** (user: "go ahead do it"). Windows first, one VK account, Android later. This revision incorporates the actual [VK feasibility results](VK_FEASIBILITY.md) and the user's requirements for automatic refresh, several Piles and resilience to VK changes.

## What the feasibility test established

The table records the Electron reference test. Host-specific Flutter/Android results are tracked separately in [Flutter feasibility](VK_FLUTTER_FEASIBILITY.md).

| Capability | Observed result | Meaning for the MVP |
| --- | --- | --- |
| Private VK sign-in and retained session | Working in the dedicated app browser | Reuse this route; no browser extension or exported cookies |
| Personal music navigation | My music opens and is verified automatically | No repeated manual navigation/import workflow |
| Large metadata listing | 2,147 entries retained after a bounded scan and incremental refresh | Pagination works beyond 1,000 entries; exact account coverage is still unverified |
| Incremental discovery | 39 previously unseen rows merged, with earlier rows retained | Refresh can discover missing local metadata; newly added account songs still need a live scheduled-refresh check |
| Complete audio | Real downloads fully decoded and validated | Reuse the proven download/validation path |
| Cached playback and seeking | Passed online and after a network-blocked restart | Local audio can work independently of VK |
| Listening check | User confirmed audible playback and correct songs | Do not repeat manual listening tests without a new issue |
| Automation | 63 Node and 11 Python tests passed in the probe | Useful starting evidence, not production release validation |

The five-minute metadata scan stopped at its budget with `complete: false`. A large count is not proof of a complete account import. The older 1,492 general-view entries were unverified and excluded from the corrected catalog. No test downloaded the entire library or changed the VK account.

## Product promise and release scope

Open your music, play it normally, retain selected music offline, and add a song to any personal Pile whenever you rediscover it. Metadata, organization and listening history stay local. Cached audio is a separate resource; a provider reference does not guarantee permanent online availability.

The proposed Windows release includes:

1. One private VK connection with a retained session and an explicit, persistent automatic-sync setting.
2. Automatic My music navigation, paginated metadata discovery, local title/artist search, startup/reconnect refresh and periodic checks for additions while the app runs. A newly added song must not require another Import click.
3. Play/pause, seek, volume, next/previous, a queue, shuffle and repeat. Prefer complete cached audio when present.
4. Automatic full-track caching, a configurable storage budget, and explicit offline-ready/progress/retry states.
5. Permanent track pins and pinning of local Piles. Retain the requested VK-playlist pinning goal, subject to the separate playlist-listing/membership check below.
6. Several named, ordered Piles with repeated additions and deletion of individual occurrences.
7. All music, VK, Available offline, Recently played and a basic all-time Most played view. Piles have their own navigation.
8. Persistent local data and useful disconnected, partial-sync, unavailable-track and adapter-update states.

Android, other providers, cloud/device sync, global VK search, recommendations, editing VK playlists, portable audio export and a configurable view builder are later work. **Provider refresh is part of the MVP; cloud/device sync is not.**

VK playlist browsing/import and playlist-wide pins remain desired. The current proof did not establish playlist enumeration or membership. Milestone M3 checks this before exposing the feature or calling it supported. A failure there requires an explicit scope revision; track pinning must not silently be presented as fulfilling playlist pinning.

## Windows implementation with an Android path

**Direction: Flutter, Dart and SQLite.** The user explicitly prioritized future Android reuse and authorized a second, isolated feasibility probe. Production implementation is now authorized. See [Flutter feasibility](VK_FLUTTER_FEASIBILITY.md) for the actual checks and limits.

The Electron/Python experiment remains the working VK reference. Its music readers, adapter guards, loading behavior and source-resolution findings are reusable. Its Electron browser/input bindings and Python helper are not the proposed mobile runtime.

The new probe uses `flutter_inappwebview` for Windows WebView2 and Android WebView, `media_kit` audio libraries, SQLite and shared Dart download/cache code. The Dart cache stores complete local HLS manifests, keys and segments, validates local decoding and publishes atomically. No Python or FFmpeg executable is needed by this route at runtime. Compatibility with actual VK media must pass in the new host before adopting it for the MVP.

Flutter permits a shared UI and much of the application logic. Android sign-in, trusted playback activation, resource interception, background audio, media controls and lifecycle remain platform acceptance gates. A Windows success or an APK build alone does not prove them. Keep browser credentials inside each platform's private WebView session and expose only guarded music operations to the local app.

## Small architecture with a replaceable VK adapter

| Part | Responsibility |
| --- | --- |
| Local UI and player | Browse local records, edit Piles, operate the queue and play local audio |
| Library service + SQLite | Track identities, provider references, occurrences, pins, history and sync state |
| VK adapter | Recognize music context, discover metadata, resolve a selected track's audio and report availability |
| Sync coordinator | Schedule bounded refreshes, merge progress, retry and persist partial/failure state |
| Audio/cache worker | Download, validate, publish, pin and evict complete local assets |

These are modules within one desktop app, not separate network services. No Ownsemble server was required by the proven route.

Keep the adapter contract small:

- Listing returns validated metadata, progress/continuation when available, an optional provider total, and a completion/partial outcome.
- Audio resolution accepts a provider track reference and returns an ephemeral source in app memory or a fixed failure category.
- Status distinguishes private sign-in needed, temporary loading/network trouble, unavailable audio, ambiguity and unsupported adapter format.

Do not invent a reliable provider cursor if the browser page exposes none. Retain known IDs and scan state; resume through a verified continuation when available, otherwise deduplicate a fresh bounded scan. Temporary URLs, cookies and browser coordinates are not durable catalog identifiers.

Prefer explicit music fields and stable track IDs, then semantic/scoped controls. Keep the current observed modern/legacy fallback small. Avoid dependence on exact parent/child nesting, generated CSS hashes, global framework stores or guessed generic clicks. A VK data/control change may still require maintenance; an unknown format must preserve the local library and cached playback.

Fixtures cover known page variants, changed wrappers, virtualized rows, delayed arrivals, stuck loading, sign-in interruption and ambiguous sources. Add a new fallback only when an observed format requires one. Do not build a general page-repair framework.

## Automatic sync and dynamic loading

- Connect/enable sync is a one-time explicit user action; preserve the setting. The current test profile has sync disabled and this planning update does not change it.
- Proposed cadence: bounded discovery on connection/startup, an incremental check every two minutes while running, and reconciliation batches for older missing entries. Metadata work must not block playback or list interaction.
- Watch new track identities and loading state rather than waiting a fixed interval. A virtualized list can change IDs without changing its row count.
- Adapt the wait to observed arrival times, retry a stalled scroll boundary and use elapsed quiet time plus overall time/page/track budgets. Progress resets the quiet deadline; a busy loader is not an end marker.
- Persist merged progress between batches. Timeouts, offline state, interrupted sessions and unknown formats produce a partial/retryable result. Never delete unseen records on that basis.
- Identify actual collection membership, excluding incidental recommendations and preview sections. A verified My music page does not by itself prove that every music row on it belongs to the account collection.
- Show last successful refresh, progress and honest coverage. Claim a complete import only with a reliable provider end/total witness and reconciliation; 1,000+ rows alone is insufficient.
- Pause on a sign-in form without reading its fields. Recover after the user signs in privately. No repeated manual song imports should be part of normal operation.

M0 must verify the normal scheduled background path. The probe's successful visible/active-window run does not prove that a hidden production browser will continue lazy loading. Check a genuinely new VK addition during normal use; do not manufacture account changes or count delayed existing rows as that result.

## Local records and Pile behavior

| Record | Responsibility |
| --- | --- |
| Track | Stable local identity and metadata |
| Provider reference | Provider/account source, provider track ID and availability; resolve temporary audio on demand |
| Pile / Pile entry | Named list; independently identified occurrences, order and addition time |
| Addition event | Each deliberate addition, including repeated tracks |
| Play event | Playback start, listened duration and outcome |
| Cache asset | Audio variant, local path, bytes, completion and last access |
| Pin reference | Explicit retention by a track or a pinned list snapshot |
| Sync state | Last success, partial/error outcome, known progress and verified continuation if available |

Do not merge songs by artist/title alone. Preserve versions and provider identifiers. All music is a unique-track view; a Pile is an occurrence view.

For a Pile containing A, B, A, newest first:

- Adding A again creates a new entry at the top. Existing occurrences remain.
- Removing one A removes only that entry, leaving the other occurrence, library record, other Piles and audio retention unchanged.
- Playback starts at the selected occurrence, even if another entry refers to the same track.
- Pile actions do not modify VK. Creating, renaming and deleting several local Piles are first-release behavior.

Proposed list-pin rule: pinning captures the current list's unique audio assets; later discovered additions extend it. Removing a list occurrence or losing provider membership does not silently erase retained audio. Explicit unpin releases that list's retention references; individual pins and other pinned lists remain effective. Keep these references separate from occurrence IDs.

## Playback, cache and offline rules

- Start with an LRU policy for unpinned complete audio. Proposed default automatic-cache budget: 2 GiB, configurable. Popularity remains separate from eviction recency.
- Pins sit outside that automatic-cache budget; display automatic, pinned and total storage separately and handle insufficient disk space explicitly.
- Never evict pinned assets, active downloads or the currently playing asset. If no safe eviction is possible, pause further automatic caching with a clear state.
- Cache one copy per audio variant, regardless of repeated Pile entries or pin references.
- Reuse the validated HLS/source findings and check direct audio sources when supplied. Validate the shared Dart local-HLS route against real VK media; the reference Electron proof used codec-aware remuxing. Preserve source audio quality.
- Publish offline-ready only after complete download, full decoding/duration validation and atomic publication. A manifest, partial file or browser buffer is insufficient.
- On interruption, retain a retryable state and clean temporary files safely. Re-resolve expired audio sources; never treat them as permanent IDs.
- Prefer the saved asset on replay. Removing an occurrence does not change retention; unpinning does not immediately delete an asset protected elsewhere.

**Streaming is mandatory (user decision, 2026-10-19).** Uncached songs must start
playing while buffering/downloading continues, without waiting for the complete
track. Keep the player responsive during scanning and cache completion; test slow
networks, cancellation and seeking. Offline-ready still requires full integrity,
duration/decode validation and atomic publication. The existing download-first
baseline does not satisfy this requirement. Implement streaming immediately after
the hidden, independent playback/scanning page fix. Do not assume the browser's
playback buffer is a reusable full cache file.

## Views and UI

Use a compact sidebar for Library, VK, Recent, Most played, Offline and Piles; a searchable, virtualized track list; and a persistent player. Keep browsing responsive during sync/downloads. Give rows quick Play, Add to Pile and Keep offline actions. Display offline-ready, pinned, downloading, partial-sync and unavailable states distinctly.

Preserve a play-event history. Recently played uses tracks whose playback began. Proposed qualified-listen threshold for all-time Most played: 30 seconds or half the track, whichever is shorter. This is a product default, not a provider rule. Time-window rankings and a separate re-addition-history view can follow later.

Verify Cyrillic metadata, keyboard navigation, readable empty/error states and clear selected/playing rows. Specific colors and artwork treatment remain a design choice; a polished UI must not conceal provider/cache failures.

## Implementation milestones and acceptance

The user authorized these milestones on 2026-10-19. Current implementation and acceptance status is tracked in `IMPLEMENTATION_STATUS.md`. Keep both `spikes/` probes as feasibility references.

| Milestone | Deliverable | Acceptance gate |
| --- | --- | --- |
| M0: packaged provider slice | Flutter desktop host, isolated adapter, shared audio/cache, scheduled sync | Run without developer tools installed; retained private session works; refresh while the main window is backgrounded; a genuinely new VK song appears without Import/My music clicks; expired-session/unknown-format fixtures retain local data; Android probe has explicit results |
| M1: persistent library and shell | SQLite records/migrations, local search, responsive list, progress and recovery | Use a 1,000+ metadata fixture plus real bounded discovery; restart mid-scan and merge without duplicates/loss; reconcile against the provider list/count where possible; clearly mark unresolved coverage |
| M2: player and automatic cache | Queue controls, local-first playback, validated downloads, LRU and retries | Test seek, next/previous, shuffle/repeat, expired links, interruption and a tiny quota; pins/current audio survive cleanup; measure cached/uncached startup; restart with remote requests blocked and play saved audio |
| M3: several Piles and permanent lists | Occurrence-based Piles, track/Pile pins, VK playlist membership proof | Add A/B/A, remove one A and restart; other occurrences and audio remain. Overlapping pins protect one asset correctly. Verify playlist enumeration/membership and offline pinning before offering VK playlist support |
| M4: listening views and UI completion | Recent/Most played, keyboard flow, clear loading/error/offline states | Qualified listens survive restart; occurrence-based playback remains correct; browse/search stays responsive during sync and downloads |
| M5: release candidate | Reproducible Windows build, install/upgrade, end-to-end evidence | Fresh-user install without npm/Python setup; existing catalog/pins survive upgrade; normal background sync and offline restart pass; remaining limitations are explicit |

Use synthetic fixtures and controlled failures for routine regression checks. Automate app-side real tests where possible; sample audio is sufficient for the provider proof. A full metadata reconciliation serves coverage testing and does not require downloading the entire library. Existing listening confirmation need not be repeated unless the playback path materially changes.

## Defaults and review decisions

Recommended defaults for review: Flutter/Dart/SQLite with Windows first and shared Android code; several Piles; two-minute incremental refresh; 2 GiB unpinned LRU cache; track and local-list pins; basic all-time Most played. These are the approved implementation defaults; see `IMPLEMENTATION_STATUS.md` for verification limits.

The remaining technical gates are full catalog reconciliation and collection membership, true scheduled new-song discovery, private-session recovery, VK playlist membership, uncached startup latency and helper packaging. They determine the release claim and any estimate. Android and later providers need separate plans.

The user authorized production implementation on 2026-10-19. Routine implementation and validation may proceed; private sessions remain agent-inaccessible. Deployment and commits have not been requested.
