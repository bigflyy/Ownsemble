# VK personal-library listing and sync

VK's guarded `load_section` music request exposes the account's personal listing
with `hasMore`, `nextOffset` and `totalCount`. Import now uses this listing before
trying rendered rows. Play resolves an exact recording independently; sync does
not download audio or wait for artwork or lyrics.

## Incremental and full import

Ordinary automatic checks request the small page form (`is_loading_all=0`). They
stop after a consecutive block of up to 12 saved head identities. A generated
300-record new prefix takes four 100-row pages; an unchanged library takes one.
The saved head retains up to 128 validated identities from received pages, even
when merging stops earlier. It is not replaced after an unresolved head check.

Head checks have a 15-second slice budget, at most eight page requests and at
most 4,096 accepted rows. An in-flight request has its own 20-second deadline and
can finish after the slice budget; no further page is then started. An unmatched
or over-budget prefix remains incomplete. It does not trigger a full sweep per
poll or per Play.

Initial discovery and explicit Refresh VK use larger pages (`is_loading_all=1`),
a 90-second slice budget, at most 32 requests per slice and a 50,000-record bound.
Validated contiguous cursors, unique identities, a stable advertised total and an
explicit provider end are all required for `provider_end`. Full slices retain
their original head and unique membership witness within the provider session.
A restart or new browser/private sign-in session safely begins enumeration again
with idempotent merges. A verified empty listing does not repeat initial broad
discovery on every automatic poll.

VK may advance a terminal cursor by the full page width: the observed final page
started at 2,000, returned 616 rows, and advertised nextOffset 4,000 for total
2,616. Normalize that terminal cursor only when `hasMore=false` and returned row
count reaches the exact total. Nonterminal gaps, duplicate rows, overlaps and
changed totals never manufacture complete coverage.

Rendered DOM rows are not a fallback source for personal membership. The live
comparison found rows outside the listing without recommendation markers, so
filtering explicit recommendation containers cannot establish membership. An
unsupported listing stays partial and preserves all saved data. Initial partial
or failing discovery stays pending and pauses broad automatic retries across
restart; bounded head checks can still run. Targeted exact-recording playback
and optional metadata readers continue to use their independent DOM guards.

## Persistence and presentation

A completed enumeration stores the provider count and verification timestamp
separately from the saved catalog. The UI displays the dated last verified VK
listing and local saved count. A later head check preserves that dated witness;
it does not claim to revalidate every historical row. An incomplete broad scan
shows partial coverage. Only a verified end clears initial-discovery pending state.

No enumeration deletes tracks, cached audio, Piles, listening history or optional
metadata absent from a later response. Historical saved tracks outside today's
personal listing remain saved. Absence from the listing does not prove that a
recording is unavailable or that earlier imports were recommendations.

## Privacy and diagnostics

- Require the existing personal-music witness and native browser audio isolation.
- Send only a read-only request for the browser's own numeric music owner.
  Session attachment remains inside the browser; no cookie export or auth lookup.
- Recheck the recognized route and sign-in-form presence before every request,
  after headers and after body transfer. Never read credential-field values.
- Reject redirects and non-JSON/plain-text response types before body access.
  Read bytes and decode the declared Windows-1251 or UTF-8 encoding explicitly;
  missing charset defaults to UTF-8. Reject unknown encodings and invalid bytes.
  Reject buffers over 16 MiB before text decoding and text over 8 Mi characters
  before JSON parsing. These checks occur after `arrayBuffer()` accumulates the
  response; they do not impose a streaming network-byte cap.
- Project only known basic recording fields. Drop response media URLs; exact
  Play source validation and cache bindings remain independent.
- `library_listing_page` reports only allowlisted numeric page/total/transport
  counters. Request failures retain a fixed stage: 1 fetch, 2 body, 3 JSON decode,
  4 decoded envelope, plus deadline/JSON-error flags. Separate pagination and
  metadata projection counters identify server-contract drift. No bodies or native errors.
- Explicit `inspect-library` remains a separate optional diagnostic. It compares
  at most two pages and 4,000 unique entries with one shared 20-second request
  deadline and a 21-second outer deadline. Ordinary sync does not run the DOM
  membership comparison. No diagnostic exports recording IDs, titles or URLs.

## Windows validation, 2026-10-24

Tests first reproduced the private projection, unsupported cursor behavior,
300-new-record prefix missed by the old provider, duplicate membership, quiet
initial-import state, checkpoint overwrite/shrinking, and complete-coverage UI.
The terminal fixed-width cursor regression was added after live qualification
rejected that final page, then passed after its correction. Additional generated
scanner tests cover explicit empty end, continuation, changed totals and overlap.

The original five-second explicit probe expired while reading its body, before
JSON decoding. The longer bounded probe completed in 7,972 ms: 2,616 unique listed
recordings versus 114 rendered rows, 14 rendered outside the listing. None of
those 14 had a recognized recommendation marker. Their cause is not established.

Native head qualification requested one 100-row page and matched the saved
checkpoint after 19 entries, with no new rows, in 6,616 ms including preparation.
Native full qualification then read 2,000 + 616 rows, verified unique total 2,616
and explicit end in 9,430 ms. The local historical catalog stayed preserved. Live
addition/removal was not induced on the account; new additions are generated-data
qualification, not a claim of a real account mutation test. Timing is host/network
specific. Ordinary Linux qualification remains separate.

Generated checks: 260 Flutter tests, 78 app-adapter/diagnostic Node tests and 66
preserved probe/CLI tests pass; Dart analysis is clean. The shared provider
contract probe passes. Native Windows candidate Release browser isolation/input,
1,200-row catalog/restart/SQLite, and streaming/seek/cache/offline checks pass.
Streaming starts at 306 ms with the generated delayed source; the existing
nonfatal decoder signal 4096 remains, while complete validation passes. These
fixture results do not certify physical sound quality or other operating systems.

## Cyrillic import regression and recovery

The initial listing importer used Fetch `response.text()`, which decodes UTF-8
regardless of a legacy response charset. Native VK replies declare Windows-1251.
That importer therefore saved replacement characters in 1,541 catalog rows.
ASCII-only import fixtures missed this defect; basic counts and complete page
coverage did not prove text fidelity.

The corrected importer reads bytes and uses a strict TextDecoder for the declared
allowlisted encoding. Invalid bytes, unknown encodings and replacement characters
in projected metadata are rejected before merging. Generated tests first reproduce
Windows-1251 Cyrillic corruption and invalid UTF-8 being silently accepted. Further
qualification covers UTF-8 Cyrillic/emoji, missing charset, privacy guards and
metadata recovery across restart without changing IDs, cache, Piles, history or
first-import timestamps. Public source files were also checked as strict UTF-8.

Native corrected Debug qualification received Windows-1251 on both personal-list
pages and completed the 2,616-member enumeration in 32,447 ms on this attempt.
Earlier runs took 9,354-19,403 ms; provider/network/preparation latency varies.
The corrected merge restored the saved text: replacement-character rows 1,541
before repair, zero afterwards; Cyrillic titles 37 before, 1,527 afterwards.
All 2,635 saved tracks, 2,632 optional-metadata records and 113 cached-artwork
records remained. These are aggregate counts only; no recording text was exported.
The repair reuses exact recording identities and does not redownload audio.
