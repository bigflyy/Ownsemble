/// The video maker the karaoke export runs (plan 11 B1-B3): a trimmed,
/// statically linked ffmpeg.exe from Ownsemble's public release
/// video-tools-1, downloaded on the first export the user agrees to, with
/// its size and SHA-256 written here, in the app, never taken from the
/// server.
library;

import '../lyrics/fit_model.dart';
import '../lyrics/model_bundle.dart';

/// Ownsemble's release that holds ffmpeg.exe, its licences and its source.
const videoToolsReleasePage =
    'https://github.com/bigflyy/Ownsemble/releases/tag/video-tools-1';

const _videoToolsBase =
    'https://github.com/bigflyy/Ownsemble/releases/download/video-tools-1/';

/// The name of the exe inside the bundle folder.
const ffmpegFileName = 'ffmpeg.exe';

/// ffmpeg.exe and the full licence texts of what is linked into it. The
/// release's NOTICES.txt is kept as ffmpeg-NOTICES.txt, since the bundle
/// writes its own NOTICES.txt.
final videoToolsBundle = ModelBundle(
  name: 'video-tools',
  version: 1,
  files: [
    ModelFile(
      url: Uri.parse('${_videoToolsBase}ffmpeg.exe'),
      bytes: 9703936,
      sha256:
          '250aae36074993a1b164831030a1405f7612f5e4c99d3d41dc3e4e4a973707c5',
      fileName: ffmpegFileName,
    ),
    ModelFile(
      url: Uri.parse('${_videoToolsBase}NOTICES.txt'),
      bytes: 164378,
      sha256:
          '1ec0f5958921a70f3be3b33a5de0384b94686fdc6dc250e3f82adda087f62db5',
      fileName: 'ffmpeg-NOTICES.txt',
    ),
  ],
  notices: videoToolsNotice,
);

/// What the app says about the video maker (also in its licence notices,
/// plan 11 D4).
const videoToolsNotice =
    '''
Ownsemble karaoke video export: the video maker

ffmpeg.exe is a trimmed, statically linked build of FFmpeg 9.1 with x264
(H.264 video), libass 0.17.5 (the karaoke lines), FreeType 2.15.0, GNU
FriBidi 1.0.18, HarfBuzz 15.2.0 and zlib 1.4. Because it includes x264, the
program as a whole is licensed under the GNU General Public License,
version 2 or later. Ownsemble runs it as a separate program.

The full licence text of every part is in ffmpeg-NOTICES.txt beside it.
The complete corresponding source, the build scripts and the build options
are in ffmpeg-video-tools-1-sources.tar at
$videoToolsReleasePage
Portions of this software are copyright (C) 2026 The FreeType Project
(www.freetype.org). All rights reserved.

H.264 is covered by patents in some countries; this build is for personal,
non-commercial use.
''';
