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

Source checks pass 325 Flutter tests, analyzer, focused formatting, and the
standalone generated provider contract probe. Fresh critical GPT Luna review and
follow-up review found no material issue in the final source changes and confirmed
the generated/native evidence distinction. Windows build and live incident
acceptance remain separate from these source checks.
