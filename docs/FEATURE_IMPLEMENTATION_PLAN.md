2026-10-27 checkpoint: the local queue/menu performance slice and clear sync,
connection/download status slice are delivered; see UI_PERFORMANCE.md and
LIBRARY_STATUS.md for exact scope. Native FPS/network distributions remain open.
Recommended next corrective task: confirmed VK lyrics extraction failure, before
larger UI research or new feature screens. The user must select the next slice.

Current priority 2026-10-22: the user selected cross-platform-friendly architecture
before further feature implementation. See ARCHITECTURE.md, ADR0001 and the latest
handoff. Browser/provider/playback/runtime/trust boundaries are implemented; full
Linux/Android ports are separate acceptance work. The numbered feature order below
remains a proposal after this selected milestone; do not silently start it.

# Proposed feature implementation order

Proposed 2026-10-21. The user selected step 1, additionally requesting exclusive
SAVED states, column alignment and clickable artwork previews. That slice is now
completed (see CONTROLS_UI_FIXES.md); later milestones remain proposals. FEATURE_LOG.md retains all requests.

2026-10-22 extension: the user requested additional keyboard shortcuts, hover hints
and protection from text-entry conflicts. This is a keyboard usability pass within
step 1 (KEYBOARD_USABILITY.md). Recommended next: step 2, including measured
queue/menu response and the newly logged delay-before-sound/early-streaming-start
proposal. The user requested that performance proposal be logged, not that it
replace the active shortcut task. VK lyrics extraction remains a separate bug.

The current recording/cache repair and metadata delivery passed scoped acceptance;
see RECORDING_INTEGRITY.md, METADATA_ENRICHMENT.md and the latest SESSION_HANDOFF.md.
Live VK lyrics retrieval, the original restricted recording and universal catalog
coverage remain unproven or unavailable as documented. Existing legacy downloads
are retained and require online identity verification when first selected.

## Suggested order

| Order | Deliverable | Reason and acceptance |
| --- | --- | --- |
| 1 | Search spaces and speaker mute | Fix daily input/control failures first. Space inserts text in focused editors without toggling playback; the global shortcut still works elsewhere. Mute/unmute restores the previous nonzero volume and survives restart consistently. |
| 2 | Responsiveness baseline, queue/menu fixes and diagnostic gaps | Establish generated large-library measurements before optimization; reproduce queue scroll and menu latency, then fix the measured bottlenecks and menu styling. Separate UI time from provider time. Add bounded stage diagnostics where failures are currently ambiguous. |
| 3 | Clear sync and download status | A dedicated sync control/popover distinguishes background checks from song preparation, shows last outcome and offers an explicit deeper refresh. Clarify automatic cache versus protected downloads while preserving pins, files and first-use verification state. |
| 4 | UI/UX research and variant review | Research current leading products and actual workflows, then present coherent variants covering dense browsing, queue, player, status, details and menus. Choose a direction before building large new screens; small urgent fixes above remain independently useful. |
| 5 | Favorites, Most played counts/ranges and metadata filters | Define timestamps and counting semantics first. Add favorites/history, consistent date-range counts/ranking, stable multi-field sorting and composable filters over supported metadata. Use the chosen design direction. |
| 6 | Artist pages and local playlists | Build browsing and organization on verified credits and existing tracks. Preserve distinct identities, playlist order and repeated occurrences; removing an occurrence must not delete audio or library records. |
| 7 | VK playlist import and local-file import | Deliver as separate milestones. Verify playlist enumeration/membership with bounded probes; choose snapshot versus continued sync explicitly. Local import preserves originals and validates copied audio/tags/artwork before publication. Both retain provenance and partial outcomes. |
| 8 | External lyrics discovery, then optional genre/mood | Start with recording-bound candidates, preview/accept/reject and persistent overrides for Russian/English/mixed-language material. Make external lookup explicit. Add tags only with provenance and correction; unknown data remains unknown. |
| 9 | Listening reports and additional listening modes | Reuse tested history/date/filter semantics. Start with useful counts/timelines, then richer reports and explainable rarely/never/most-played or historical-pattern queues. Show missing-history/tag coverage. |
| 10 | YouTube/multi-source search and provider recommendations | Probe each provider's actual capabilities before committing to support. Keep candidates separate until a recording is chosen. Retain identity/version/provenance and never silently substitute audio. Treat optional saving back to providers as a separate explicit capability. |

UI research may move earlier if the user wants design work next. External lyrics
may move ahead of organization once a suitable explicit lookup flow is agreed.
These are prioritization choices, not technical prerequisites for every later item.

## First implementation slice

Recommended next slice: search spaces and mute only. For search, first write failing
widget tests for multiword input, focused text controls, and the unfocused playback
shortcut. For mute, first cover zero/nonzero transitions, previous-volume restore,
slider interaction and restart persistence. Then implement, run the relevant tests
and analyzer, build the opposite output mode while the normal app runs, and finish
with generated native controls before updating the normal Release build.

## Acceptance for each milestone

- Write meaningful failing behavior tests before changing production behavior.
  Keep generated fixtures separate from real catalog data.
- Test controlled failures, cancellation, persistence and offline behavior where
  applicable. Keep identity, privacy and existing-data preservation contracts.
- For performance, use reproducible 2,633-row and larger generated workloads;
  measure click-to-feedback, completion, frames, memory and median/tail latency.
  Establish budgets from a recorded baseline rather than inventing a universal
  network latency guarantee. Test slow/offline/failing network fixtures separately.
- Keep optional enrichment and diagnostics bounded and independent of Play.
  Extend sanitized stage reports without logging account content or media URLs.
- For provider changes, use bounded feasibility probes and fixed app-owned controls;
  record unsupported capabilities and sampled coverage honestly. No manual song
  clicks or error transcription are required from the user.
- Align production source, bundled adapters and both builds before release claims.
  Preserve recovery artifacts and update the handoff with evidence and limitations.

The original proposal preceded implementation. Subsequent work follows the user's
explicit choice of step 1 and the additional controls/layout/artwork requests.
