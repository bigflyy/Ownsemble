#!/bin/bash
# Download the sources for the karaoke ffmpeg build (plan 11 B1) into
# ../video-src (also the GPL source bundle of B2). Checks signatures where the
# project publishes them; records sha256 of everything in SOURCES.sha256.
# Runs in Git Bash (curl, gpg).
set -euo pipefail
SRC=/c/MyProjects/Ownsemble/.local/v2-tools/video-src
GPGDIR=/c/MyProjects/Ownsemble/.local/v2-tools/video-gpg
mkdir -p "$SRC"
cd "$SRC"
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
get() { [ -s "$2" ] || curl -sSfL "$1" -o "$2"; }
get https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz ffmpeg-9.1.tar.xz
get https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz.asc ffmpeg-9.1.tar.xz.asc
get https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz libass-0.17.5.tar.xz
get https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz.asc libass-0.17.5.tar.xz.asc
get https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz freetype-2.15.0.tar.xz
get https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz.sig freetype-2.15.0.tar.xz.sig
get https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz fribidi-1.0.18.tar.xz
get https://github.com/harfbuzz/harfbuzz/releases/download/15.2.0/harfbuzz-15.2.0.tar.xz harfbuzz-15.2.0.tar.xz
get "https://code.videolan.org/videolan/x264/-/archive/$X264_COMMIT/x264-$X264_COMMIT.tar.bz2" "x264-$X264_COMMIT.tar.bz2"
for sig in ffmpeg-9.1.tar.xz.asc libass-0.17.5.tar.xz.asc freetype-2.15.0.tar.xz.sig; do
  echo "== $sig"
  GNUPGHOME="$GPGDIR" gpg --batch --keyserver hkps://keyserver.ubuntu.com --auto-key-retrieve \
    --verify "$sig" "${sig%.*}" 2>&1 | grep -E "Good signature|BAD|Can't check|fingerprint" || true
done
sha256sum *.tar.* | grep -v '\.asc$\|\.sig$' > SOURCES.sha256
cat SOURCES.sha256
ls -la
