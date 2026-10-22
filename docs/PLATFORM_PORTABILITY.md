# Platform portability and acceptance

Updated 2026-10-22 after the user selected the architecture rework. The earlier
assessment/proposal has now been followed by implemented interfaces and a Windows
adapter extraction. See [architecture](ARCHITECTURE.md) and [ADR 0001](decisions/0001-platform-boundaries.md).
The Linux native UI milestone is now implemented and checked in WSLg; see
[the Linux proof](LINUX_PROOF.md). Live VK and broader distribution acceptance
remain pending. Android production acceptance is still separate.

## Implemented foundation

- AppController consumes provider, playback, decoder, runtime and trust interfaces;
  bootstrap selects concrete implementations. No browser profile path or executable
  selection lives in application orchestration. Views retain the existing facade.
- VK policy and its transitive dependencies are pure Dart. Browser-plugin types,
  DevTools calls, native mute/input/focus/request observation and the dedicated
  environment live in the Windows adapter. Required capabilities fail closed.
- The current Windows implementation, browser package pin and native mute patch
  are retained. Native media and certificate-chain fallback are isolated too;
  caches use injected trust with strict rejection by default.
- The same generated provider-policy/queue probe passed with Dart3.13.5 on Windows
  and Linux in WSL. This proves shared policy execution, not a Linux browser or UI.
- The Windows generated native browser smoke now drives the new adapter contract,
  testing native isolation, trusted input, hidden independent documents,
  document-start scripts and browser-cache request witnesses. Final rebuilt-mode
  acceptance and scope belong in the latest SESSION_HANDOFF.md section.

## Target gates

| Target | Current evidence | Still required |
| --- | --- | --- |
| Windows | Shared/unit suite, generated native browser/media/restart/retention; final reports in handoff | Retain regression gates for each adapter change; live samples never certify every recording |
| Linux | Native GTK Debug/Release UI, generated media/cache/restart/window-close checks and180 Flutter tests pass in Ubuntu24.04 WSLg; one Windows-only test skipped | Qualified browser adapter, real VK, packaging and ordinary Ubuntu/other-distribution acceptance |
| Android | Historical isolated synthetic WebView input/resource-hook/audio/cache/seek/offline proof in VK_FLUTTER_FEASIBILITY.md | Current production browser native mute/identity/cancellation contract, real VK, physical audibility, permissions/background audio/media controls |
| macOS/iOS | No current project-specific acceptance | Target setup and the same platform/provider gates; no support claim from a plugin badge |

The Android historical probe was not rerun during this rework. It does not certify
parity with the newer production identity/native-mute contract. A matching scoped Flutter3.47.7 SDK and GTK/clang/Ninja/libmpv prerequisites are
now installed in Ubuntu. WPE is still missing: public Linux-plugin CMake readiness
fails with WPE WebKit not found. Linux native sources under app/linux use standard
GTK/Flutter, with no WSL-only app runtime path. WSLg is a test host; Ubuntu native
desktop and another distribution family still need separate acceptance.

## Current Linux browser selection

The user explicitly prioritizes a strong ordinary Ubuntu/Linux desktop choice over
WSL compatibility. [ADR0003](decisions/0003-linux-browser-selection.md) records this
requirement. Native WebKitGTK2.52.6 generated probes now run: input/focus/native mute/
cache witnesses pass, but offscreen media stalls while the visible control plays.
CEF now passes both native windowless and hidden Views/Alloy media/input/cache
probes after correcting standalone first-run UI and installing native audio
capture/discard. CEF native Views is selected for adapter implementation; full
lifecycle/sandbox/packaging/Ubuntu acceptance remain. No production Linux browser
is wired and no live VK is tested. WPE remains an unqualified alternative. See
[the detailed probe](LINUX_BROWSER_PROBE.md). Earlier plugin-only candidate notes
below are historical context, not a selected engine or runtime acceptance.

## Linux browser candidate and the corrected earlier answer

Production pins flutter_inappwebview6.1.5; that manifest lacks Linux. However,
upstream [6.2.0-beta.3](https://pub.dev/packages/flutter_inappwebview/versions/6.2.0-beta.3)
lists Linux and requires WPE2.0 WebKit. A browser engine from scratch may therefore
be avoidable. The broader initial statement that the library offered no Linux
support was too pessimistic and was corrected before this rework.

An isolated public-source review of
[flutter_inappwebview_linux0.1.0-beta.1](https://pub.dev/packages/flutter_inappwebview_linux/versions/0.1.0-beta.1)
found native isMuted/setMuted bindings and WebKit muting, plus native WPE pointer
handling. That is a feasibility signal, not proof that our exact trusted-input,
hidden-document focus, pre-navigation isolation or cached-request witness contract
is available through the same API. Windows CDP calls cannot simply be renamed or
left in shared code. Generated target-native tests must establish equivalent
behavior, or an adapter-specific native binding must supply it. No production
package upgrade was made and no untested platform is wired as supported.

The separation follows Flutter's guidance on
[responsibilities](https://docs.flutter.dev/app-architecture/guide) and
[platform implementations](https://docs.flutter.dev/packages-and-plugins/developing-packages#federated-plugins).
Those patterns do not replace acceptance of our actual app behavior.

## Next platform implementation

1. Preserve the tested Windows baseline and keep the same shared contracts.
2. Probe the candidate in an isolated target host with generated pages/media,
   including native mute before navigation, trusted per-event input, cached request
   observation, independent hidden documents, cancellation and private-session
   lifecycle. No sign-in/profile inspection in agent probes.
3. Implement/wire only capabilities that pass. Then run target audio/seek/cache/
   offline restart and packaging gates. Never use untrusted DOM clicks or DOM-only
   muting as a silent replacement for mandatory native guarantees.
4. Run separate actual-provider acceptance with private sign-in handled by the
   user and fixed app-owned controls/sanitized results. Background media controls
   and permissions are additional mobile gates.

Existing SQLite schema and files were preserved. Absolute asset-path relocation,
provider identity/provenance for future sources and OS permissions still need
explicit additive tests/migrations. A shared core is not a claim that a Windows
database copied to another OS is already a usable offline library.
