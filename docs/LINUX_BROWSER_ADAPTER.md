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

## Reproducible engine updates

`app/linux/browser/cef-runtime.json` pins Linux x64 CEF156.0.7 / Chromium156.0.8078.17
from the official public build index refreshed2026-10-22. The highest stable
Chromium version is selected numerically, ignoring upload order and beta builds.
The archive was verified against the published size/SHA1 and a SHA256 is pinned.
This checks byte identity; it is not a claim of security or universal compatibility.

On Linux, `python3 scripts/prepare-linux-browser.py CACHE_DIRECTORY` downloads and
verifies the pinned SDK and prints its directory. An existing archive is verified
again; an unmatched extraction destination is refused. Archives reject traversal,
links and special files before extraction. This SDK cache is separate from all app
sessions, catalogs and media. No session directory is inspected or cleaned.

For maintainers only, `--update-pin` refreshes the public index, selects the highest
stable Linux minimal artifact, downloads it and changes the source manifest.
Review the diff, rerun native/Flutter/privacy/TLS and packaged checks, then commit
that upgrade separately. The application does not silently upgrade its engine.
Track upstream security releases and ship timely tested updates. Keep the SDK and
archive out of Git and retain the supplied licenses in distributed bundles.

The pinned156 runtime also passes the same13 generated native adapter checks.
The SDK remains outside Git. Actual installed artifact validation is handled by
the subsequent packaging change; live VK is not established by these fixtures.
