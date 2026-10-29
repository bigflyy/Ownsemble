Latest update (2026-10-22 00:08 UTC): native Linux GTK UI is running via WSLg with generated
data. Debug/Release builds and native UI/media/cache/restart/shutdown checks pass;
180 Linux Flutter tests pass plus1 expected Windows-only skip; analyzer clean.
See LINUX_PROOF.md/ADR0002/latest handoff. Shared Dart, production dependencies and
Windows native source unchanged. Live Linux VK blocked by missing WPE/browser
adapter; ordinary Ubuntu/other-distro acceptance still pending. No private data
copied. Evidence: .local/linux-proof/evidence/validation.json.
Older status follows where it conflicts.

Latest update (2026-10-21 18:17 UTC): selected platform-boundary architecture implemented.
See ARCHITECTURE.md, ADR0001 and latest handoff.181 Flutter/48 adapter tests, clean
analyzer/format, both builds and new-contract native browser/media/restart/streaming
checks pass. Shared generated policy passes standalone Windows/Linux Dart; no native
Linux/Android production port claim. Final scoped uncached and old-cached checks
pass; slow-first-sound/VK lyrics bugs remain. Data preserved; one verified cache
entry added. Evidence: .local/ownsemble/architecture-validation.json.
Older status follows where it conflicts.

Latest update (2026-10-21 17:48 UTC): Escape leaves search while retaining query/results;
front dialogs keep priority, Ctrl+K returns.166 Flutter/48 adapter tests and both
builds/generated native acceptance pass. See KEYBOARD_USABILITY.md and handoff.
Portability is assessed in PLATFORM_PORTABILITY.md; NO platform refactor/upgrade/
port implemented. Clickable VK connection/status control is logged only. Uncached
startup latency and VK lyrics extraction remain unresolved. Older status follows.

Latest update (2026-10-21 17:19 UTC): keyboard usability delivered.164 Flutter/48 adapter
tests, analyzer/formatter, both builds and generated native checks pass. Shared
shortcut hints/F1 help; text-editing/button/modal protection. Final Release cached
main controls/replay pass721ms/zero bytes. See KEYBOARD_USABILITY.md. Early-streaming
startup investigation and undecided manual queue/save-session design were logged;
VK lyrics extraction remains unresolved. Older status below is historical.

Latest update (2026-10-21 16:55 UTC): selected controls/UI slice completed. Search spaces,
mute/restart volume, exclusive SAVED status/column alignment and clickable cached
artwork previews are delivered.155 Flutter/48 adapter tests and both generated
native modes pass; both builds aligned; final Release cached main controls pass.
See CONTROLS_UI_FIXES.md. VK lyrics retrieval despite available VK lyrics remains a
confirmed queued bug. Older status text below is historical where it conflicts.

# Windows MVP implementation status

2026-10-21 continuation: see [recording integrity](RECORDING_INTEGRITY.md) for the
critical wrong-recording cache failure found during metadata work, and
[metadata enrichment](METADATA_ENRICHMENT.md) for the implemented scope and live
lyrics limitation. 143 Flutter/48 adapter tests pass; analyzer clean. Final native
build acceptance is recorded in the top SESSION_HANDOFF.md section. Older sampled
playback claims below predate the identity-receipt requirement and are historical.
All feature ideas remain in FEATURE_LOG.md; no backlog feature order is approved.

Updated 2026-10-21. Automatic newest-first refresh is implemented; see
[its behavior and evidence](INCREMENTAL_SYNC.md) and the latest
[handoff](SESSION_HANDOFF.md). Existing catalogs no longer automatically walk
the full list after restart/every quiet boundary. A saved ordered checkpoint
stops short checks at a known block. Initial import and manual Refresh VK still
support deeper bounded discovery. Unmatched checks preserve all records and
checkpoint state, with a partial result rather than a full-sweep fallback.

104 Dart and 38 JavaScript tests pass; analyzer/format clean. Test cases cover
additions before a known block, virtualized overlap, reordering, budgets,
checkpoint persistence, startup scheduling, manual continuation, initial import,
and navigation/guard ordering. Both Windows modes are rebuilt from current
source. The initial scheduled live check failed before fresh navigation; frozen
negative evidence is retained. The corrected Debug and final Release two-minute scheduled
cycles both passed: 115 rows, known block found; Release took 6119 ms. Runtime error reports can be stale; compare timestamps.

Live short checks inspected 115 of 2633 saved tracks and stopped at a known block,
including after restart. Cached and uncached playback worked during refresh with
nonzero native output and full cache; final Release measured starts were 603 ms cached and 1758 ms uncached
during refresh. Complete cache and nonzero output were verified. See the handoff.
A genuinely new live account addition remains unverified; generated additions
are covered. Older changes outside the checked prefix require a deeper scan.

The original restricted recording STILL DOES NOT PLAY in this VK session. The
six old-tail playback passes are scoped samples. Cold uncached playback may still
take 10-20 seconds. Automatic refresh is separate from playback loading.

Data/cache/Piles/listens/private session/both probes remain; no account changes,
resets, profile copies, commits or publication. Privacy, exact identity/route/form
checks, native mute, cookie-free HTTPS fetching, cancellation, full cache integrity,
formats/timestamps and relay shutdown protections remain. The tests-first rule
is now explicit in AGENTS.md and a user-requested persistent preference note.

Remaining gates: full VK coverage/playlists, genuine live addition, older/mass
changes beyond the head budget, every-track availability, expired sessions,
Android and clean-machine packaging. Production is Flutter/Dart/SQLite.
