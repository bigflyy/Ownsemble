# Shuffle playback startup investigation

## Reproduced source failure

A muted uncached selected recording failed at the 30-second foreground startup
limit with no received bytes. Retained diagnostics identify `player_start_timeout`
in `resolving_source`; the check's later `cancelled` result is cleanup, not the
original cause. The hidden music document took 32.375 seconds to become ready.
The same recording then passed after that document warmed up. This is consistent with a cold source-resolution failure in the playback path
shared by both queue modes. The captured baseline runs did not isolate queue mode
or establish shuffle order as the cause of the reported failures.

Before the repair, warm selected and old-tail samples started at 9.319 and 10.178
seconds, respectively. Each passed main Play/pause/resume/seek/stop, complete-cache
publication and local replay/seek. These are bounded samples, not all-library
acceptance, and the latency remains significant.

## Repair boundary

Current rendered metadata and a witnessed source-memory hit keep their priority.
A standby page finishing within a 150 ms grace also retains the existing current
search path. If it remains cold, the already-consented main music page can resolve
only the requested stable recording ID through the existing exact-reference
adapter. Unsupported reference responses fall back to the independent page.

The personal-music witness, route/form rejection, exact recording identity, native
browser mute, HTTPS/CDN policy, transport and cache receipt checks remain intact.
No list-position match, title-only substitute, cookie export, full catalog walk,
provider account write or storage replacement was added. A missing personal-page
witness cannot use this shortcut. A failed exact reference can still require slow
page preparation/search; this repair does not promise a universal latency bound.

## Rejected-reference recovery

Paired live baseline checks subsequently reproduced the same failure in both
modes with 2,617 queue entries and the same preserved recording identity: normal
2.208 seconds, shuffle 2.877 seconds, zero received bytes. The exact-reference
request succeeded structurally, but its approved CDN address redirected to a VK
web destination. The existing transport guard correctly rejected that hop. This
proves that candidate is unusable under current policy; it does not prove whether
the endpoint is stale, the recording is unavailable, or a newer source exists.

The optional `RejectedSourceRecovery` provider contract accepts only a recording
and exact source previously returned by the reference resolver. On that specific
destination rejection, the controller unloads media and retries the same recording
once through current discovery, with legacy fallback disabled. The retry retains
the original request ownership and total startup deadline, including cleanup.
Stop or a new selection invalidates it immediately. Cancelled cache-validation
waiters relinquish the download lane; late validation cannot publish cancelled
bytes. A different retry failure retains the original destination error, while
fixed diagnostic events identify the retry and its own failure category.

The provider retains at most 64 reference candidates and 64 session-local current-
discovery markers. A rejected reference remains disabled for that recording until
session disconnection or bounded eviction, including after successful recovery.
No source address enters the reports or persistent settings. An unsupported
current source fails closed; recovery is not a source substitution or a guarantee
that an unavailable recording can play.

## Bounded silent queue comparison

The existing app-owned diagnostic channel accepts two additional fixed commands:

```sh
node scripts/app-control.cjs mute
node scripts/app-control.cjs check-queue-normal
node scripts/app-control.cjs check-queue-shuffle
```

Wait for acknowledged native volume zero before either check. Both commands refuse
unmuted playback. They accept no IDs, paths or browser instructions. The first
chooses one uncached, not-known-restricted recording internally; the second reuses
that in-memory identity. Each starts it through `playRows` with the full local
library and the requested shuffle mode, requires actual native progress, then
stops and restores the prior queue. Diagnostic playback suppresses listening
history. A newer user request retains ownership and is never overwritten by
cleanup. Successful prefixes may finish caching; `was_cached` records each
attempt's actual starting condition.

The fixed `queue-check.json` report contains mode, queue count, identity-preserved
flag, cache precondition, startup stages/timings and safe outcomes. It contains no
recording identity, display metadata, source address or authentication material.
Run paired checks in the same app process and require a fresh report timestamp;
a restart intentionally forgets the comparison target.

## Regression coverage and acceptance

The cold-page exact-reference regression failed before the provider change.
Coverage retains current-row/current-search priority over an available legacy
source, missing personal witness rejection, exact identity, cancellation, and
standby ownership/readiness bounds. Generated 2,633-row controller checks exercise
the fixed command path, normal/shuffle modes, same selected identity, original
queue restoration with duplicate occurrences, no listening-history insertion,
no identity in reports, and unmuted refusal. The check harness was corrected for
its real-zone timer after implementation and verified failing against the original
controller; that supporting baseline run is not a preimplementation live proof.
The full suite also caught an unregistered fixed startup-failure category before
its schema registration was added.

Repeat source checks:

```sh
bash scripts/app.sh test --no-pub test/reference_playback_test.dart test/standby_resource_test.dart test/queue_startup_check_test.dart test/diagnostic_journal_test.dart
bash scripts/app.sh test --no-pub --concurrency=1
bash scripts/app.sh analyze --no-pub
node --test app/adapter/music.test.cjs
```

Additional generated regressions cover warm-page reference ownership, one retry,
no retry loop, a different second failure retaining the first cause, cancelled and
late resolution after a newer song, stalled cleanup, total deadline consumption,
and original queue restoration with duplicate occurrences after recovery.

The source checkpoint passes 318 Flutter tests, 81 Node adapter tests, a clean
analyzer/format check and the standalone generated provider contract probe. The
adapter was rebundled without a byte change. Fresh critical GPT Luna reviews and
follow-up reviews covered the recovery, deadline, cancellation and warm-reference
ownership changes; material findings received failing regressions before fixes.

Native and live results are recorded separately below once completed. Generated
fixtures and independent source review alone do not certify actual VK playback,
all recordings, acoustic output, or Linux/Android behavior.
