Ownsemble video-tools-1: complete corresponding source of ffmpeg.exe
====================================================================

ffmpeg.exe in the Ownsemble release "video-tools-1" is a trimmed, statically linked
build of FFmpeg with libx264 and libass. Because of libx264 the binary as a whole is
licensed under the GNU General Public License, version 2 or later. This archive holds
everything needed to rebuild it:

  sources/   the unmodified upstream source archives, their signatures where the
             projects publish them, and SOURCES.sha256
             - ffmpeg-9.1.tar.xz            (ffmpeg.org, GPG-signed)
             - x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2
                                            (code.videolan.org, exact git commit; x264
                                             publishes no release tarballs)
             - libass-0.17.5.tar.xz         (GitHub release, GPG-signed)
             - freetype-2.15.0.tar.xz       (savannah, GPG-signed)
             - fribidi-1.0.18.tar.xz        (GitHub release)
             - harfbuzz-15.2.0.tar.xz       (GitHub release)
             - mingw-w64-zlib-1.4-2.src.tar.zst
                                            (MSYS2's source package for the zlib that
                                             was linked: zlib 1.4 plus MSYS2's patches
                                             and PKGBUILD; signed by MSYS2)
  build/     the scripts that ran and the build record
             - fetch.sh     downloads the sources above and checks the signatures
             - pkgs.sh      installs the MSYS2 build tools (gcc, nasm, meson, ...)
             - msys.ps1     runs one command inside the separate MSYS2 with a clean PATH
             - build.sh     builds freetype, fribidi, harfbuzz, libass, x264, then ffmpeg,
                            all static; every configure and meson option is in it
             - BUILD-INFO.txt  date, compiler, the exact ffmpeg configure line, the
                            sha256 of the resulting ffmpeg.exe and its DLL imports
  NOTICES.txt  the licences of every part inside ffmpeg.exe

No source file was patched. The only changes from the upstream defaults are the build
options in build.sh.

How to rebuild
--------------
1. Unpack an MSYS2 base archive (msys2-base-x86_64-20261120 was used) into a folder of
   its own and start its UCRT64 shell.
2. bash pkgs.sh install   (gcc 16.2.0 Rev7 and the other tools from MSYS2's UCRT64
   repository; zlib is mingw-w64-ucrt-x86_64-zlib 1.4-2, or build it from
   sources/mingw-w64-zlib-1.4-2.src.tar.zst with makepkg-mingw).
3. Put the archives from sources/ into one folder, and edit the HERE and SRC lines at
   the top of build.sh (the paths of the build folder and of that source folder).
4. bash build.sh   ->  out/ffmpeg.exe and out/BUILD-INFO.txt

The resulting exe only imports Windows' own DLLs (KERNEL32, USER32, GDI32, SHELL32,
bcrypt and the Universal C Runtime api-ms-win-crt-*). A rebuild with the same compiler
gives the same features; it is not promised to be byte-identical.

These sources stay available in the same release as long as ffmpeg.exe can be
downloaded from it. Project: https://github.com/bigflyy/Ownsemble
