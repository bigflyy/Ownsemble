#!/usr/bin/env bash
set -euo pipefail
printf 'BASH_READY\n'
if cat .local/sandbox-proof/private/sentinel.txt >/dev/null 2>&1; then
  printf 'Bash could read the synthetic private file.\n' >&2
  exit 1
fi
if ls .local/sandbox-proof/private >/dev/null 2>&1; then
  printf 'Bash could list the synthetic private directory.\n' >&2
  exit 1
fi
printf 'BASH_PRIVATE_ACCESS_BLOCKED\n'
git status --short
python --version
