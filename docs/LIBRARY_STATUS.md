# Library sync, connection and download status

The top-right sync control opens a live status panel. Its icon rotates only while
VK enumeration is active, resets upright when idle, and honors reduced motion.
The former page-wide sync progress bar and unexplained full-refresh button are
removed. The selected song's controls and audio progress remain separate.

## Explicit actions and outcomes

- Check newest always requests a bounded newest-entry check, including during an
  unfinished initial import. It cannot silently fall back to a full scan.
- Scan full library explicitly requests deeper enumeration. Partial/time-limited
  slices remain partial, with a continuation notice and Stop sync between slices.
- While a full scan is waiting between slices, scan-switching actions are disabled.
  Stop remains available before selecting a different scan mode.
- Stop sync invalidates late merges/results, stops provider enumeration, and
  retains all already imported rows. An unfinished initial import stays paused;
  future scheduled checks remain bounded. Explicit full scan can resume it.
- The panel shows received/new counters during work, checked/new counters for the
  result, the last attempt time, actionable failure text, and coverage limitations.
  A successful newest check attests only that check. Full coverage still requires
  the existing unique provider-end witness. Prior full-listing evidence is dated.
- Offline/disconnected/connecting states disable scan actions. Opening either
  panel performs no scan, connection attempt, sign-in or playback action.

AppController stores only the last terminal attempt in the additive
`last_sync_result` setting: phase, mode, checked/new counts, timestamp, and an
allowlisted outcome category. No schema replacement, track IDs, provider messages,
media URLs or credential data are added. Missing/corrupt/interrupted state restores
idle; it never invents a result or resumes a spinner. Active work is in memory.
Old diagnostics and incremental checkpoint/coverage contracts remain in place.

The MusicProvider cancelSync port stops enumeration separately from the audio
resolver. The VK adapter raises its existing scanner-yield flag. Controller
operation generations reject late merges, completion or errors after Stop,
offline/disconnect or shutdown, even if the backend replies late. Native backend
unwinding can take time; the panel says Stopping sync until that operation ends.

## Connection and offline music

The connection badge opens explicit Connect/Reconnect, Disconnect VK and Sign in
privately controls. Clicking the badge itself changes nothing. Disconnect disables
automatic reconnection and uses the existing offline cleanup path; it preserves
tracks, pins, cached files and the dedicated browser sign-in. It does not log out
of the provider account. Connect explicitly returns online and enables automatic
checks. After private sign-in, the panel explains the return-to-app Connect step.
Connection failures remain in the connection panel, separate from audio feedback.

## Download intent and progress

Row download icons replace individual pin icons. Keep offline retains the same
protection; Allow automatic cleanup releases only the individual protection. A
Pile can still protect the recording. Releasing protection can allow quota cleanup;
it does not mean removing a library track or changing favorites.

Saved indicators distinguish automatic cache and kept audio. An unsaved kept
recording shows waiting-to-download, an active transfer shows progress, and a
failure replaces the success indicator while retaining the saved copy if present.
These indicate storage state, not a new assertion of exact-recording verification.
The existing first-use/legacy identity checks remain mandatory. The audio footer
retains download progress/cancellation; cancelling uses the existing playback-stop
and download-cancellation behavior. No media/cache algorithm was replaced here.

## Validation

Tests were observed failing before the corresponding implementation fixes. They
cover sync/audio separation; head/full and partial/end distinctions; bounded
explicit checks during unfinished import; cancellation during and between slices;
late responses after offline/shutdown; corrupt summary restoration; retry;
restart persistence; safe summary fields; retained generated cached bytes and
pins on disconnect; stale connection completion; sign-in errors; download status
exclusivity; large text, Escape, rendered badge font and upright idle icons.

Generated panel previews are written under ignored `.local/ownsemble-smoke/` as
`status-sync-preview.png` and `status-connection-preview.png`. The silent test
playback engine opens no media/audio device; no real provider/profile is inspected.
Native generated smoke, builds and real-account acceptance are separate gates.
This UI milestone does not claim a live VK playback or cross-platform acceptance.

Repeat generated checks from the repository root:

```sh
bash scripts/app.sh test --no-pub test/library_status_test.dart test/sync_activity_test.dart test/incremental_sync_test.dart
bash scripts/app.sh test --no-pub --concurrency=1
bash scripts/app.sh analyze --no-pub
```

The final suite passes 302 Flutter tests, including the 36 focused status/sync
checks. The unchanged adapter suite passes 81 Node tests. Analyzer and format
checks are clean. Windows builds and muted generated native catalog/play/seek/
queue/persistence/restart checks are qualified separately from live-provider use.
