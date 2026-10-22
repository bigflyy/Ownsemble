# Feature queue

2026-10-22 current Linux browser direction: user explicitly requires a maintainable
Ubuntu/desktop-Linux adapter; do not compromise the choice to make WSL pass.
Selection criteria and honest generated qualification results are in ADR0003 and
LINUX_BROWSER_PROBE.md. CEF native Views is selected for adapter implementation after generated media/input
proof; full native lifecycle/packaging and live Linux VK remain undelivered.

2026-10-22 selected Linux UI follow-up: native GTK host and shutdown bridge,
Debug/Release builds and generated-data WSLg UI/audio/cache/restart checks delivered.
Shared Dart/provider dependency pin unchanged. Broader Ubuntu/Fedora acceptance
and live VK browser/runtime remain pending. See LINUX_PROOF.md and latest handoff.

2026-10-22 the user selected the architecture rework as the current milestone:
shared logic behind tested provider/browser/playback/runtime/trust interfaces,
Windows adapter extraction and cross-OS generated-policy verification. This is
now implemented, with current acceptance in SESSION_HANDOFF.md; see ARCHITECTURE.md
and ADR0001. It does not deliver a production Linux/Android port. The clickable
connection badge and other backlog features remain logged separately.

## Clickable provider connection badge / connection controls — proposal

Requested 2026-10-22 for the feature log: make VK connected clickable and expose
disconnect/reconnection controls there, rather than requiring discovery in Settings.
The exact interaction is undecided. Candidate: click opens a small connection menu
or status panel with connection state and explicit reconnect/disconnect actions;
avoid unexpectedly disconnecting merely by clicking the status badge. Coordinate
with the separately logged sync-status control so connection, synchronization,
download and song-loading states remain understandable.

Disconnecting should have explicit semantics for automatic retry/sync and preserve
the catalog, saved metadata, Piles, history and offline music. Distinguish temporary
disconnect from signing out/clearing a private session; do not silently delete
session data or imply external account/library mutations. Retain keyboard/focus,
hover hints and current privacy controls. This is logged only, not implemented
as part of the architecture rework.

2026-10-22 keyboard follow-up: Escape leaves search without clearing its query,
returns keyboard focus to the library and keeps front dialogs/popups first in
Escape handling. Ctrl+K returns to search. Tests first; see KEYBOARD_USABILITY.md.

2026-10-22 portability discussion: the user challenged Windows-specific browser
coupling and asked for an approach suitable for Android/Linux and other OSes.
PLATFORM_PORTABILITY.md records the current gaps, historical Android synthetic
proof, official Linux-capable prerelease candidate and proposed common browser
capability contract. This is a proposed portability milestone, not an upgrade or
implemented port. The user subsequently selected the architecture milestone above.

2026-10-22: delivered keyboard usability extends selected step 1: additional playback
shortcuts, shared hover hints/F1 help, text-editing/modal/focused-button protection
and tests first.164 Flutter/48 adapter tests, both builds and native smoke checks
pass. See KEYBOARD_USABILITY.md. Performance/earlier-streaming-start
investigation and the confirmed VK-lyrics extraction bug remain queued separately.

2026-10-21 16:54 UTC: selected step 1 plus SAVED/alignment and clickable artwork
previews are delivered; see CONTROLS_UI_FIXES.md. VK lyrics extraction failing
despite lyrics being available in VK is a confirmed queued bug. Later feature
milestones remain unselected.

2026-10-21 13:21 UTC: current metadata delivery and the critical recording/cache
repair passed their scoped acceptance checks. Live VK lyrics text remains an
explicit limitation. See METADATA_ENRICHMENT.md, RECORDING_INTEGRITY.md and the
latest SESSION_HANDOFF.md. Agree priorities with the user before backlog work.

This is an UNSORTED backlog, not an implementation order. Complete the active
metadata/artwork/lyrics task first. Then suggest a priority order and ask the user
which item to do next before starting backlog features. User clarified this on
2026-10-21. Use tests-first development and preserve existing data/playback.
The proposed order is in [FEATURE_IMPLEMENTATION_PLAN.md](FEATURE_IMPLEMENTATION_PLAN.md).
The user selected step 1 (search spaces and mute), plus the fixes/previews below;
later milestones still await a priority choice.
General user instruction: messages marked "feature log" (or equivalent) add to
this list while the current task continues; they do not interrupt or replace it.

## Delivered task: metadata, artwork, lyrics support and dates

- Extract supported optional metadata from the exact VK recording: album,
  version/subtitle, artist credits, explicit flag and true release information.
- Cache validated thumbnails for library/player and supported lyrics for offline
  reading; timed lyrics only when actual timestamps are supplied. Never block Play.
- Show date added when its provider meaning is verified. Otherwise show the
  earliest retained "Imported into Ownsemble" date. Upload date is separate.
- Preserve existing records/cache and good optional data after partial failures.
  New full-library rescans or bulk external queries are not a side effect.

## Search spaces — bug

Fixed and verified 2026-10-21; see CONTROLS_UI_FIXES.md.

Pressing Space in the search field must insert a normal space between words.
The global play/pause shortcut must continue to work when text input is not focused.
Reported 2026-10-21; also tracked in KNOWN_ISSUES.md.

## VK lyrics extraction misses available lyrics — confirmed bug

Reported 2026-10-21: the user confirms that lyrics exist for a song in VK, but
Ownsemble does not extract them. Treat this as a retrieval bug, not evidence that
the provider has no lyrics. Repair the guarded exact-recording extraction path;
external lyrics discovery is a separate feature. Reproduce with synthetic
fixtures/tests first, then use fixed app-owned controls and sanitized categories
for scoped live verification. Preserve saved lyrics and recording identity;
lyrics lookup must never delay Play. This report is queued without interrupting
the active search/mute/status-alignment/artwork-preview work.

## SAVED status and column alignment — delivered fix

Requested 2026-10-21: success and failure indicators must not appear together;
SAVED status, duration under the clock, play/# and title headers must align with
their row contents. Preserve errors and cached files rather than deleting data
to hide a contradictory state. Show one primary status with retry progress first,
then a failure if present, then verified saved state; retention remains a separate
pin control and explanatory tooltip.

## Clickable artwork previews — delivered feature

Requested 2026-10-21: click cached library/player thumbnails to inspect the image
in a larger view. Use the existing validated cached image, support zoom/pan and
close/Escape, and preserve playback/selection. Placeholder artwork is not a real
image. Enlarging a thumbnail does not establish access to higher-resolution art.

## Most played counts and date ranges

Requested 2026-10-21; priority to be agreed after the active task:

- Show each song's play count in Most played.
- Offer All time, last N days, last week, last month and a custom historical
  date range; preserve the selected configuration across restart.
- Apply the range consistently to displayed counts and ranking. Preserve the
  established qualified-listening rule and label the counting meaning clearly.
- Cover inclusive calendar dates, empty/invalid ranges, ties, persistence and
  qualification boundaries with failing tests before implementation.

## Artist pages — future feature

Requested 2026-10-21; backlog, outside the current metadata delivery:

- Click an artist credit to open the songs by that artist already in Ownsemble.
- Show an artist image only if the provider exposes an image bound to that
  artist; do not present album artwork as a verified artist portrait.
- Candidate additions: Play/Shuffle, album grouping when known, Offline filter,
  song/offline counts, listening count and recently played tracks.
- Preserve distinct artist identities and multiple credits; do not merge unrelated
  artists just because their displayed names match. Biographies and external
  discovery are separate optional work, not assumed metadata.

## Playlists and provider playlist import — future feature

Requested 2026-10-21:

- Support playlists alongside the existing duplicate-preserving Piles. Preserve
  list order and repeated occurrences; removing an occurrence must not delete
  the song, its cache or other list entries.
- Import VK playlists first, with stable provider/list identity, provenance,
  progress, partial/retryable outcomes and existing-data preservation.
- Every playlist and song retains its source/provider identity and origin link
  when supported; distinguish imported copies from a provider's original list.
- Verify actual VK playlist enumeration and membership before claiming support.
  Imported lists must not silently overwrite a user's edits or imply full import
  after a partial scan. Keep read-only import separate from changes to VK.
- Design provider boundaries for additional playlist sources later. Decide
  snapshot import versus optional continued synchronization explicitly.

## Queue mental model, deliberate listening sessions and saving them — undecided

Requested 2026-10-22 as a broad design direction, explicitly for the feature log:
the user finds the current queue confusing and questions why it repeats the visible
library's order. They want to add, for example, ten songs and hear just those songs
in the order added, independently of ordinary whole-library playback. They have
not chosen names, modes or a final model; do not turn this into fixed requirements
for a complex mode system without reviewing the design.

- Explain the useful distinction between a playback source/order (library, Pile,
  playlist or selected results), songs deliberately queued by the user, the
  currently playing item, and listening history. Source order can remain useful
  even when the user navigates elsewhere; the UI should make that reason clear.
- Explore a dedicated manual session/queue containing only explicitly added
  songs, with FIFO append order, visible upcoming items, reorder/remove/clear and
  preserved repeated occurrences. Adding ten songs must not silently place them
  behind the remaining 2,600 library songs or shuffle them without user intent.
- Consider one clear Up next view separating explicitly queued songs from source
  continuation, versus a separate manual session. Compare flows rather than
  assuming that multiple queue modes are the best answer. Define Add to queue,
  Play next and Start/replace queue distinctly; protect deliberate edits when
  starting playback from another source. Avoid silently losing a curated session.
- Make end behavior explicit: stop after the chosen songs, optionally continue
  from a clearly identified source, or replay only if repeat is enabled. The user
  must be able to choose a finite just-these-songs session.
- Explore Save queue/session as a playlist or duplicate-preserving Pile, before
  or after listening. Decide whether saving means the original session, remaining
  queue or actually played order, and label it clearly. An unobtrusive optional
  save action at the end is a candidate, not an agreed automatic prompt.
- Connect to listening patterns/modes later, while distinguishing an exact saved
  ordered list from an algorithm that generates a similar listening pattern.
  Preserve source/recording identity, occurrences, offline state, restart recovery
  and intentional shuffle/repeat behavior; saving never changes provider libraries
  or downloads all songs as an implicit side effect.
- Research/compare understandable flows during the dedicated queue/UI design
  stage, present options and use cases, then agree terminology/behavior. Tests
  first after selection: FIFO additions, duplicates, reorder/clear, finite ending,
  interruption/restart, source continuation and save/reopen order/data preservation.

This entry does not interrupt the active shortcut/hover-hint task and does not
claim that manual-session or save-queue functionality already exists.

## Lyrics discovery, candidates and verification — future feature

Requested 2026-10-21; separate from the current VK-supplied metadata work:

- Optional automatic lookup through supported lyrics sources, with appropriate
  sources for English, Russian and mixed-language songs. Use language/script and
  recording metadata; artist nationality alone must not determine language.
- Retain multiple candidates with source links, retrieval time, text, timestamps
  when available, recording/version match and an explainable confidence score.
- Rank by artist/title/album/version and language compatibility. Normalize texts
  for comparison and group duplicates. Cross-source agreement is supporting
  evidence, not proof: identical wrong text can occur in multiple results.
- Let the user preview, accept, reject, compare and replace candidates. Preserve
  chosen lyrics and rejected candidates across restart; user choice takes
  precedence over automatic ranking. Store successful selections for offline use.
- Distinguish original/studio/live/remix/cover/instrumental recordings; do not
  attach another recording's lyrics solely because a title matches.
- External lookup shares song information outside VK. Make that behavior clear
  and optional; do not send the private catalog wholesale or export account data.
- Tests first: false matches, alternate versions, Russian/English/mixed text,
  duplicate sources, ties, unavailable lyrics, offline use and persistent overrides.

## Local audio-file import — future source

Requested 2026-10-21:

- Import an audio file as a local source, with a provider-independent track model.
  Read supported embedded tags/artwork and measured audio properties; retain
  honest filename/unknown fallbacks where tags are missing.
- Preserve original files by default. Validate decoding and full-file integrity
  before publishing the app-managed copy; retain source provenance/import date.
- Handle identical bytes and alternate recordings deliberately, preserving list
  occurrences and existing metadata rather than silently merging by title.

## YouTube source and multi-source song search/download — future feature

Requested 2026-10-21:

- Add YouTube as a source alongside VK and local files, using stable source IDs
  and a source interface that can support further providers.
- Search by title with an optional artist. Present candidate recordings with
  provider/source link, artist, title, version, duration and available artwork.
- Rank and explain recording matches using title/artist, studio/live/remix/cover
  distinctions, duration, album and reliable recording identifiers when supplied.
  Cross-source agreement/fingerprints can support verification; title similarity
  or several copies of one result cannot guarantee the correct recording.
- Offer preview and explicit version selection when ambiguous. Optional automatic
  download is for sufficiently verified matches; preserve the exact chosen source
  identity and do not silently substitute a different recording after failure.
- Keep candidate search separate from committed library records. After selection,
  download, validate full decoding/duration/integrity, publish atomically and retain
  provenance so the user can verify or replace the result later.
- Include cancellation, bounded requests, retries, unavailable/version conflicts,
  wrong-duration results, partial files, duplicate content and offline restart in
  tests before implementation. Provider-specific access limits remain explicit.

## Combined metadata/source filtering and sorting — future feature

Requested 2026-10-21; propose useful combinations and agree priorities after the
active task. Only offer fields/providers that are actually supported.

Filter candidates:

- Source/provider (VK, local files, YouTube later); account/list/Pile provenance
  where supported. Distinguish a source from an app-managed offline copy.
- Favorite/unfavorite, with an explicit date-favorited range. Keep this date
  separate from import/upload/release and listening dates. Decide whether the
  filter uses the latest active favorite event or historical favorite events;
  preserve history rather than inventing a date for existing records.
- Title/artist/album/version text, individual artist credits and album selection.
- Imported into Ownsemble, verified VK-added date if ever available, upload date
  and release date/year as SEPARATE fields. Date intervals and relative windows.
- Offline/uncached, pinned/unpinned, restricted/unresolved/error state.
- Lyrics: not checked, advertised, cached plain/synchronized, not supplied, failed;
  artwork: cached, observed but not cached, unknown/unavailable. Missing metadata.
- Duration/size ranges; play count, last played, never played and selected listening
  period. Language/genre/technical properties only if a reliable source supplies them.

Sorting candidates:

- Existing provider order; import date oldest/newest; verified provider-added,
  upload and release dates separately; title, artist, album, version; duration,
  cached size; plays within selected period, last played and never-played first.
- Multiple levels such as Artist -> Album -> track number when known, otherwise
  title; Release year -> Artist -> Album; Import date -> Title. Stable ties.
- Unknown values stay explicitly identifiable and normally last in either order;
  handle Cyrillic/Latin case and numeric title components consistently.

Combination examples:

- Recently imported + VK + available offline.
- Pinned + selected artist/album; uncached + long duration.
- Most played in the past 30 days + offline; never played + newly imported.
- Missing cached lyrics/artwork + source or import-date interval, with unknown
  coverage distinguished from a confirmed absence.
- Release-era browsing independent of when a track was uploaded or imported.

Use AND across filter groups and OR within selected values, visible active chips,
result counts, clear/reset and saved presets. Filter local stored metadata without
starting a full provider scan; explain partial enrichment coverage. Preserve the
chosen filters/sort consistently when playing/shuffling the resulting collection.

## Dedicated sync status/control — future UI improvement

Requested 2026-10-21. Current library progress can be mistaken for song loading.
Proposed placement: upper-right library-header corner, replacing/integrating the
existing refresh control; agree order with the user after the active task.

- Small sync icon spins only during VK sync. Player loading/buffering remains
  tied to the selected audio, visually distinct from metadata work.
- Idle/success/partial/offline/error states have clear icons/tooltips; no permanent
  ambiguous page-wide loading bar. Avoid success/completeness claims for partial sync.
- Clicking opens a compact status popover: current phase, last check, checked/new
  counts, partial coverage and any actionable fixed error category.
- Include a short "Check newest" action and an explicit deeper/full refresh action,
  rather than making an unexplained click unexpectedly scan the whole library.
- Preserve keyboard/accessibility labels, disabled/running actions, cancellation,
  local-first usability and responsiveness while audio plays.

## Favorites and clearer permanent-download controls

Requested 2026-10-21; fit these naturally into the existing library/player:

- Add an identifiable favorite button and a Favorites collection/filter. Favorites
  express preference; keeping an offline copy expresses storage intent. They may
  be combined, but neither should silently imply the other.
- Retain favorite timestamps/history for date-range browsing and reports. Define
  remove/re-add behavior explicitly, preserve data across restart and avoid
  inventing historical dates when migrating older records.
- The current pin icon/purpose is unclear. Explore a download/keep-offline icon
  and clear labels for downloading, cached, and kept offline until explicitly
  removed. Explain automatic cache versus a protected permanent download.
- Changing a label or icon must preserve existing pins and protected cached audio.
  Removing a download, removing a favorite, and deleting a library song must have
  distinct, predictable effects.

## Response-time benchmarks and large-library performance

Additional report/proposal 2026-10-22: the user sees 2–3–10 MB downloaded before
hearing anything and asks for earlier playback instead of waiting for the full
song. An uncached streaming path already exists, but that alone does not establish
that this case uses it correctly. Queue an investigation/optimization of time to
first audible output, including recent/old recordings and legacy-cache revalidation.
Measure source resolution, first bytes, playable prefix, identity verification,
native open/buffering/first output, and full-cache completion separately. Check
whether a full-download branch or decoder buffering causes this symptom rather
than inferring a cause from byte counts. Use throttled/variable-network fixtures
and both cold/warm cases; prove playback begins from a small identity-bound buffer
well before completion when feasible. Retain full validation for offline publication
and the exact-recording/legacy-file-preservation protections. The user explicitly
requested logging this proposal without interrupting the shortcut task. It fits
the proposed performance stage; no startup-speed improvement is claimed yet.

Requested 2026-10-21; also see KNOWN_ISSUES.md for reported queue/menu lag:

- Measure click-to-feedback and click-to-completion for critical controls: song
  Play/pause/Stop/seek, queue opening/scrolling, song options, search/filter/sort,
  sync controls, favorites/downloads and details/lyrics/artwork loading.
- Establish reproducible baselines for large libraries/queues (including 2,630+
  songs and larger generated stress cases), cold/warm launches and cached versus
  uncached audio/artwork. Record frame timings, latency distributions and bounded
  memory/work rather than judging responsiveness only by average duration.
- Separate deterministic local/UI regression budgets from provider/network time.
  Use controlled fast/slow/offline/failure network fixtures; report live timing
  with environment/cache state and do not fail a UI benchmark solely because the
  user's network or VK is slower. Track median and tail latency against a baseline.
- User reports long queue scrolling lags and a large delay opening the three-dot
  menu. Reproduce with generated large queues and test before fixing. Avoid
  rebuilding/laying out the entire catalog for one visible interaction.
- Restyle the options inside that menu to match the app, including spacing,
  typography, hover/focus/disabled states and accessible targets.
- Artwork feels slow. Investigate the current thumbnail path now: observe first
  visible cover latency, avoid unnecessary serial waits, prioritize visible rows
  and the player, reuse valid cached images and bound concurrency without blocking
  playback or weakening validation. Broader performance work remains queued.
- Explicit fast-scroll requirement (2026-10-21): do not leave a backlog of covers
  from rows the user swept past. Use actual viewport visibility and a short dwell
  delay; prioritize the current viewport/player, drop obsolete queued work and
  cancel obsolete active work when safe. Keep completed cache entries for reuse.
  Test rapid jumps, settling at a destination, shared artwork and return scrolling.

## Verified genre/mood enrichment and listening reports

Requested 2026-10-21; suggestions below are candidates, not implemented claims:

- Optional genre discovery alongside lyrics/metadata, with source provenance,
  multiple tags, confidence and user confirmation/correction. Genre may differ
  by recording/version; do not label a guessed tag as verified.
- Explore mood tags such as sad/upbeat/calm/energetic, clearly distinguishing
  provider tags, inferred classifications and user choices. A song tag does not
  establish the listener's emotional state. Keep unknown and disputed values.
- Attractive song-level and library-level listening views for week/month/year or
  any historical date range: listening timeline/calendar, top songs/artists/albums,
  genre/mood mix, repeats/loops, rediscoveries, new versus familiar music and change
  over time. Candidate plots: calendar heatmap, time-of-day/week pattern, trend
  lines and transitions between songs/artists/genres.
- Define qualified plays/listening time consistently with existing history;
  explain partial history, missing metadata and sample sizes. Preserve timezone
  and date-boundary semantics. Do not turn missing tags into a misleading report.
- Start with readable useful views and drill-down to the underlying songs and
  plays. Let users inspect, correct or exclude inferred tags before relying on
  them for reports or listening modes.

## Listening modes beyond shuffle

Requested 2026-10-21:

- Modes such as rarely listened, never played, most listened, rediscover older
  favorites, and recreate/explore listening patterns from a chosen past interval.
- Explore an explainable smart ordering that uses verified local history and
  selected filters/tags, with controls for familiarity, variety and repeats.
  Historical sequence replay and a newly generated similar sequence are distinct.
- Preview the resulting queue/reason for selection; preserve ordinary manual
  queue edits, allow exit/reseed and handle sparse history/offline availability.
  Avoid repeatedly cycling the same tiny group unintentionally.

## Clickable volume icon / mute

Delivered and verified 2026-10-21, including native output-volume state and restart
restoration; see CONTROLS_UI_FIXES.md.

Requested 2026-10-21. The speaker icon should act as a mute/unmute control, show
the correct icon/state and restore the previous nonzero volume when unmuted.
Keep the slider and keyboard/accessibility feedback consistent; do not silently
replace the user's saved volume. Icon controls should have clear click semantics.

## Thorough UI/UX research and redesign variants

Requested 2026-10-21 for a future dedicated phase. The current UI feels "AI-ish"
to the user; they want a considered rework, not incidental cosmetic patches.

- Research Spotify, Apple Music, leading music/media apps, respected designers
  and strong UI/UX work internationally in depth at that stage. Use current
  primary examples and inspect actual interaction flows, not just screenshots.
- Study information hierarchy, library/queue navigation, dense large-library
  browsing, search/filter/sort, player controls, metadata/artist views, sync and
  download status, menus, typography, spacing, color, motion and empty/error states.
- Explain what works and why, including keyboard use, accessibility, responsive
  layouts, perceived speed and consistency. Fit findings to Ownsemble's local-first
  library, multiple sources, Piles/duplicates and offline retention semantics.
- Present several coherent, polished redesign variants with representative
  populated screens and interactions. Compare tradeoffs and review with the user
  before selecting a direction and migrating the UI. Preserve existing data and
  behavior; do not copy another product's branding or substitute a generic template.
- Plan visual/interaction regression checks and large-library performance budgets
  alongside implementation. This research/rework is logged, not started now.

## Provider recommendations and optional saving back to sources

Requested 2026-10-21; future work, not a change to the current task:

- Explore listening to recommendation feeds from VK, Spotify and other supported
  providers inside Ownsemble, retaining each feed/candidate's source and recording
  identity. Verify actual access and playback capabilities per provider before
  promising support; one provider's library access does not establish another's.
- Let the user save a chosen recommendation into Ownsemble. Explore a separate
  explicit action to add it to its VK/Spotify/other source library or playlist
  where a supported authenticated write capability exists. Merely playing a
  recommendation must not silently mutate an external library or enable downloads.
- Also explore intentional opt-in auto-save while listening, configured separately
  for each destination, with a clear qualifying event, visible outcome and an undo
  path where supported. This never follows merely from connecting an account.
- Explain available save destinations and preserve provenance, duplicate/version
  handling, partial failures and user edits. Account writes require the user's
  intentional authorization; reading a recommendation is a separate capability.
- Keep provider feeds distinguishable; optionally compare or combine them with
  clear attribution and controls for repeats, unavailable songs and offline use.

## Stage-level diagnostics without UI overhead or sensitive data

Requested 2026-10-21; extend existing sanitized diagnostics deliberately:

- Trace critical operations through named stages with operation correlation,
  timing, counts, outcome and stable error categories. Cover route/form guards,
  music-page readiness, adapter/schema matching, identity binding, source lookup,
  download, decode/integrity, cache publication, native playback, sync, artwork,
  lyrics and persistence. Detect unsupported provider layout/schema changes and
  report which contract/stage failed instead of a generic infinite loading state.
- Make reports useful for VK website/API changes and failures elsewhere in the
  app: distinguish timeouts, cancellations, offline state, provider restriction,
  missing data, permission failures and unexpected internal errors. Record app/
  adapter version and bounded recent context for reproduction.
- Preserve privacy: never log credentials, login-field values, cookies/tokens,
  authentication responses, private catalog contents, lyrics text or temporary
  media/image URLs. Do not use broad DOM dumps, private profiles or sign-in
  screenshots. Detail comes from stages/contracts and synthetic reproduction.
- Use a bounded in-memory buffer, event coalescing/sampling, background batched
  writes, rotation/retention limits and an explicit safe export path. Avoid
  synchronous per-frame/per-byte disk writes or full-catalog work for logging.
- Benchmark instrumentation enabled/disabled under large-library and slow-disk
  fixtures. Tests cover redaction, size limits, failure isolation, useful stage
  attribution and cancellation, so diagnostics cannot break or stall playback.
