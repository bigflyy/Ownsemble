#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
proof_root="${OWNSEMBLE_LINUX_PROOF_ROOT:-/opt/ownsemble-linux-proof}"
cef_dir="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["directory"])' "$proof_root/cef-probe/selected.json")"
cmake -S "$source_dir" -B "$proof_root/cef-probe/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCEF_ROOT="$cef_dir"
cmake --build "$proof_root/cef-probe/build" -j 8
python3 - "$cef_dir" "$proof_root/cef-probe/build" <<'PY'
from pathlib import Path
import sys
sdk, target = map(Path, sys.argv[1:])
for source in (sdk / 'Release', sdk / 'Resources'):
    for file in source.iterdir():
        destination = target / file.name
        if not destination.exists():
            destination.symlink_to(file, target_is_directory=file.is_dir())
PY
