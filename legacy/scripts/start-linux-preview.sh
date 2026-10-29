#!/usr/bin/env bash
# Windows/Git Bash launcher only. The Linux application has no WSL dependency.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -W)"
distro="${OWNSEMBLE_WSL_DISTRO:-Ubuntu}"
proof_root="${OWNSEMBLE_LINUX_PROOF_ROOT:-/opt/ownsemble-linux-proof}"
linux_root="$(MSYS_NO_PATHCONV=1 wsl.exe -d "$distro" --exec wslpath -u "$repo_root")"
linux_root="${linux_root//$'\r'/}"
MSYS_NO_PATHCONV=1 wsl.exe -d "$distro" --exec env \
  "OWNSEMBLE_LINUX_PROOF_ROOT=$proof_root" \
  "OWNSEMBLE_FLUTTER_SDK=${OWNSEMBLE_FLUTTER_SDK:-$proof_root/flutter}" \
  bash "$linux_root/scripts/linux-app.sh" preview "${1:-release}"
