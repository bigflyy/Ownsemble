#!/bin/bash
# Pack the release files of video-tools-1 (plan 11 B2): ffmpeg.exe, NOTICES.txt
# (every licence of the parts inside the exe) and the GPL source bundle
# ffmpeg-video-tools-1-sources.tar (upstream archives, build scripts, build
# record, README). Runs in Git Bash after build.sh. Output: ../video-release.
set -euo pipefail
TOOLS=/c/MyProjects/Ownsemble/.local/v2-tools
REPO=/c/MyProjects/Ownsemble/experiments/karaoke/ffmpeg-build
SRC=$TOOLS/video-src
EXTRA=$TOOLS/video-src-extra
BUILD=$TOOLS/video-build
LIC=$TOOLS/msys2-video/msys64/ucrt64/share/licenses
OUT=$TOOLS/video-release/video-tools-1
STAGE=$TOOLS/video-release/stage
X264=x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/texts" "$STAGE/bundle/sources" "$STAGE/bundle/build" "$OUT"

# Licence texts straight out of the archives that were built.
pull() { # $1 archive, $2 path inside it, $3 name to save as
  tar -xOf "$SRC/$1" "$2" > "$STAGE/texts/$3"
}
pull ffmpeg-9.1.tar.xz ffmpeg-9.1/LICENSE.md ffmpeg-LICENSE.md
pull ffmpeg-9.1.tar.xz ffmpeg-9.1/COPYING.GPLv2 GPLv2.txt
pull ffmpeg-9.1.tar.xz ffmpeg-9.1/COPYING.LGPLv2.1 LGPLv2.1.txt
pull "$X264.tar.bz2" "$X264/COPYING" x264-COPYING
pull libass-0.17.5.tar.xz libass-0.17.5/COPYING libass-COPYING
pull freetype-2.15.0.tar.xz freetype-2.15.0/LICENSE.TXT freetype-LICENSE.TXT
pull freetype-2.15.0.tar.xz freetype-2.15.0/docs/FTL.TXT freetype-FTL.TXT
pull fribidi-1.0.18.tar.xz fribidi-1.0.18/COPYING fribidi-COPYING
pull harfbuzz-15.2.0.tar.xz harfbuzz-15.2.0/COPYING harfbuzz-COPYING

section() { # $1 title, $2 file
  printf '\n\n==============================================================================\n'
  printf '%s\n' "$1"
  printf '==============================================================================\n\n'
  tr -d '\r' < "$2"
}
{
  tr -d '\r' < "$REPO/NOTICES-head.txt"
  section "FFmpeg: LICENSE.md" "$STAGE/texts/ffmpeg-LICENSE.md"
  section "GNU General Public License, version 2 (FFmpeg COPYING.GPLv2)" "$STAGE/texts/GPLv2.txt"
  section "x264: COPYING (GPL 2, an older printing with the old FSF address)" "$STAGE/texts/x264-COPYING"
  section "GNU Lesser General Public License, version 2.1 (FFmpeg COPYING.LGPLv2.1)" "$STAGE/texts/LGPLv2.1.txt"
  section "GNU FriBidi: COPYING" "$STAGE/texts/fribidi-COPYING"
  section "libass: COPYING (ISC)" "$STAGE/texts/libass-COPYING"
  section "FreeType: LICENSE.TXT" "$STAGE/texts/freetype-LICENSE.TXT"
  section "FreeType: FTL.TXT (the licence used)" "$STAGE/texts/freetype-FTL.TXT"
  section "HarfBuzz: COPYING" "$STAGE/texts/harfbuzz-COPYING"
  section "zlib: LICENSE" "$LIC/zlib/LICENSE"
  section "MinGW-w64 runtime: COPYING.MinGW-w64-runtime.txt" "$LIC/crt/COPYING.MinGW-w64-runtime.txt"
  section "MinGW-w64 winpthreads: COPYING" "$LIC/winpthreads/COPYING"
  section "GCC Runtime Library Exception, version 3.1 (libgcc, libstdc++)" "$LIC/gcc/COPYING.RUNTIME"
  section "GNU General Public License, version 3 (GCC runtime libraries)" "$LIC/gcc/COPYING3"
} > "$OUT/NOTICES.txt"

# The source bundle.
cp "$SRC"/*.tar.* "$SRC/SOURCES.sha256" "$STAGE/bundle/sources/"
cp "$EXTRA/mingw-w64-zlib-1.4-2.src.tar.zst" "$EXTRA/mingw-w64-zlib-1.4-2.src.tar.zst.sig" \
  "$STAGE/bundle/sources/"
(cd "$EXTRA" && sha256sum mingw-w64-zlib-1.4-2.src.tar.zst) >> "$STAGE/bundle/sources/SOURCES.sha256"
for f in fetch.sh pkgs.sh msys.ps1 build.sh; do
  # The copies that ran must match the committed ones.
  diff -q "$BUILD/$f" "$REPO/$f"
  cp "$BUILD/$f" "$STAGE/bundle/build/"
done
cp "$BUILD/out/BUILD-INFO.txt" "$STAGE/bundle/build/"
cp "$REPO/SOURCES-README.txt" "$STAGE/bundle/README.txt"
cp "$OUT/NOTICES.txt" "$STAGE/bundle/NOTICES.txt"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-11-28 00:00Z' \
  -cf "$OUT/ffmpeg-video-tools-1-sources.tar" -C "$STAGE/bundle" .

cp "$BUILD/out/ffmpeg.exe" "$OUT/ffmpeg.exe"
(cd "$OUT" && sha256sum ffmpeg.exe NOTICES.txt ffmpeg-video-tools-1-sources.tar > SHA256SUMS.txt)
rm -rf "$STAGE"
ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt"
tar -tvf "$OUT/ffmpeg-video-tools-1-sources.tar"
