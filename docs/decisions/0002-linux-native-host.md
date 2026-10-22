# ADR 0002: standard Linux GTK host with an isolated generated-data harness

Status: accepted for the user-requested Linux UI milestone, 2026-10-22.

Add a standard Flutter Linux GTK host under app/linux. Keep shared Dart source,
provider policy, dependency pins, data schema and Windows native behavior unchanged.
Use WSLg as the available first host, while targeting ordinary Linux interfaces.
No WSL paths or dependencies are introduced in application runtime code.

Stage source/resources into a separate Linux workspace before dependency resolution
and builds. Do not reuse Windows tool output, browser session, real catalog or
cached user audio. Archive/launcher tests enforce the staging contract; generated
fixtures alone drive native smoke checks and the interactive preview.

Implement the existing ownsemble/lifecycle channel in GTK. Intercept window-close
before Flutter's default handler; wait for the shared shutdown acknowledgement,
with a bounded fallback. Programmatic test close is supported too. Native failures
were reproduced before these corrections. The --lifecycle-smoke native test hook
only operates with the generated --demo mode.

A visible UI, passing generated media tests and WSLg success do not establish live
VK or support for every Linux distribution. The current browser candidate's WPE
runtime is absent, and a source configure probe fails explicitly. Keep unsupported
browser capabilities disabled. Ordinary Ubuntu desktop, another distribution
family, packaged launch and real-provider acceptance remain separate gates.

See LINUX_PROOF.md for evidence, reproduction and precise limitations.
