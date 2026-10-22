#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
proof_root="${OWNSEMBLE_LINUX_PROOF_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/ownsemble-linux-proof}"
cef_dir="${OWNSEMBLE_CEF_ROOT:-}"
if [[ -z "$cef_dir" ]]; then
  cef_dir="$(python3 "$repo_root/scripts/prepare-linux-browser.py" "$proof_root/cef-runtime")"
fi
build_dir="$proof_root/native-browser/build"
cmake -S "$repo_root/app/linux/browser" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCEF_ROOT="$cef_dir"
cmake --build "$build_dir" -j 8
ctest --test-dir "$build_dir" --output-on-failure
cmake --install "$build_dir" --prefix "$proof_root/native-browser/runtime"
