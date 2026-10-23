# Reported issues

- Uncached Windows playback (2026-10-23): a deep-library sample bound the exact
  recording source, then failed opening its local relay after 8,519 ms with no
  upstream bytes observed. The UI category was decoder_open_failed, which can
  conceal an upstream transfer failure. Cached controls pass; uncached playback
  remains an active release gate. Diagnose the original transfer category/status
  before changing TLS, source allowlists or identity verification.

- Delayed first sound despite several MB received (2026-10-22): user observes
  2–3–10 MB downloaded while still silent and suspects a complete-download wait.
  Streaming exists, but branch selection/prefix/verification/native buffering
  must be measured to establish why this happens. Logged for the performance
  stage, alongside early-start optimization; not investigated/fixed by the active
  keyboard/hover-hint task. Preserve exact-recording and offline-publication checks.

- Completed 2026-10-21 controls/UI slice: search spaces, clickable speaker mute,
  overlapping success/failure indicators in SAVED, and header/row alignment
  (including the duration clock). The user also requested clickable artwork
  previews. 155 Flutter/48 adapter tests, both builds and generated native checks
  pass; final normal Release cached controls pass. See CONTROLS_UI_FIXES.md.
  All existing data and privacy protections remain.

- VK lyrics extraction: user confirms lyrics are available for a song in VK,
  but Ownsemble fails to retrieve them (2026-10-21). This is a confirmed retrieval
  bug, not a provider-lyrics absence. Queued separately from current controls/UI
  fixes; preserve exact-recording binding, cached lyrics and playback independence.
  See FEATURE_LOG.md for scope and required validation.

- CRITICAL — wrong recording under the selected song: user reports selecting
  "Край" but hearing "Один в поле" (the next song); selecting "Один в поле"
  also plays that recording. Reported 2026-10-21 during metadata work. Stop
  playback, preserve data/evidence, and investigate source/native/cache identity
  before further feature work. Do not claim that import or playback is reliable
  based on previous sampled passes. Regression tests must precede the fix.
  Update 2026-10-21 13:21 UTC: repaired and verified on the reported pair plus an
  old sample, including fresh Release offline playback. Identity receipts, exact
  source binding and duration checks now gate use. Legacy files are preserved and
  require online verification before offline eligibility. See RECORDING_INTEGRITY.md;
  this is not a claim that every saved recording was individually checked.

- Search field: pressing Space does not insert a space, so multi-word search
  could not be typed normally. Reported 2026-10-21; fixed with hardware-key routing
  regression coverage. Global Space remains available outside text editing.

- Large queue: scrolling lags and opening a song's three-dot options menu has
  noticeable latency. Reported 2026-10-21; reproduce with generated large-library
  benchmarks and failing regression tests before implementation. The menu's
  internal button styling also needs to match the application.
- Thumbnail appearance feels slow. Reported 2026-10-21; investigate during the
  active artwork task. Measure cache/network/queue delays separately and preserve
  image validation, privacy and playback responsiveness.
- Speaker mute/unmute is now implemented and verified, including remembered volume
  and restart persistence; see CONTROLS_UI_FIXES.md.
- Pin icon purpose is unclear to the user. Clarify permanent-download semantics
  without changing or losing current pinned audio; see FEATURE_LOG.md.
