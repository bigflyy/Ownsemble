# Recording identity and cache repair

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
