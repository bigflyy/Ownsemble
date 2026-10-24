# Diagnosing future VK changes

With Ownsemble open, run from the repository root:

```bash
node scripts/app-control.cjs diagnose
```

This requests a fresh `.local/ownsemble/diagnostics-report.json` and prints a safe
summary. A new request nonce must be acknowledged; an old file is not accepted
when the app is stopped. Collection does not sign in, connect, scan, play or change
the queue. It can collect existing evidence while private sign-in is active.
This is currently a checkout tool; installed-app export UI is future work.

## Evidence

- **Code identity:** schema version, platform family, compiled Git revision with
  dirty-source marker, and SHA-256 of the actual bundled adapter loaded by the
  app. Windows/Linux build helpers attach labels automatically. Direct builds
  without the define honestly report `unlabelled`. Hash equality identifies code;
  it does not prove provider correctness.
- **Attempt identity:** locally generated run and operation IDs correlate async
  playback/provider/cache events without recording or account identifiers.
  Concurrent sync uses a separate operation context.
- **Timings:** startup phases and monotonic offsets; source resolution; connection,
  response headers, HTTP status, first body bytes, completion and cache stages.
  `connect_ms` combines DNS, socket connection and TLS; it does not claim to
  measure these individually.
- **Contract clues:** known music-row/field/control counts, source-shape flags,
  fixed CDN-family flags and adapter installation boundaries. Unknown fields are
  omitted and counted. An absent observation is not a measured zero.
- **Failure cause:** preserve the original registered category/status through
  generic native/cleanup symptoms. Recovered cache warnings remain observations.
  A timeout retains its last active phase through event rotation and restart.
  Investigation areas are routing hints, not assertions of root cause.

Background events cannot erase the last failure. Keep 64 recent events, 12
operation summaries and four failure snapshots with up to 12 context events each.
Reports are capped around 192 KiB. Failures survive restart with their original
build, adapter digest and date; historical failures do not mean current playback
failed. The terminal summary exposes fewer fields than the complete artifact.

## Investigation order

| Report area | Check first |
| --- | --- |
| `connection_or_private_signin` | Private-sign-in/connection flags; never inspect login pages or session storage. |
| `page_or_adapter_contract` | Adapter digest, install boundaries and action/field/control counts; recreate changed shapes with generated fixtures. |
| `source_resolution` | Last startup phase, page readiness, exact target matching and source-refresh/request counts. |
| `recording_identity` | Exact recording binding; never substitute adjacent songs or infer identity from prefetches. |
| `cdn_destination` | Destination flags/redirect hops; research a new provider CDN before explicitly accepting it. |
| `media_transport` | HTTP status, connection/header/first-byte timings, TLS/socket category and cancellation. |
| `provider_restriction` | Separate an unavailable recording from an extraction failure. |
| `playlist_or_segment_format` | Manifest/segment category; add generated changed/malformed-format tests. |
| `native_playback_or_integrity` | First-byte evidence, startup phase, native category and decode/duration checks. |
| `local_cache` | Verification/publication stage and identity receipt; preserve existing files. |
| `unclassified` | Fixed exception component/kind and preceding stages; register new safe categories with tests. |

Compare a failed attempt with a known uncached success and a cached success.
Cached playback alone does not validate VK extraction. Never collect raw page
HTML, request/response bodies, headers, URLs, titles, account IDs, cookies, tokens,
profiles, authentication data, normal native logs or memory dumps. Unknown values
are omitted before entering the journal, rather than recorded and scrubbed later.
Raw exception messages/stacks remain excluded.

## Cost and validation

Events stay in memory; writes are asynchronous, coalesced at 250 ms, with one batch
in flight. A blocked disk cannot accumulate a per-event write queue. Fixed files
are replaced through sibling temporary files. Missing/corrupt/oversized previous
evidence cannot prevent startup. Write failures become counters, and optional
persistence cannot hold shutdown indefinitely. Existing player/sync status files
retain their prior behavior.

Run `bash scripts/app.sh dart tool/diagnostic_benchmark.dart` for generated logging
cost, independently of network/device conditions. On this Windows host the sample
run measured 5,000 events at median 6 us, p95 17 us and p99 99 us; first JIT snapshot
and serialization took 28.8 ms. These are informational host-specific results,
not an end-to-end Play benchmark or a zero-overhead claim.

Tests cover correlation, first-cause retention, warnings, privacy, bounds, slow
writes, restart/corruption, passive collection and automatic source labels. A
registry test catches unregistered literal production error categories. Extend
explicit schemas and generated tests; never serialize arbitrary page objects.
235 Flutter and 68 Node tests passed; analysis was clean. Generated build-label,
launcher and source-archive tests passed (one platform-specific archive case skipped).

A live uncached Windows attempt played and completed its cache. One operation ID
linked source resolution, HTTP 200, first bytes and publication; the adapter digest
matched public source and the report recorded zero write failures. Real player
pause/resume/seek/stop/local reopen and generated encrypted streaming/offline checks
passed. One concurrent Debug browser fixture exited with native code 3221225477
before producing a fresh report; a standalone retry passed all browser gates.
Its cause is not established. Never count the stale earlier report as success.

During launcher verification, Windows' legacy `bash` alias accidentally started
Ubuntu. It was stopped again. A separate tests-first fix now selects an explicit
Git Bash executable and rejects the legacy alias. No Linux playback acceptance is
claimed; native Ubuntu audio testing remains deferred.
