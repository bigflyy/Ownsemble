# First-attempt playback after browser document changes

## Renewed report and evidence boundary

On 2026-10-28 the user reported that a first selection during shuffle failed,
then eventually played. Retained diagnostics from the same installed source
`ce189f836342` contain several `music_script_failed` failures in 30-177 ms,
followed by later successful current-source resolution/playback. The reports omit
recording identities, so they do not prove those failures belong to the specific
recording in the user's report. This is distinct from the prior rejected redirect.

The prior full-queue checks started one selected recording with shuffle enabled.
They did not exercise advancing through shuffled Next while downloads were active.
Passing those samples did not close this renewed first-attempt reliability report.
No library reset, source substitution or stack rewrite is justified by these logs.

## Reproduced lifecycle gap

A browser connection and a recognized music route do not establish that the
application's JavaScript adapter exists in the current document. Navigation loses
window globals; another event can also clear the adapter in the same document.
The fast main-page path in `VkProvider.resolve` called `verify-my-music` before
installing that adapter, relying on earlier sync or unrelated initialization.
Generated tests reproduce first-Play failure after a fresh connection, replacement
document and same-document loss without any sync or manual retry.

Resolution now installs the existing guarded adapter before the first main-page
action and checks cancellation both before and after installation. This makes
installation deterministic for each resolve rather than inferring readiness from
session state. The shared VK provider policy owns this ordering; no OS-specific
browser mechanism, UI, storage schema or playback engine was replaced. Real script
errors still fail visibly after one action; there is no blanket script retry.
All route/form/personal-page, exact identity, native mute, TLS/CDN/cache and
cancellation guards remain in force. Installation itself extracts no music data.

## Diagnostic correction

Previously a subsecond source failure could retain `stopping_previous` in its
failure snapshot: the local phase changed to `resolving_source`, but that change
was not published until the next one-second timer tick. A failing regression
reproduces this misleading phase without any native-stop failure.

Phase transitions now update the bounded in-memory diagnostic journal immediately;
this adds no synchronous per-phase disk write. Existing coalesced persistence stays
in place. Failed adapter dispatch also retains its fixed action and safe category,
without scripts, exception messages, recording metadata, URLs or credentials.
These changes narrow future diagnosis; they do not retroactively identify the
exact failed operation in older reports.

## Regression and acceptance scope

The lifecycle, persistent-action diagnostic and subsecond-phase regressions failed
before their production changes. Additional verification covers Stop while the
main adapter is installing and an actual `AppController.next()` transition in
shuffle mode while the previous generated download is held open. That integration
uses the real provider/controller/relay path with silent fake native playback,
clears the main adapter before Next, and requires the next exact recording to
start once without publishing cancelled previous bytes. It also verifies the two
expected play-history rows in its isolated generated database.

Generated script errors and loopback IO do not certify the live user incident or
a real multi-song native shuffle sequence. Native and live results must be named
separately. Do not interrupt the user's active playback to run a check or install
a new payload. The renewed thumbnail-latency report remains queued behind this
playback task in FEATURE_LOG.md and KNOWN_ISSUES.md.

Initial lifecycle source checks passed 325 Flutter tests, analyzer, focused formatting, and the
standalone generated provider contract probe. Fresh critical GPT Luna review and
follow-up review found no material issue in the final source changes and confirmed
the generated/native evidence distinction. Windows build and live incident
acceptance remain separate from these source checks.

## Bounded native shuffled-Next check

`node scripts/app-control.cjs check-queue-sequence` is a fixed app-owned control
with no track, path or browser-operation arguments. It requires acknowledged
native volume zero, an idle player with no paused listening session, no active
sync/connection/download, and at least three local catalog rows. It starts the
stable internal sample in the full shuffled queue and advances Next twice,
stopping at the first failure. It checks exact selected identity and actual native
progress at each start without requiring a whole download. It performs at most
three starts, with the existing per-start and overall diagnostic deadlines.

The report contains only attempt ordinals, cache flags, safe identity evidence,
fixed categories and timings. Per-attempt `first_audio_ms` starts immediately before
each Play/Next; the top-level elapsed time includes check preparation and cleanup.
No recording identity, display metadata, temporary URL or private session is
exported. Successful starts suppress listening history and queue persistence.
The original duplicate-occurrence queue is restored on owned cleanup. Internal
startup timeout retains that ownership; newer user playback owns its queue and
cannot be overwritten, including during delayed native Stop acknowledgement.
Shuffle, Repeat and Add to queue cancel the check, await restoration, then apply
and persist the user's edit to the original queue.

Generated regressions reproduced the missing command, first/second failure
accounting, paused-session interference, undersized-library false success,
internal timeout misclassification, delayed-Stop queue overwrite, and lost
shuffle/repeat/enqueue edits. Generated fixtures also cover acknowledged-mute and
active-playback refusals. The queue-edit tests preceded their correction; the
repeat fixture's expected enum step was corrected to Off -> All afterward and
rerun against the original bindings, where all three queue edits still failed.
Fresh critical GPT Luna follow-up found no remaining material source issue.
These controls and tests improve the acceptance boundary;
they are not themselves live playback proof. Native/live results follow below.

Source verification on 2026-10-29 passes all 338 Flutter tests, analyzer and 81
adapter tests. Fresh independent critical GPT Luna review of the complete diff
from `5b61db8` found no material source/test issue. Native/live checks remain
separate open gates until recorded below.

## Windows acceptance - 2026-10-29 local date

Both Windows Debug and Release built clean source `d90a9d65c7d4`. The adapter
bundle is byte-identical (`ef80b82e86659600cd8818a945225af59ba94278f35e07fc6ca8d029dcbd7b51`).
Both builds passed the isolated muted 1,200-row catalog/cache/queue/pin/quota/
persistence/Cyrillic/restart fixture, with SQLite quick_check and parent/child
exit zero. Release generated streaming passed early progressive start (308 ms),
encrypted HLS, shared upstream, full validation, local reopen and offline seek.
Generated timings are not live-provider latency measurements.

The normal application was switched through its guarded app-owned restart while
paused, then left on Release. A live full 2,617-song shuffled queue performed an
initial Play followed by two actual Next calls. All three recordings were uncached
at their respective starts and passed on the first attempt:

| Attempt | Native playback progress | Source returned | Source lookup | Identity |
| --- | ---: | ---: | ---: | --- |
| Initial Play | 4,575 ms | 2,446 ms | 2,400 ms | Exact metadata row |
| First Next | 3,531 ms | 1,915 ms | 1,881 ms | Exact metadata row |
| Second Next | 3,995 ms | 1,733 ms | 1,698 ms | Exact metadata row |

All attempts reported selected_identity_preserved and identity_bound, with
prepared_before_selection true and page_wait_ms zero. The check took 12,132 ms
including cleanup, stopped playback and restored the prior queue. Admission
required acknowledged native volume zero. Diagnostic playback suppresses listening-
history writes and makes no account changes.
No real raw catalog/database, profile/authentication or cached media was inspected.
The final runtime projection is connected, paused and not loading/buffering.
A separate fixed-field player-state projection records native volume zero and no
active download stage. Catalog coverage remains `sync_partial` at 2,617 preserved recordings.
The retained historical page_or_adapter_contract failure is not a fresh failed
Play from this check.

This closes the bounded Windows build/native/three-start acceptance gate for this
source milestone. It is not acoustic-output proof, a sustained shuffle stress
run, an all-library availability guarantee, or Linux/Android certification. The
three live sources were ready current metadata; the generated lifecycle-loss
regression remains the direct proof of that repaired branch. The earlier named
recording and the exact cause of its first failure were not identified by these
sanitized samples. Thumbnail latency and confirmed VK lyrics retrieval remain
separately queued.

Sanitized local artifacts are `first-attempt-live-sequence.json`,
`first-attempt-resume-final-runtime.json` and
`first-attempt-resume-final-player-state.json` under
`.local/linux-proof/evidence/`. Generated native/streaming outputs and source-check
logs share the `first-attempt-resume-` prefix. Fresh critical GPT Luna evidence
review corrected the distinction between a zero-volume admission guard and a
continuous volume trace; no such continuous trace was collected.
