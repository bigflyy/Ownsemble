import 'dart:io';

import '../contracts/music_browser.dart';
import '../platform/linux/linux_music_browser.dart';
import '../platform/windows/windows_music_browser.dart';

/// OS choice stays at composition; browser engines never share a session folder.
MusicBrowserFactory createBrowserFactory({
  required String profilePath,
  String? operatingSystem,
  bool hidden = true,
}) => switch (operatingSystem ?? Platform.operatingSystem) {
  'windows' => WindowsMusicBrowserFactory(profilePath, hidden: hidden),
  'linux' => LinuxMusicBrowserFactory('$profilePath-linux-cef'),
  _ => const UnsupportedMusicBrowserFactory(),
};
