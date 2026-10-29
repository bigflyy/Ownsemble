# Git workflow

Use a focused feature or fix branch from a reviewed baseline. Keep commits atomic:
one coherent behavior change with its necessary tests and documentation. Preserve
unrelated work and review status and diffs before editing.

For behavior changes, write meaningful regression tests first and observe the
expected failure before implementation. Run relevant checks after the correction.
Keep supplemental qualification results distinct from tests-first evidence.

Stage explicit intended paths, inspect the staged diff and run
`git diff --cached --check` before committing. Use clear imperative commit subjects.
Do not add assistant coauthor or attribution trailers.

Keep credentials, private browser sessions, real catalogs, cached user media,
SDKs, build outputs and temporary artifacts outside source control. Use the
repository's source line-ending rules. Local assistant configuration, instruction
files, handoffs and logs also stay outside published commits; put their ignore
entries in `.git/info/exclude` rather than changing the committed `.gitignore`.

Before a first push, review the entire unpublished history as well as the current
tree for excluded local files. Preserve the original local history when preparing
a separate filtered publication. Do not rewrite shared history, discard unrelated
work or force-push without explicit authorization.

Push reviewed, verified working milestones when publication is authorized. State
which source branch and checks were published, and document unresolved acceptance
gates separately from completed fixes. A local commit alone does not authorize
publication or deployment.
