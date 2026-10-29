import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/music_navigation.dart';

void main() {
  test('only approved music routes permit extraction', () {
    for (final path in ['/audios', '/audios123', '/audio', '/music/library']) {
      expect(
        classifyMusicRoute(Uri.parse('https://vk.ru$path')),
        MusicRoute.music,
      );
    }
    for (final url in [
      'https://id.vk.com/auth',
      'https://vk.ru/login',
      'https://vk.ru/audios_bad',
      'https://vk.ru.bad.test/music',
      'https://user:synthetic@vk.ru/music',
      'https://vk.ru:8443/music',
      'http://vk.ru/music',
    ]) {
      expect(classifyMusicRoute(Uri.parse(url)), MusicRoute.other);
    }
  });

  test(
    'live route refresh recovers a missed SPA history notification',
    () async {
      final navigation = MusicNavigation();
      navigation.observe(Uri.parse('https://vk.ru/feed'));
      expect(
        await navigation.refresh(
          readUrl: () async => Uri.parse('https://vk.ru/audios123'),
          openMusic: () async => fail('music is already open'),
        ),
        isTrue,
      );
      navigation.observe(Uri.parse('https://vk.ru/login'));
      expect(navigation.isMusic, isFalse);
    },
  );

  test('feed redirects once, and sign-in routes stay private', () async {
    final navigation = MusicNavigation();
    var current = Uri.parse('https://vk.ru/login');
    var attempts = 0;
    Future<bool> refresh() => navigation.refresh(
      readUrl: () async => current,
      openMusic: () async {
        attempts++;
      },
    );
    expect(await refresh(), isFalse);
    expect(attempts, 0);
    current = Uri.parse('https://vk.ru/feed');
    expect(await refresh(), isFalse);
    expect(await refresh(), isFalse);
    expect(attempts, 1);
    current = Uri.parse('https://vk.ru/audios');
    expect(await refresh(), isTrue);
    current = Uri.parse('https://vk.ru/feed');
    await refresh();
    expect(attempts, 2);
  });

  test(
    'feed recovery refreshes route after navigation before extraction',
    () async {
      final navigation = MusicNavigation();
      var current = Uri.parse('https://vk.com/feed');
      expect(
        await navigation.refresh(
          readUrl: () async => current,
          openMusic: () async {
            current = Uri.parse('https://vk.ru/audios');
          },
        ),
        isTrue,
      );
      expect(navigation.isMusic, isTrue);
    },
  );
  test(
    'a transient blank document never authorizes extraction or hides login',
    () {
      final navigation = MusicNavigation();
      navigation.observe(Uri.parse('about:blank'));
      expect(navigation.isBlankDocument, isTrue);
      expect(navigation.isMusic, isFalse);
      navigation.observe(Uri.parse('https://vk.ru/login'));
      expect(navigation.isBlankDocument, isFalse);
      expect(navigation.isMusic, isFalse);
      navigation.observe(Uri.parse('https://vk.ru/music'));
      expect(navigation.isBlankDocument, isFalse);
      expect(navigation.isMusic, isTrue);
    },
  );
}
