# Incremental VK refresh

Implemented 2026-10-21. Automatic refresh of an existing catalog no longer starts
repeated full-library sweeps. It checks the newest entries against a persistent
local checkpoint. Playback and refresh remain independent.

## Behavior

- Startup and two-minute automatic refresh reload the recognized personal music
  page in the retained, natively muted WebView. No session data is exported.
- The checkpoint contains up to 128 ordered music IDs, stored only in the local
  application database. It contains no source URLs, cookies or access references.
- A check merges arriving metadata and stops when 12 consecutive IDs match their
  saved order. Smaller saved blocks require the whole block to match. One familiar
  row or an arbitrary collection of known IDs is not sufficient.
- Scanning has limits of 256 unique rows, eight reads/pages and 15 seconds, with
  shorter pagination waits. Page navigation/preparation has separate bounds.
- Successful overlap updates the checkpoint. An existing catalog without one
  seeds it from fresh top rows without walking the old tail. Very short lists
  wait for a quiet boundary. Failed or unmatched checks keep the old checkpoint
  and display an incomplete-check message; they do not become full sweeps.
- Initial import and manual Refresh VK still use broad discovery in bounded
  slices. Initial-import pending state survives restart. A normal completed
  manual sweep returns scheduling to short head checks. All unseen tracks remain.

## Verification

104 Dart tests pass, including additions before the saved block, overlap across
virtualized windows, reordered rows, a 256-row unmatched prefix, page/time limits,
short/legacy libraries, persisted checkpoints, startup scheduling, failure
preservation, manual continuations and initial-import restart. Analyzer and
formatter are clean. All 38 JavaScript guard fixtures pass unchanged.

Real application with 2633 saved tracks:

| Check | Result |
| --- | --- |
| First automatic checkpoint | 115 rows checked; no new tracks; 8518 ms including page preparation |
| Repeated newest check | 115 rows; known block found; 5637 ms |
| Debug restart | Loaded 115-ID checkpoint; 115 rows; known block found |
| Cached playback during refresh | 1018 ms, nonzero Ownsemble audio output |
| Final Release uncached playback during scheduled refresh | 1758 ms; nonzero output; complete cache |
| Final corrected Release startup | Loaded checkpoint; 115 rows; known block found; 13564 ms |
| Final corrected Release cached playback during refresh | 603 ms; nonzero output |
| Corrected Debug two-minute scheduled cycle | 115 rows; known block found; 5798 ms |
| Corrected Release two-minute scheduled cycle | 115 rows; known block found; 6119 ms |

These are measured samples. The current real account supplied no new additions
during the checks. Addition detection is tested with generated data; a genuinely
new live VK addition remains a separate acceptance gate. The algorithm checks a
newest-first prefix; older edits/reorders beyond it require a deeper scan. A burst
larger than the head budget remains partial and can be reconciled manually.
It does not claim full provider coverage or every-recording availability.

Safe reports: .local/ownsemble/sync-status.json, sync-head-bootstrap.json,
sync-head-repeat.json, sync-head-after-restart.json, sync-head-with-uncached.json,
sync-head-release-navigation-fixed.json, sync-head-debug-scheduled-fixed.json,
sync-head-release-scheduled-fixed.json, sync-head-concurrent-play-uncached.json,
sync-head-concurrent-play-current.json. Reports expose categories/counts/timings
only. The checkpoint itself must not be printed by agent tools.

The first actual two-minute cycle exposed a failure before reload:
private_signin_required, zero rows, 235 ms. It is preserved as
sync-head-scheduled-initial-failure.json. Regression tests reproduced validation
of the old document before fresh navigation. Top checks now verify only the
approved music route on the old document, reload, then apply the full route/form/
personal guard before any extraction. A real sign-in form after reload still
stops access; no guard was relaxed. Debug startup with the correction checked
115 rows and reached its checkpoint; its actual two-minute scheduled cycle then
passed in 5798 ms. Final corrected Release startup also passed; its scheduled
cycle passed in 6119 ms and is recorded in sync-head-release-scheduled-fixed.json.
The final sanitized summary is incremental-sync-validation.json.

Both builds and packaged adapter assets are current after rebuilding. Real data, cache, Piles,
listens, privacy guards, source identity and cache-integrity requirements remain.
The original VK-restricted recording still cannot play; this change does not
claim otherwise. The tests-first development rule is recorded in AGENTS.md.
