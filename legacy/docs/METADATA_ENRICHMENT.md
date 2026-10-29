# Optional metadata, artwork and lyrics

Updated 2026-10-21. This extends existing records without replacing the catalog,
cache, Piles, pin references or listening history. See RECORDING_INTEGRITY.md for
the critical recording-assignment repair discovered during this work.

## Fields and dates

The guarded reader projects optional fields only after an exact owner/audio-ID
match: album, version/subtitle, artist credits, explicit flag, upload timestamp,
release year when supplied, thumbnail and lyrics availability. Missing/blank
values do not erase previously saved good fields. Image/media URLs remain in RAM.
Additive track_metadata and track_lyrics tables retain supported results.

The official [VK audio schema](https://github.com/VKCOM/vk-api-schema/blob/master/audio/objects.json)
defines date as upload time. It is shown separately as Uploaded to VK; it is not
treated as release time or as the date added to this user's collection. No verified
VK collection-added field was found. Imported into Ownsemble uses the earliest
retained tracks.updated timestamp, preserved by later merges and restart. Unknown
provider fields stay unknown rather than being filled with today's date.

## Artwork and visible-row loading

Library rows and the current player show validated cached artwork with a local
placeholder fallback. Cache entries use a SHA-256 content key; shared album bytes
deduplicate. The independent cache has a 128 MiB budget, preserves pinned keys,
allows at most 2 MiB per image and validates MIME, decode and bounded dimensions.
Publication is atomic. Strict image-CDN/HTTPS/redirect/certificate guards remain;
no browser cookies are exported or attached to artwork requests.

Demand follows the actual painted viewport, excluding ListView cache extent. A
120 ms dwell avoids starting requests during fast scrolling. Leaving a row releases
its demand, obsolete queued requests are discarded and active requests are aborted
when possible; another visible consumer keeps a shared request alive. The player
has higher priority. Four network/decode jobs can run together and reuse HTTPS
connections; only publication/quota work is serialized. Completed files stay cached.

If an old visible row has no known thumbnail metadata, a separate single-worker
queue performs an exact-ID metadata lookup. It skips abandoned rows and fetches no
lyrics. It yields during audio preparation/download; the image queue does likewise.
Play never awaits these optional jobs. Cold provider lookup still depends on VK;
parallel artwork does not promise fixed latency under arbitrary networks.

## Details and lyrics

Song options -> Song details & lyrics opens a recording-bound panel with dates,
optional fields and complete-audio properties. Opening/refreshing it performs the
selected recording lookup. Background refresh does not fetch an entire catalog's
lyrics. Successful plain/timed results are cached; timestamps are used only when
actually supplied. Later failures preserve saved lyrics. Late results are stored
under their own recording ID and cannot replace another song's panel data.

Supported exact-row lyric controls/dialogs have guarded native-input and identity
checks. Current live VK pages advertised lyrics but exposed no supported direct
lyrics control and no inline text in the tested rows. Thus live lyric retrieval
has NOT been demonstrated; the panel shows an honest unavailable/retryable state.
External multilingual lyrics discovery/candidate verification remains a future
feature in FEATURE_LOG.md, not an automatic third-party query in this delivery.

## Validation and coverage

Tests cover exact identity/old structures, missing fields, non-destructive partial
merges, v1 database migration, import-date/restart persistence, offline cached UI,
wrong/stale lyrics binding, corrupt/oversized/extreme images, redirects, shared
requests, cancellation, fast jumps across 2,633 generated rows, queued old-metadata
discarding, playback priority and stalled artwork/metadata not holding up Play.
The generated-only UI preview is .local/ownsemble-smoke/metadata-preview.png.

Live recent-page sample: 115 thumbnails/upload dates, 114 albums, 113 artist-credit
arrays and 87 lyric flags; no lyrics text or verified collection-added dates.
A selected old recording also supplied optional metadata. Coverage is partial:
there is no forced 2,633-track metadata sweep or automatic external enrichment.
Startup/scheduled sync still checks the bounded newest prefix (115 observed rows).
See the latest handoff for final counts, builds and native acceptance evidence.
