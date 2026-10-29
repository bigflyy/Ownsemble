import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/bootstrap/browser_factory.dart';
import 'package:ownsemble/contracts/music_browser.dart';
import 'package:ownsemble/platform/linux/linux_music_browser.dart';
import 'package:ownsemble/platform/windows/windows_music_browser.dart';

void main() {
  test('Linux gets a distinct engine session and the packaged helper path', () {
    final factory = createBrowserFactory(
      profilePath: '/generated/private-webview',
      operatingSystem: 'linux',
    );
    expect(factory, isA<LinuxMusicBrowserFactory>());
    final linux = factory as LinuxMusicBrowserFactory;
    expect(linux.profilePath, '/generated/private-webview-linux-cef');
    expect(
      linux.executablePath,
      endsWith('/lib/ownsemble_browser/ownsemble_browser'),
    );
  });
  test('Windows keeps its existing session and native adapter', () {
    final factory = createBrowserFactory(
      profilePath: 'generated-existing-windows-session',
      operatingSystem: 'windows',
    );
    expect(factory, isA<WindowsMusicBrowserFactory>());
    expect(
      (factory as WindowsMusicBrowserFactory).profilePath,
      'generated-existing-windows-session',
    );
  });
  test('unimplemented platforms keep an explicit unsupported guard', () {
    final factory = createBrowserFactory(
      profilePath: '/generated/unused',
      operatingSystem: 'android',
    );
    expect(factory, isA<UnsupportedMusicBrowserFactory>());
    expect(factory.capabilities, isEmpty);
  });
}
