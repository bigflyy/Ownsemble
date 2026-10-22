# ADR 0003: qualify the Linux browser for desktop Linux, independently of WSL

Status: CEF selected for the next Linux adapter implementation; production acceptance pending.
Date: 2026-10-22.

The user explicitly requires a reliable, maintainable adapter for Ubuntu and other
Linux desktops. WSLg is an available test host. Do not choose a worse backend merely
to get a WSL pass, or reject an otherwise appropriate backend solely for a WSL
failure. Record host/environment failures separately from adapter limitations.

Keep MusicBrowser/Factory as the application boundary. Evaluate real native
behavior before declaring capabilities or wiring a Linux implementation. Keep
Windows stable and preserve the catalog/cache/session and current exact-recording,
per-event input, route/form, native audio isolation, cancellation and TLS guards.
Do not replace them with DOM clicks, DOM-only mute, transparent windows, disabled
sandbox/certificate checks or copied account cookies. No production dependency
upgrade is part of a feasibility probe.

## Comparison and current evidence

| Candidate | Desktop fit and maintenance | Evidence / unresolved gate |
| --- | --- | --- |
| WebKitGTK | Natural GTK desktop integration; Ubuntu24.04 packages provide GTK3 API4.1 and security updates | Actual2.52.6 native probe passes pre-navigation mute, sandbox enabled, strict TLS setting, document-start script, hidden trusted/focused click, independent documents and cached fetch observations. Hidden media never loads; visible control plays and advances its clock. Not qualified for our invisible fallback path. |
| WPE WebKit | Official embedded/offscreen WebKit port; suitable architecture for an invisible renderer | Existing Flutter Linux package configure failed because runtime is absent. Ubuntu package availability/packaging needs work. This is NOT an engine runtime failure or reason to reject it just for WSL. |
| CEF / Chromium | Explicit windowless rendering/input/native-mute APIs and Chromium compatibility; bundled engine means an explicit security-update/distribution obligation | Verified public Linux build152.0.15. Both windowless and native hidden-window probes pass trusted/focused input, document-start scripts, cached requests, advancing media and native audio capture/discard. Native Views permits showing/hiding the same document for private sign-in. Sandbox is requested but renderer attestation and remaining adapter lifecycle/packaging gates are still pending. |
| External browser automation | Existing browsers can be maintained separately | Not selected as a shortcut: exposed debugging endpoints, session ownership, input/audio isolation and browser availability would all need an equally strong contract. |

These are not interchangeable plugin badges. Runtime security, invisible native
input/media, private session ownership, observation of cached requests, startup
latency/idle cost, distribution ABI/packaging, update cadence and VK compatibility
all matter. Prefer a maintained upstream implementation over an application fork
of a browser engine. A small native adapter is different from maintaining WebKit
or Chromium itself.

## Probe scope and what remains

Generated fixtures only; see [the probe](../LINUX_BROWSER_PROBE.md). No VK, sign-in,
existing profile inspection, cookies, catalog or user media involved. Actual
Linux VK is still unsupported in production. Implement the Linux adapter with
CEF's native Views/Alloy window, initially hidden, behind MusicBrowser. The same
window can show private sign-in and hide without replacing the document. This uses
supported native desktop windowing, not a transparent-window workaround. Discard
native captured audio unconditionally: Chromium resets its ordinary mute flag on
navigation, so that flag alone is insufficient. This was reproduced before the
native-capture correction. No browser engine fork is introduced.

CEF startup originally stalled inside Chromium's standalone first-run EULA dialog;
a generated-only native stack identified it. The embedded helper now suppresses
standalone first-run UI. This was a configuration defect, not established WSL
incompatibility. Correct DevTools request ordering and Page.enable are needed for
its document-start script. Both corrected probes pass. See the qualification log.

The bundled CEF engine creates a security-update and packaging responsibility.
Pin/verify releases, retain licenses, test upgrades and arrange timely security
updates; do not ship an indefinitely frozen engine. The contract isolates this
choice from VK policy, storage and playback. Android remains a separate native
WebView adapter, not a CEF deployment. Qualify on native Ubuntu X11/Wayland, then
another distribution family, with clean packaging and ordinary audio devices.

Before production wiring, prove native isolation for every document before any
provider navigation, trusted per-event guarded input without OS focus theft,
independent hidden documents, cached-media request witnesses, private sign-in to
hidden-session transition, persistence/restart, cancellation/crash/late-callback
cleanup and strict TLS negative cases. Existing policy tests remain required.
Then run native UI/media/cache/offline/restart suites and separate scoped VK
acceptance. Generated success alone cannot establish live-provider compatibility.

Primary sources: [WebKitGTK API](https://webkitgtk.org/reference/webkit2gtk/stable/class.WebView.html),
[WPE purpose](https://wpewebkit.org/about/what-is-embedded.html),
[CEF native windowless integration](https://chromiumembedded.github.io/cef/general_usage.html),
[CEF native mute API](https://github.com/chromiumembedded/cef/blob/master/include/cef_browser.h),
[CEF capture mutes output](https://github.com/chromiumembedded/cef/blob/master/include/cef_audio_handler.h).
The hidden-media symptom also matches existing upstream Linux report
[WebKit bug232860](https://bugs.webkit.org/show_bug.cgi?id=232860). This supports
investigating an engine/container limitation; it does not prove the cause of our
specific run or that all WebKitGTK integrations fail.
