# Git workflow

The user requires good Git practices, including atomic commits (2026-10-22).
AGENTS.md makes this a repository rule.

The initial commit d5654bc captures the existing application and preserved probes,
with fresh Windows analyzer/181 Flutter/48 Node checks. Its documentation uses the
preceding Linux UI checkpoint. Private/runtime data and the newer browser
experiments were excluded; working files were preserved. This initial import is
the baseline, not a claim that Linux VK is complete.

Continue browser work on feat/linux-browser-adapter. Commit each completed coherent
slice together with its tests and relevant documentation, after observing the
required tests-first failure and running the relevant green checks. Stage explicit
paths, inspect the staged diff, check whitespace and keep unrelated work separate.
Do not commit unfinished tests as accepted production behavior; isolated feasibility
qualification may record an unsupported capability honestly.

Keep local sessions, credentials, real catalogs/user media, SDKs and build outputs
excluded. Use the source line-ending rules in .gitattributes. Do not destructively
reset unrelated changes or rewrite existing history. No push/publication is
implicitly authorized by a local commit. Recovery snapshots remain supplementary.
