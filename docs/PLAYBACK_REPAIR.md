Current continuation (2026-10-21): automatic refresh now checks a persistent
newest-first checkpoint instead of repeatedly sweeping the whole library. See
[implementation and measured evidence](INCREMENTAL_SYNC.md). The measurements
below are historical playback evidence; current test count is 104 Dart / 38 Node.
The original restricted recording remains unplayable in this VK session.

# VK playback/loading/cache repair

Updated 2026-10-20 18:35 UTC. Current evidence is scoped to measured cases on this
PC. See latest [handoff](SESSION_HANDOFF.md). Earlier success claims did not prove
the user's failing selection. That original recording still cannot play: exact
VK content_restricted=1, no usable URL, guarded native Play produced no media.
Specific restriction reason is unknown. Four consecutive original rows failed.

| Check | Observed result |
| --- | --- |
| Normal uncached Library Play / Next | 2216 /1663 ms; scan active |
| Normal MAIN controls / replay | Passed; replay 733 ms |
| Fixed old-tail sample | All 6 played; full caches and nonzero native output |
| Five uncached old-tail starts | 4755,2775,2723,3747,3602 ms |
| One cached old-tail start | 1292 ms |
| Known-age old target controls/replay | Seek/pause/resume/stop passed; replay 688 ms |
| Same old target fresh Release offline | First audio 721 ms; controls/seek; zero bytes / provider disconnected; exit0 |
| Same old target final ordinary Release | Cached942 ms; actual nonzero output |
| Tests and artifacts | 87 Dart / 38 Node; format/analyzer clean; both builds current |
| Generated native fixtures | Streaming/cache/seek and hidden/muted browser pass |
| Real SQLite | quick_check=ok; 2633 tracks/22 complete assets |

Old tests used an unfiltered fixed snapshot, offsets 1,10,25,50,100,250 from the end
of 2633 rows. Five uncached exact matches have VK upload/addition metadata bucket
2015to2019; one cached unknown. These are not composition release years or proof
of pre-2015 coverage. Warm sample latency is not a universal limit. Cold uncached
VK startup can still take 10-20 seconds. Every-track access/full coverage unproven.

Fixed: playback no longer paginates; exact-ID source memory/search resolves deep
selections while independent import scans. Default library order now uses observed
VK positions, not late discovery time. Empty capture is unresolved, not automatically
unavailable. Only matched restriction metadata or guarded disabled Play produces
restriction categories. UI labels restriction; records remain retryable/saved.
Old inferred unavailable errors migrate without removing data. Exact valid media
wins over advisory flags. Pile ordering/occurrences remain independent.

Unused muted metadata documents can be retained. Activated/failed/cancelled pages
are destroyed. Route/login-form/exact-ID checks, trusted input, native mute,
HTTPS suffix/authority, cookie-free bounded media fetching, cancellation deadline,
strict decode/duration/hash/atomic full cache, formats/timestamps and relay shutdown
order remain enforced. No profiles/auth/cookies/media URLs inspected/exported.

Current sanitized summary: .local/ownsemble/final-playback-validation.json.
Frozen old reports: old-audio-validation.json, old-audio-controls.json,
old-audio-offline-check.json. Normal: provider-order-primary.json,
provider-order-controls.json, final-release-ordinary-play.json. Negative:
restriction-validation-live.json/current-selection-restriction-* remain failures.
Normal Release left paused, volume preserved. Source recovery snapshot:
.local/repair-backups/normal-old-verified-20261020-1835/.
