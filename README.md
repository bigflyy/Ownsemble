# Ownsemble

A Windows music library built with **Flutter, Dart and SQLite**, structured for later Android reuse.

Double-click **Start Ownsemble.cmd** in this folder, then **Connect VK** once. Your local library, Piles, queue, playback history and pins persist between launches. The app refreshes VK progressively while open and plays complete cached songs offline.

The first Windows candidate includes local search, All/VK/Recent/Most played/Offline views, play/pause/seek/volume, next/previous, queue, shuffle/repeat, automatic caching, individual/Pile pins and several named Piles with independent repeated entries. VK playlist browsing and playlist-wide pins are still gated on real membership verification.

## Current validation

The current [Windows browser repair](docs/WINDOWS_BROWSER_REGISTRATION.md) and [partial VK pagination checkpoint](docs/VK_PAGINATION_REPAIR.md) describe the latest scoped validation. Broader automated contracts and native generated-media checks are documented in [implementation status](docs/IMPLEMENTATION_STATUS.md). The native run uses a separate 1,200-song fixture catalog, verifies playback/seek, persistence and cache retention, renders the actual interface, and restarts offline. Real VK refresh/background behavior and uncached startup latency still need acceptance in this production host. Earlier [Windows VK feasibility](docs/VK_FLUTTER_FEASIBILITY.md) passed, including the user's audible offline check. Actual Android VK access remains unverified.

The app and both feasibility probes are separate. Nothing reads or copies account cookies, passwords, private profiles or temporary audio links into logs. The user signs in privately. Authorized live checks use fixed app-owned controls and sanitized numeric reports; generated test data stays separate from the real catalog.

## Development and requirements

- [App build, test, development and runtime instructions](app/README.md)
- [Approved MVP requirements and acceptance gates](docs/MVP.md)
- [Git workflow and tests-first development](docs/GIT_WORKFLOW.md)
- [Flutter and Android feasibility evidence](docs/VK_FLUTTER_FEASIBILITY.md)
- [Preserved Electron reference evidence](docs/VK_FEASIBILITY.md)
- [Research and technology comparison](docs/RESEARCH.md)

`app/` contains production code/tests/assets and the Windows runner. `spikes/` preserves both experiments. `scripts/` contains scoped toolchain and control helpers. `.local/` is ignored local data, reports, caches and SDKs; browser profiles remain private. See the app README for pinned dependencies and reproducible commands. Source changes are tracked in Git; publication and deployment require separate authorization.
