# Linux native browser adapter

The adapter uses CEF Views/Alloy behind MusicBrowser. Dart communicates with a
child helper through inherited JSON pipes; no debugging listener or cookie export
is exposed. Every document must attest native audio capture and renderer seccomp
before the provider can navigate. Native audio is captured and discarded without
reading/copying/persisting samples. Password saving/autosignin are disabled.

The same native document can show private sign-in and hide afterward. Navigation
passes the application policy, including server redirects. TLS failures are denied.
Request observation exports URI/kind only; native diagnostics contain categories,
never console contents, headers, bodies or authentication responses. Browser-owned
session files must never be inspected by agents, including generated sessions.

## Validation of the adapter module

Tests-first factory/lifecycle/privacy/sandbox regressions were observed failing
before correction. Additional wire-protocol cases supplement them. Current full
Windows Flutter suite:195 passed; analyzer clean. Native generated integration:
13 checks passed on Ubuntu24.04/WSLg against the feasibility CEF152 build:

- audio isolation and renderer sandbox before navigation;
- document-start scripts and independent documents;
- hidden trusted/focused media input;
- hidden popup denial and private popup cleanup;
- show/hide preserves the document;
- script errors expose only a category;
- application navigation fencing, including redirects;
- cached request observations;
- invalid TLS certificate rejection before HTTP data;
- clean helper shutdown and session restart persistence;
- closing cancels a stalled evaluation.

Synthetic process-tree tests verify that only sandboxed descendants can attest a
renderer. The renderer reports its own PID; the parent reads only kernel security
metadata of its own descendants. Renderer-side sandbox introspection itself was
blocked by seccomp and was replaced with this parent-side check.

Reproduce the module check with `bash scripts/build-linux-browser.sh` in Linux,
then `dart app/tool/native_linux_browser_probe.dart HELPER OUTPUT.json` from the
repository root using its Linux Dart SDK. Requires openssl for generated TLS data.
Evidence is local and ignored: `.local/linux-proof/evidence/native-linux-browser-commit.json`.

This commit provides the adapter module, not production Linux selection or a
packaged runtime. Those remain separate changes. CEF152 was a feasibility build:
public build upload order does not identify the highest supported stable Chromium
branch. Packaging must pin/verify a current stable engine, retain licenses and
provide an explicit update procedure. Native Ubuntu X11/Wayland, another distro
family, physical audio and separate privacy-scoped VK acceptance remain gates.
Windows implementation, existing catalog/cache and private sessions are unchanged.
