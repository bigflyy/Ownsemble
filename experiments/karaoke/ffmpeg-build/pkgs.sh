#!/bin/bash
# Packages for the karaoke ffmpeg build (plan 11 B1), in the separate MSYS2.
# Usage: bash pkgs.sh size | install
set -u
PKGS="mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-pkgconf
mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja make diffutils autoconf automake
libtool git patch"
case "${1:-size}" in
  size)
    pacman -Syu --noconfirm 2>&1 | tail -2
    pacman -S --needed --print-format '%n %s' $PKGS |
      awk '{s+=$2} END {print NR, "packages,", int(s/1048576), "MB download"}'
    ;;
  install)
    pacman -S --needed --noconfirm $PKGS 2>&1 | tail -4
    gcc --version | head -1
    nasm --version
    meson --version
    pkgconf --version
    ;;
esac
