# Bounded VK library diagnostics

The guarded music-page request `load_section` exposes a personal playlist listing
with explicit `hasMore`, `nextOffset` and `totalCount` fields. A Windows feasibility
check received 2,000 entries, a continuation offset of 2,000 and a total of 2,615.
The rendered page separately exposed 2,630 distinct recordings. Those counts must
not be treated as interchangeable without checking membership.

The adapter can compare the listing and rendered recording IDs internally. It
exports only numeric counts: listed and rendered membership, differences and
explicit recommendation-container markers. Optional metadata readers are excluded
from this diagnostic path so stalled enrichment cannot hold up its result.
No IDs, song names, response bodies, source URLs or credentials are returned in
these diagnostics. The comparison never changes the catalog or cache.

## Bounds and privacy

- Run only after approved personal-music access and the explicit fixed
  `inspect-library` diagnostic command. Ordinary sync and playback do not run it.
- Send at most two read-only requests, with one shared five-second network
  deadline and a six-second outer diagnostic deadline.
- Keep session attachment inside the browser; reject redirects and non-JSON
  responses before reading bodies. Limit each response text to 8,388,608 characters
  before parsing; record only its length and a distinct oversized-response category.
- Recheck route and sign-in-form presence before requests, after response headers
  and after body transfer. Never read credential-field values.
- Compare membership only when an explicit end marker and a matching total fit
  the two-page, 4,000-entry budget. Reject malformed recording IDs or changed totals.
- Compare modern recognized DOM recording rows only. A partial or virtualized DOM
  is not proof that listed tracks are missing from VK.
- Project known bounded counters again at the Dart boundary before reporting.

This is a feasibility and troubleshooting path. It does not replace import with
an unverified endpoint or infer that entries absent from one representation should
be deleted. Existing records remain preserved.

## Validation

The initial request/projection tests, body-transfer sign-in race and bounded
membership comparison failed before their corrections. Additional generated
fixtures cover network failures, HTML rejection, sign-in during requests and
malformed optional counters. Dedicated Dart tests cover deadlines, numeric
projection, private sign-in cancellation and native exception sanitization. Later
Linux validation of this shared change remains deferred.

The preceding authorized Windows scan observed 2,630 distinct recordings across
bounded continuations and retained all 2,633 saved records. An older cached
selection passed main-player and local-cache controls in 3,619 ms with zero
received bytes. These are scoped observations, not a universal provider or audio
quality guarantee.

Final Windows checks: all 212 Flutter tests and 64 adapter tests pass; analysis is
clean. Release source and the generated adapter asset match. The explicit native
probe emits sanitized failure counters. The old two-million-character response
cap was incorrectly reported as a transport/format rejection; size failures now
have a separate category and the bounded parsing cap is eight million characters.
A complete live membership comparison remains unverified. Keep the alternate
endpoint diagnostic-only until that discrepancy is understood.

Uncached playback acceptance is still open: a deep-library selection obtained an
exact native-player source binding, then failed opening the local relay after
8,519 ms with no upstream bytes observed. Cached-player passes do not resolve
that failure. Preserve the underlying transfer error before changing transport
or weakening certificate, destination or recording-identity guards.
