# Search, mute, saved status and artwork previews

Completed 2026-10-21. The user selected implementation-plan step 1, then added
SAVED/column alignment and clickable thumbnails to the same slice.

## Result

- Space reaches focused text editors. Outside text editing it remains the global
  playback shortcut; Ctrl+K still focuses search. The former CallbackShortcuts
  binding consumed Space even when its callback chose not to toggle playback.
- The speaker is a labeled mute/unmute button. It remembers the previous nonzero
  volume, follows slider changes and restores that value after restart. Desired
  state updates immediately; native writes are serialized to preserve rapid-click
  order. Values are bounded to 0–100; nonfinite values are ignored. Volume changes
  do not invalidate the library row cache. Existing saved volume is preserved.
- SAVED displays one primary status: active preparation/retry, otherwise an error
  if present, otherwise saved audio, otherwise a dash. An error tooltip explains
  when a saved copy remains. Errors/files are retained; the fix does not hide
  contradictory state by deleting data. The separate pin control retains storage
  intent without adding another SAVED icon.
- Header and rows share widths/padding for play/#, artwork/title, SAVED, duration
  and actions. Status and duration are centered; title headings align to song text.
- Cached library/player covers open a larger recording-bound artwork dialog with
  zoom/pan and Close/Escape. It uses only the existing validated cached image;
  opening it makes no external lookup and does not change selection or playback.
  Placeholders are not clickable. Enlargement does not create higher-resolution art.

## Evidence

Regression tests were written and observed failing before production changes:
.local/ownsemble/controls-ui-red.txt and artwork-preview-red.txt. Widget async
cleanup was subsequently refined to progress both simulated and real async zones;
the interrupted/harness-failure logs remain. Additional native acceptance checks
were added after implementation and are not described as tests-first evidence.

- 155 Flutter tests and 48 adapter tests pass; analyzer/formatter clean.
- Hardware-key routing and multiword filtering, Ctrl+K/global Space, mute/slider,
  zero/invalid values, rapid changes, restart persistence, status exclusivity,
  file/error retention, and alignment at 1080/1440 widths are covered.
- Cached row/player artwork previews pass offline, including zoom controls,
  selected-recording binding, unchanged playback/queue and Close/Escape.
- Both Debug and Release generated native checks pass, including actual native
  zero/restored volume, restart restoration, play/seek/next/previous and retention.
- Final normal Release main-player cached controls/replay passed: 886 ms to first
  audio and zero received bytes. This is a scoped playback regression sample.
  Existing decoder diagnostic signals remain in the report despite passed controls.
- Source, bundled adapter and both compiled outputs match. Normal Release was
  left paused with no loading; original volume 35.820896 was retained.
- Final aggregates: 2633 tracks, 34 assets, 6 verified assets, 1 Pile/1 occurrence,
  0 pins, 89 plays; SQLite quick_check=ok. The before/after slice counts are equal
  for tracks/assets/Piles/occurrences/pins/plays; user activity before this slice's
  baseline had added assets/listens and was preserved.

Consolidated sanitized report: .local/ownsemble/controls-ui-validation.json.
Generated previews (no account data): .local/ownsemble-smoke/preview.png and
artwork-preview.png; both were viewed. No profile/sign-in screenshot was taken.

## Queued separately

The user confirms VK has lyrics for a song while Ownsemble fails to extract them.
This is a confirmed extraction bug, recorded in KNOWN_ISSUES.md and FEATURE_LOG.md.
It remains unresolved; a missing extraction must not be described as provider
absence. Current metadata dates remain in Song options -> Song details & lyrics;
import dates are retained, upload date is separate and a VK collection-added date
has not been verified. No additional backlog milestone was silently started.
