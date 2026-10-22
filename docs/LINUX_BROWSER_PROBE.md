# Linux browser qualification probes

2026-10-22. Isolated feasibility work under spikes/linux-browser. The production
app still uses the unsupported-browser guard on Linux; no app/lib, dependency,
SQLite, JS or Windows runner behavior was changed. See ADR0003 for the user's
Ubuntu/Linux-first requirement and selection criteria. WSL convenience is not an
engine-selection criterion.

## Reproduce WebKitGTK

On an ordinary Ubuntu24.04 desktop with Python3/PyGObject and GTK3, install the
standard packages libwebkit2gtk-4.1-dev, gir1.2-webkit2-4.1 and
gstreamer1.0-pulseaudio alongside normal GStreamer base/good plugins. No OS-wide
upgrade, sandbox-disable, TLS bypass or WSL-specific browser flag is used.

From the repository root on Linux:

```bash
python3 scripts/test_linux_browser_fixture.py
python3 scripts/test_linux_browser_probe.py
```

The qualification command currently exits1: two tests run, visible control passes,
hidden media gate fails. This failure is deliberate evidence, not an accepted
backend. Scripted checks were written/run before their implementations; more
specific failing checks preceded focus, cache-session and byte-range corrections.
The source-only app harness does not import these experiments into production.

probe.py creates only generated loopback HTML, cached text and a small generated
WAV. Native mute is set/checked before navigation; the HTML audio is unmuted at
volume1. Scripted native GDK pointer events are trusted in the renderer. Native
focus events activate its offscreen document without a visible browser or OS focus
request. A fresh engine-owned generated session exercises caching; no session files
are inspected. An ephemeral context is checked separately, not misrepresented as
the cache-bearing context. It uses native TLS FAIL and explicitly enables sandbox.

The final hidden probe2.52.6 passes all tested setup/input/cache/document checks,
but makes zero WAV requests, stays readyState0/time0 and never resolves Play.
The visible generated control requests the WAV, advances time with no media error
and stays natively muted. The fixture's HTTP range contract was first reproduced
failing, then corrected/tested for bounded/open/suffix ranges and416. This prevents
an unrelated loop/seek server error from masquerading as a backend failure.
No physical speaker isolation or real-provider compatibility is established.

Safe evidence in .local/linux-proof/evidence:
- browser-webkit-capabilities.json: hidden result, including failure.
- browser-webkit-visible-control.json: successful visible comparison.
- browser-webkit-qualification.txt:1pass/1fail; prior red logs retained.
- browser-fixture-green.txt and browser-fixture-range-red.txt.

## CEF comparison

Public upstream automated-build index selected Linux stable152.0.15
(chromium152.0.7977.169). The321,344,911-byte minimal archive was verified against
its published SHA-1 before extraction under /opt/ownsemble-linux-proof/cef-probe.
This checks transfer identity; it is not a security certification. SDK/header/
wrapper/resources remain outside production dependencies and repository source.

Native cef_probe.cc compiles with the package's CMake wrapper, using C++20. The
build helper creates an isolated standard flat resource/library layout. The
Python runner builds first and uses that same layout for library lookup, preventing
stale-binary execution. OWNSEMBLE_LINUX_PROOF_ROOT
can select another prepared root; selected.json identifies the public SDK path.
The /opt default is probe tooling, not a production installed layout.

```bash
bash spikes/linux-browser/build-cef.sh
python3 scripts/test_linux_cef_cleanup.py
python3 scripts/test_linux_cef_probe.py
```

Current CEF qualification passes both tests: genuine windowless and genuine native
Views/Alloy hidden-window mode. Both load generated media, advance its clock,
receive trusted/focused input, install document-start scripts, observe2cached fetch
requests with1network transfer, and close cleanly. Native hidden-window mode is the
adapter direction: its window can show private sign-in without replacing a page.
Focused input waits for native focus-emulation acknowledgement before dispatch;
a failing focus-order test preceded the correction. Showing/hiding and the complete
adapter lifecycle still need their own tests.

The original initialization timeout was diagnosed with a generated-process GDB
stack: Chromium waited inside first_run::internal::ShowEulaDialog. Suppressing its
standalone first-run UI corrects embedded startup. Initial ICU layout and stale
binary issues were also corrected. The runner always builds current source first.
DevTools request IDs must increase and Page.enable precedes document-start scripts;
a failing native test preceded this correction. Native Views and BrowserView both
need Alloy style; the mismatch failed before its fix.

The test also reproduced Chromium resetting its ordinary native mute flag during
navigation. Pre-navigation SetAudioMuted alone is insufficient. CefAudioHandler is
installed before any page loads, always accepts native capture and discards every
packet without reading/copying/persisting PCM content. CEF mutes physical output
while capturing (upstream contract); native stream/frame counts and an unmuted HTML
player advancing its clock prove that this path is exercised. A capture error
closes the browser. The report truthfully retains native_mute_during_media=false;
output isolation is provided by native capture, not that flag or DOM muting.
No independent physical sound-device measurement is claimed.

Sandbox remains requested but renderer attestation is still pending. No
--no-sandbox, TLS bypass, transparent-window trick or host-policy change was used.
New evidence: browser-cef-windowless-final.json and browser-cef-views-final.json;
corresponding green and prior failing logs. Production Linux VK is not wired yet.

A timed-out Chromium child retained a pipe after its parent group was terminated.
A tests-first cleanup regression now permits killing only same-user processes
whose exact executable resolves to this isolated generated helper; an unrelated
fixture executable is protected. No Ownsemble preview/Windows app is terminated.
Probe sessions are created afresh and never inspected. Native logs contain only
generated fixtures; sanitized reports carry checks/counts/error categories.

CEF is selected for implementing the Linux adapter; see ADR0003. The full native
privacy/lifecycle/session/sandbox/packaging gates and normal Ubuntu/other-distro
acceptance remain. This generated proof is not Linux VK success.
