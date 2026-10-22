# Linux native UI proof

Implemented 2026-10-22 after the user requested a visible Linux UI through WSL.
The target is ordinary Linux desktop software. WSLg is the first test host; the
application has no WSL-only runtime dependency or /mnt/c path in its Linux host.
This delivers a generated-data native UI/audio prototype. Live VK is still gated.

## Delivered and verified

- Standard Flutter GTK host under app/linux, Debug and Release Linux x64 builds.
- Visible Ownsemble (Linux) window with 1,200 generated records, Cyrillic search,
  cache/queue/occurrence/pin behavior and rendered UI. The generated preview was
  visually inspected. Final interactive Release preview remains open (refresh
  liveness); app volume23, paused, no loading. Only bundled generated test audio.
- Existing native playback/seek, mute/restore and restart checks pass in both
  initial Debug and final Release. Generated delayed-network streaming passes
  prefix playback before completion, seek, shared fetch, validation and offline
  replay. The streaming fixture intentionally uses null audio output. Automated
  checks do not establish that a person physically heard sound from the device.
- Linux shutdown bridge uses the existing ownsemble/lifecycle channel. Window
  close waits for shared shutdown before GTK exits. A bounded fallback remains
  for an unresponsive renderer. Regression tests first demonstrated missing
  programmatic close and missing native window-shutdown acknowledgement, then
  passed after the bridge and handler ordering fix. Debug/Release checks pass.
- 180 Flutter tests pass on Linux; one Windows certificate-policy test is correctly
  skipped. Linux analyzer is clean. Source archive and launcher tests pass; failing
  logs preceded fixes. Windows source archive symlink fixture is skipped where OS
  permissions prevent creating a fixture symlink; that test passes on Linux.
- All shared Dart sources, production dependency/lock files and guarded JS bundle
  match the preceding Windows-validated architecture baseline. No browser package
  upgrade, private session access, catalog import or production data migration.

Safe evidence: .local/linux-proof/evidence/validation.json and named reports there.
Generated release-preview.png is app-only rendering, with no real catalog/sign-in.
Mesa/EGL and PipeWire warnings occurred despite functional checks passing; do not
claim all native logs are clean or all machines/distributions are accepted.

## Reproduce from Windows / Git Bash

The prepared host is Ubuntu WSL, workspace /opt/ownsemble-linux-proof/workspace,
scoped matching Flutter3.47.7 SDK under /opt/ownsemble-linux-proof/flutter.

```bash
bash scripts/start-linux-preview.sh release
```

This WSL launcher translates the checkout path and calls the Linux-native harness.
It opens generated preview data. It does not launch the Windows private session.
The WSL-specific launcher is development tooling, not an application dependency.
OWNSEMBLE_WSL_DISTRO and OWNSEMBLE_LINUX_PROOF_ROOT can select a prepared test host.

## Reproduce on ordinary Linux

Use Flutter3.47.7 / Dart3.13.5 and the standard Linux desktop prerequisites (clang,
CMake, Ninja, pkg-config, GTK3 development headers and libstdc++ development files).
The tested Ubuntu host also has libmpv development packages. No blanket OS upgrade
was performed; dependencies were installed in Ubuntu, not Windows.

From the repository root:

```bash
bash scripts/linux-app.sh build release
bash scripts/linux-app.sh preview release
bash scripts/linux-app.sh smoke release
bash scripts/linux-app.sh streaming release
```

The default proof root is the user's cache directory / ownsemble-linux-proof.
An explicit OWNSEMBLE_FLUTTER_SDK selects a scoped SDK; otherwise Flutter is taken
from PATH. An explicit OWNSEMBLE_LINUX_PROOF_ROOT changes the separate test root.
The harness archives only allowlisted source/resources, rejects source symlinks,
excludes runtime/profile/build/ephemeral data and stages a separate workspace with
its own dependencies, generated SQLite data and output. It never stages .local,
.env files or the real Windows catalog/cache. Building in the same Windows app/
folder would mix platform tool output, so the Linux harness always stages first.

The Release bundle uses $ORIGIN/lib for native library lookup. GTK/system ABI and
package requirements still matter. A build on Ubuntu24.04 is not a guarantee for
all older Linux distributions. Distribution packaging/runtime choice and clean-host
acceptance remain explicit work.

## VK browser readiness: generated adapter gates pass; live VK pending

The Linux composition now selects a native CEF Views/Alloy adapter and the harness
bundles pinned CEF156 with resources/licenses. See LINUX_BROWSER_ADAPTER.md and
ADR0003. Windows6.1.5/native patch stay stable. Shared policy remains pure Dart.
Generated native adapter14checks and actual Flutter browser smoke pass, including
native isolation/trusted focused input/cached witnesses, sandbox attestation,
private show/hide/popup cleanup, restart, cancellation, crash recovery and TLS
negative cases. Linux197 Flutter tests plus1platform skip and analyzer pass.
No sign-in, account catalog/profile inspection or live VK acceptance occurred.

Ordinary Ubuntu/Linux quality remains the priority, independently of WSL. The
previous WPE package readiness failure is historical; no WSL-only runtime is used.
New session sign-in must be completed privately by the user. Generated acceptance
cannot establish compatibility with VK's real current website.

## Broader Linux acceptance

| Target | Status |
| --- | --- |
| Ubuntu24.04 x64 under WSLg | Native Debug/Release UI and generated audio/cache/lifecycle checks passed |
| Ubuntu24.04 native desktop or separate VM | Pending: rendering, actual audio devices, window close, permissions and packaged launch |
| Another distribution family, such as Fedora | Pending: dependencies/runtime, packaged launch and the same acceptance suite |
| Linux live VK | Pending browser runtime/adapter, then private sign-in and scoped provider acceptance |
| Android | Separate native implementation/acceptance; no readiness claim from Linux tests |

No Windows-to-Linux real-cache relocation has been performed. Existing absolute
paths and multi-source provenance still require the separately documented tested
migration contracts. See PLATFORM_PORTABILITY.md and ARCHITECTURE.md.
