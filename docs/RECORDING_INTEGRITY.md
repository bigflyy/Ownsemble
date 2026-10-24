# Recording identity and cache repair

## Exact reload references and unresolved historical entries - 2026-10-24

The personal-list importer retained recording identities but discarded reload
hashes. That made old, non-rendered recordings depend on title search even when
the listing had supplied an exact lookup reference. Listing pages now project
only bounded, identity-bound reload references alongside their existing metadata;
the provider retains them before the controller's ordinary persistence callback.
No media URLs are persisted by this change. Missing hashes do not prevent a bare
exact-ID reload attempt. A main document that fails its personal-page witness
before issuing a request no longer suppresses the request on a prepared personal
playback document. Same-title recordings never establish identity.

Tests first reproduced missing listing references, their loss at the provider
merge boundary, skipped bare-ID reloads, skipped prepared-page lookup, and numeric
reload outcomes being removed from diagnostic reports. Generated controls also
cover a named, ambiguous recording lookup without starting or switching music.

Live qualification did not restore the newly reported historical recording. A
named lookup found exactly one saved entry, but its identity was absent from a
fresh complete 2,617-recording provider listing. It had no saved reload reference;
the direct reload returned zero matching recordings/sources, and the search
fallback did not find that identity. These observations do not establish deletion,
copyright restrictions, or permanent unavailability. The entry and existing data
are retained; no alternate recording was substituted.

An initial positional reproduction selected another entry after sorting changed.
Its result was discarded as evidence for the reported song. Named diagnostics
now verify the requested title/artist internally and expose only counts/flags.
A separate old listed recording reached an exact reload match, then encountered
a rejected HTTPS redirect to VK's site rather than an approved media CDN. The
destination guard remains strict; that sample did not pass playback. A previously
verified cached recording passed real Release controls in 1,100 ms with zero
received bytes. That success does not qualify either failed recording.

All 266 Flutter tests and 79 adapter/diagnostic Node tests passed, and analysis
was clean. An earlier concurrent suite had one timing-dependent mute-control
failure; the isolated test and complete sequential suite passed without changing
the mute implementation. All native checks were silent. The reported recording
remains an unresolved live-provider gate, not a completed playback repair.

A subsequent bounded probe also searched with artist plus title instead of the
common title alone. It still did not recover the reported original identity:
native Debug failed in 10,706 ms with zero received bytes. The resolver now uses
the more specific query when it fits the existing 160-character input budget;
long metadata retains the prior title-only path. Tests first cover both the
specific query and that budget boundary. This remains an exact-ID search, never
an automatic switch to a name match. Numeric diagnostics also retain the existing
`musicSearchChangeHandler` control-capability flag without exporting input values.

Updated 2026-10-21. The user reported one title playing the next recording.
Read-only aggregate checks confirmed the reported pair shared a cached payload;
one cached duration disagreed with its track by more than five seconds. SQLite
quick_check was OK. This was a content-assignment failure, not a corrupt database.
The historical fetch cannot be reconstructed completely from the retained logs.

## Source contract

Network timing, a lone media request, and an HLS segment match do not establish
which song was requested: VK can prefetch the next song. The old fallback could
accept that evidence. Regression tests reproduce that unsafe selection.

Production playback now requires a source explicitly bound to the requested
owner/audio ID by exact row metadata, an exact-ID reload response, or a supported
guarded current-music-player getter. Resolver results carry their recording ID
and evidence kind; the controller checks them before playback/cache publication.
Unbound requests remain diagnostic counts and never select audio. Ambiguous or
unverified selections fail closed. Route/form/native-mute/HTTPS guards remain.

Full decode must agree with a known recording duration within five seconds in
either direction. The former check rejected only recordings that were too short.
Duration is an additional check, not a substitute for source identity. Provider
metadata is not independent acoustic recognition; this does not certify every
recording in the account or repair a provider's own mislabeled recording.

## Existing downloads

New complete caches include an integrity-covered recording.json receipt containing
the track identity, evidence kind and expected duration, never a media URL/token.
An additive asset_identity table binds offline eligibility to the current asset
digest. Replacement invalidates a marker for the old bytes. The user-facing
Offline view excludes legacy entries until verification succeeds.

Legacy files without identity proof need an online check when selected. They are
not trusted merely because their own checksums match. Offline attempts fail with
a clear explanation and retain the files. This is a deliberate change to older
cache eligibility after a confirmed assignment failure; no bulk download runs.

A complete, decoded, identity-bound replacement is prepared first. Only then is
the old publication moved under audio/quarantine and the replacement published.
Cancellation/failure during replacement restores the old publication. Catalog,
Piles, pins, metadata and listening history are retained. Quarantined originals
are preserved outside automatic cache eviction and are not deleted by this repair.

## Evidence

Tests first: sole next-song prefetch rejection, wrong resolver identity, longer
wrong recording, legacy self-check false positive, offline retention, exact-digest
marker invalidation and cancellation rollback. Negative logs remain under
.local/ownsemble/wrong-recording-*-red.txt and the safe initial snapshot under
.local/repair-backups/wrong-recording-20261021/.

The targeted built-app repair finished with identity/duration checks and the old
file preserved. Both affected recordings passed main-player controls in Release;
the repaired sample produced nonzero native output. One old recording passed
streaming-before-completion, seek, complete cache and local replay. A fresh Debug
offline process passed with no provider connection and zero received bytes.
See the latest SESSION_HANDOFF.md for final-build checks and precise timings.

These are scoped samples. Other legacy downloads are checked on demand. The
original content-restricted recording from earlier sessions remains restricted.

## Legacy-cache startup correction, 2026-10-24

A user-selected old recording failed twice at the 30-second startup limit even
while audio bytes were arriving. The controlled reproduction found exact source
metadata in 49 ms, then waited for the entire replacement download. The cause
was the playback preparation branch treating any saved asset as a local-only path,
including an unverified legacy asset that needed online replacement.

Online preparation now races complete verified cache acquisition against the
identity-bound streaming relay for both absent and invalid/legacy saved assets.
Offline/demo still require local verification. A completed relay does not hide a
now-valid local file; an active replacement can resume without waiting for EOF.
The old file remains untouched until complete validation and atomic publication.
No identity, integrity, duration, destination, TLS or privacy guard is relaxed.

A tests-first controller regression held the final generated bytes while a genuine
legacy cache existed. It failed before the fix, then passed after it: initial
bytes came from the new bound source, the legacy file and missing receipt remained
unchanged before completion, and the next Play used the verified local asset.
The test uses loopback IO and a silent engine, with no provider/account traffic.
Existing offline rejection, identity and cancellation tests remain in the suite.

The exact previously failing normal-session selection passed native Debug checks
with volume confirmed zero: first playback in 4,544 ms after about 65 KiB arrived;
pause/resume and buffered seek; full 9,056,266-byte cache validation; local replay
and seek. The whole diagnostic took 173,503 ms on this slow transfer. Startup no
longer waits for that whole-file operation. This is a scoped playback sample, not
universal old-recording or network latency certification. Diagnostic was_cached
means an asset existed, including legacy files; streamed identifies this repair.

All 261 Flutter tests and 78 main adapter/diagnostic Node tests pass, with clean
analysis. Generated playback tests do not replace the native sample above.
