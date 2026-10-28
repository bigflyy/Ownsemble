# Reported issues

- Shuffle playback reliability (2026-10-27): a muted uncached selected attempt
  reproduced a 30-second source-resolution timeout while the independent music
  page took 32.375 seconds to warm. The baseline did not isolate queue mode;
  this is a shared-path suspect, not proof of a shuffle-order defect. The repair
  allows an exact-ID request on the already-consented main music page when the
  standby remains cold, preserving current-source priority and all identity,
  native-mute, HTTPS/CDN and cache guards. Follow-up paired checks BOTH failed on
  the same rejected CDN-to-VK-web redirect, with exact selection preserved. A
  bounded same-recording current-discovery retry is implemented and source-tested.
  New Release passed a same-process uncached normal/shuffle full-queue pair at
  2971/1483ms, a separate uncached complete-cache/control check and cached old-tail
  controls. These warm/current-source passes do not establish that the rejected-
  reference recovery branch recovered the earlier failed recording; that branch
  currently has controlled generated acceptance. Fixed silent queue probes
  compare one exact internal identity in normal and shuffled modes and restore
  the prior queue without listening history. See SHUFFLE_PLAYBACK.md for scoped
  evidence and remaining live/platform/latency gates. No full-library playback
  certification or source substitution; other provider failures remain possible.

- Repaired uncached Windows CDN compatibility (2026-10-23): a deep-library sample bound the exact
  recording source, then failed opening its local relay after 8,519 ms with no
  upstream bytes observed. The UI category was decoder_open_failed, which can
  conceal an upstream transfer failure. Cached controls pass; uncached playback
  was an active release gate. Diagnose the original transfer category/status
  before changing TLS, source allowlists or identity verification.
  Follow-up: preserve HTTP status and the relay's original transfer failure;
  unload failed media and ignore late cleanup from superseded Play requests.
  Tests reproduced both stuck buffering and late cleanup before correction.
  Fresh live attempts also exposed audio_destination_rejected and source-resolution
  timeouts. The exact selected row exposes an opaque HTTPS okcdn.ru source that
  the older CDN/filename policy did not accept. The compatibility repair now
  handles that fixed CDN suffix and detects opaque response format while preserving
  identity/TLS/cache checks. Five uncached samples, including deep/old recordings,
  played and reached cache publication. Cold first sound still took 15.2 seconds;
  warm old samples took 3.6–5.1 seconds. See VK_OPAQUE_AUDIO.md for scoped evidence
  and remaining performance/platform gates.

- Delayed first sound despite several MB received (2026-10-22): user observes
  2–3–10 MB downloaded while still silent and suspects a complete-download wait.
  Streaming exists, but branch selection/prefix/verification/native buffering
  must be measured to establish why this happens. Logged for the performance
  stage, alongside early-start optimization; not investigated/fixed by the active
  keyboard/hover-hint task. Preserve exact-recording and offline-publication checks.
  Update 2026-10-24: a generated native MP3 test reproduced an EOF metadata probe
  blocking on the full sequential download. Growing-response framing reduced the
  same fixture from 6,343 ms to 343 ms, preserving seeking and one upstream request.
  See PROGRESSIVE_STARTUP.md. This does not certify every provider/network case.

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
- Thumbnail appearance feels slow. Re-reported 2026-10-28 and queued after the
  active first-attempt playback investigation. Earlier viewport-aware work has
  not resolved the renewed user report. Originally reported 2026-10-21; investigate during the
  active artwork task. Measure cache/network/queue delays separately and preserve
  image validation, privacy and playback responsiveness.
- Speaker mute/unmute is now implemented and verified, including remembered volume
  and restart persistence; see CONTROLS_UI_FIXES.md.
- Pin icon purpose is unclear to the user. Clarify permanent-download semantics
  without changing or losing current pinned audio; see FEATURE_LOG.md.
