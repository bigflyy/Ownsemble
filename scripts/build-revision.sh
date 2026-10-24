#!/usr/bin/env bash
# Emit a public source revision only; never read runtime/profile files or Git remotes.
set -euo pipefail
# Allow generated tests to supply a repository, defaulting to this source checkout.
task_repository="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
# Read only the commit identifier; source-only archives may have no Git metadata.
task_revision="$(git -C "$task_repository" rev-parse --short=12 HEAD 2>/dev/null || true)"
# Mark missing metadata honestly rather than claiming a known application build.
if [[ ! "$task_revision" =~ ^[a-f0-9]{7,40}$ ]]; then
  printf 'unlabelled\n'
  exit 0
fi
# Limit dirty checks to public application/tooling paths, excluding local runtime data.
if ! git -C "$task_repository" diff --quiet HEAD -- app scripts ||
   [[ -n "$(git -C "$task_repository" ls-files --others --exclude-standard -- app scripts)" ]]; then
  task_revision="$task_revision-dirty"
fi
printf '%s\n' "$task_revision"
