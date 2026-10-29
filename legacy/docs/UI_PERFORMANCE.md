# Large-library UI responsiveness

The 2026-10-27 slice covers queue jumps, repeated catalog reads during playback,
and local song-control/menu response. It changes no stored library schema, media
source matching, provider behavior, cached audio, or user data.

## Reproduced causes and changes

The queue used variable-height ListView rows. A distant jump laid out preceding
rows, performing a track query for each. Give it a fixed extent calculated for
the current text scale, truncate long labels, and resolve only visible metadata.
The library uses the same text-scale calculation to avoid two-line overflow.
Duplicate queue occurrences and shuffled order retain their selection semantics.

A row-wide double-tap recognizer delayed child single-tap buttons while waiting
for a possible second tap. Limit double-tap playback to the title/artist area.
Play, download pin, artwork, Pile and song-options controls are outside it. The
song menu uses the app palette, labeled icon actions, 44px targets, rounded border
and a 120ms entrance (100ms exit), honoring reduced-motion preferences.

AppController caches display tracks, individual pin intent and nullable artwork
keys in separate FIFO maps capped at 512 entries each. It reuses Pile summaries
and library count between mutations. Library invalidation clears these values;
artwork publication evicts its specific formerly missing key. Image file checks
remain active. The entire visible screen still rebuilds on playback ticks; this
slice removes repeated SQL, not every build/layout cost.

## Generated before/after evidence

These are Windows Flutter widget-test host observations, not native Release FPS,
physical sound checks, network benchmarks or a promise about every machine.
A generated SQLite catalog and a silent in-memory playback engine keep provider
latency and private data outside the measurement.

| Workload | Before | After |
| --- | --- | --- |
| Jump to 90% of 2,633-song queue | 2,365 track reads, 8.24s | 13 track reads, 68ms in the final isolated sample |
| Jump to 90% of 10,000-song queue | 8,996 track reads, 74.37s | 14 track reads, 58ms in the final isolated sample |
| Ten position updates after warm render | 350 catalog reads | 0 catalog reads |
| Row Play button after one 16ms frame | No request yet | One request |
| Song-options immediate tap | Menu not opened yet | Route starts immediately; entrance completes in 8 x 16ms frames |

Timings are single-run diagnostic observations and vary between runs; use the
per-run JSON for the actual sample. Counts and deterministic simulated
frame budgets are regression assertions. Ten complete tick rebuilds still took
about one second in the test host: no whole-screen frame-time improvement is
claimed. Menu timing measures the popup route, excluding the independent button
ink ripple; waiting for every animation would conflate those durations.

## Repeatable checks

From the repository root, use Git Bash:

```sh
bash scripts/app.sh test --no-pub --dart-define=OWNSEMBLE_PERF_LABEL=final test/large_library_performance_test.dart
bash scripts/app.sh test --no-pub test/library_controls_ui_test.dart
bash scripts/app.sh test --no-pub --concurrency=1
bash scripts/app.sh analyze --no-pub
```

The performance suite writes generated-only JSON under the ignored directory
`.local/ownsemble-performance/`, and a generated menu preview under
`.local/ownsemble-smoke/song-menu-preview.png`. It does not read real runtime
catalogs or open media/network/audio devices. Queue-jump tests allow at most 80
track reads at either size, independent of the number of preceding rows. Clock
updates require zero repeated catalog reads after warming. Tests also cover
catalog/cursor/pin invalidation, bounded cache eviction, cached missing values,
reduced-motion/keyboard dismissal, duplicate shuffled occurrences and 2x text scale.

The original failing runs were observed before their corresponding production
changes. Native generated smoke/restart is a separate integration check; physical
interaction/FPS across Windows, Linux and Android remains a separate benchmark
stage. Broader search/filter distributions, cold/warm frame and memory budgets,
first-sound network distributions, and instrumentation overhead remain follow-up
work, rather than being implied complete by these local regression checks.

## Validation of this slice

The final full Flutter suite passes 283 tests, including all nine focused
performance/interaction tests. The analyzer is clean. The unchanged JavaScript adapter suite passes 81 tests. Windows
Debug builds and the generated 1,200-row native catalog/play/seek/queue/cold-restart
smoke pass, including SQLite quick_check and parent/child exit 0. Native media
checks run at volume zero. The generated menu preview was inspected visually.
