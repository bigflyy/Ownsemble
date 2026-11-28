#!/bin/bash
# Build the trimmed static ffmpeg.exe for Ownsemble's karaoke export (plan 11
# B1). Runs inside the separate MSYS2 (UCRT64) through msys.ps1, under agg-queue.
# Sources: ../video-src (fetch.sh). Output: out/ffmpeg.exe, out/BUILD-INFO.txt.
# Only the parts the export command needs (plan 11 B0) plus libx264 and libass
# (DirectWrite fonts) with freetype, fribidi and harfbuzz, all static.
set -euo pipefail
HERE=/c/MyProjects/Ownsemble/.local/v2-tools/video-build
SRC=/c/MyProjects/Ownsemble/.local/v2-tools/video-src
WORK=$HERE/work
PREFIX=$HERE/prefix
OUT=$HERE/out
JOBS=${JOBS:-8}
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
STEP=${1:-all}

export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG="pkgconf --static"
export CFLAGS="-O2"
export CXXFLAGS="-O2"
export LDFLAGS="-static -static-libgcc"
mkdir -p "$WORK" "$PREFIX" "$OUT"

fresh() { # extract $1 (tarball) into $WORK, replacing an earlier tree
  local dir=$2
  rm -rf "${WORK:?}/$dir"
  tar -xf "$SRC/$1" -C "$WORK"
}

meson_static() { # $1 = source dir, rest = meson options
  local dir=$1
  shift
  meson setup "$WORK/$dir/_build" "$WORK/$dir" --prefix="$PREFIX" --libdir=lib \
    --buildtype=release --default-library=static --wrap-mode=nodownload "$@"
  ninja -C "$WORK/$dir/_build" -j "$JOBS"
  ninja -C "$WORK/$dir/_build" install
}

step() { [ "$STEP" = all ] || [ "$STEP" = "$1" ]; }

if step freetype; then
  echo "=== freetype"
  fresh freetype-2.15.0.tar.xz freetype-2.15.0
  meson_static freetype-2.15.0 -Dzlib=disabled -Dpng=disabled -Dbzip2=disabled \
    -Dbrotli=disabled -Dharfbuzz=disabled -Dtests=disabled
fi

if step fribidi; then
  echo "=== fribidi"
  fresh fribidi-1.0.18.tar.xz fribidi-1.0.18
  meson_static fribidi-1.0.18 -Ddocs=false -Dbin=false -Dtests=false
fi

if step harfbuzz; then
  echo "=== harfbuzz"
  fresh harfbuzz-15.2.0.tar.xz harfbuzz-15.2.0
  meson_static harfbuzz-15.2.0 -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dpng=disabled -Dzlib=disabled -Dicu=disabled \
    -Dgraphite=disabled -Dgraphite2=disabled -Dfontations=disabled -Dgdi=disabled \
    -Ddirectwrite=disabled -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled \
    -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
    -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dbenchmark=disabled
fi

if step libass; then
  echo "=== libass"
  fresh libass-0.17.5.tar.xz libass-0.17.5
  meson_static libass-0.17.5 -Dfontconfig=disabled -Ddirectwrite=enabled \
    -Dcoretext=disabled -Dlibunibreak=disabled -Dasm=enabled -Dtest=disabled \
    -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
fi

if step x264; then
  echo "=== x264"
  fresh "x264-$X264_COMMIT.tar.bz2" "x264-$X264_COMMIT"
  cd "$WORK/x264-$X264_COMMIT"
  ./configure --prefix="$PREFIX" --enable-static --disable-cli --bit-depth=8 \
    --chroma-format=420 --disable-opencl --disable-avs --disable-swscale \
    --disable-lavf --disable-ffms --disable-gpac --disable-lsmash
  make -j "$JOBS"
  make install
fi

if step ffmpeg; then
  echo "=== ffmpeg"
  fresh ffmpeg-9.1.tar.xz ffmpeg-9.1
  cd "$WORK/ffmpeg-9.1"
  CONFIGURE=(
    --prefix="$PREFIX" --pkg-config=pkgconf --pkg-config-flags=--static
    --enable-static --disable-shared --enable-gpl
    --disable-autodetect --disable-everything --disable-doc --disable-network
    --disable-debug --disable-ffplay --disable-ffprobe --disable-avdevice
    --enable-w32threads --enable-zlib --enable-libx264 --enable-libass
    --enable-protocol=file,pipe
    --enable-demuxer=pcm_f32le,image2
    --enable-decoder=pcm_f32le,png
    --enable-encoder=libx264,aac
    --enable-muxer=mp4
    --enable-filter=ass,format,scale,aresample,anull,trim,atrim
    --extra-cflags="-I$PREFIX/include"
    --extra-ldflags="-L$PREFIX/lib -static -static-libgcc -static-libstdc++"
  )
  ./configure "${CONFIGURE[@]}" || { tail -40 ffbuild/config.log; exit 1; }
  make -j "$JOBS"
  cp ffmpeg.exe "$OUT/ffmpeg.exe"
  strip "$OUT/ffmpeg.exe"
  {
    echo "Built $(date -u +%Y-%m-%dT%H:%MZ) in MSYS2 UCRT64, $(gcc --version | head -1)"
    echo "ffmpeg 9.1 configure: ${CONFIGURE[*]}"
    echo "x264 commit $X264_COMMIT: --enable-static --disable-cli --bit-depth=8 --chroma-format=420 --disable-opencl --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash"
    echo "libass 0.17.5, freetype 2.15.0, fribidi 1.0.18, harfbuzz 15.2.0: meson static, options in build.sh"
    echo "zlib: MSYS2 package $(pacman -Q mingw-w64-ucrt-x86_64-zlib)"
    echo "Sources: SOURCES.sha256"
    cat "$SRC/SOURCES.sha256"
    echo "Size: $(stat -c %s "$OUT/ffmpeg.exe") bytes"
    echo "sha256: $(sha256sum "$OUT/ffmpeg.exe" | cut -d' ' -f1)"
    echo "DLL imports:"
    objdump -p "$OUT/ffmpeg.exe" | grep "DLL Name"
  } > "$OUT/BUILD-INFO.txt"
  cat "$OUT/BUILD-INFO.txt"
fi
echo "=== done $STEP"
