import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/storage/stored_check.dart';
import 'package:ownsemble/vk/vk_client.dart' show VkException;

Track song(int id) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Операция Пластилин',
  title: 'Ты и Я',
  durationSec: 219,
  sourceKey: '1_$id',
);

void main() {
  group('judgeStored', () {
    test('the size of the own file: the same file', () {
      expect(judgeStored(saved: 100, own: 100), StoredVerdict.same);
    });

    test('another size than the own file: wrong, whatever the release', () {
      expect(judgeStored(saved: 100, own: 101), StoredVerdict.wrong);
      expect(
        judgeStored(saved: 100, own: 101, release: 300),
        StoredVerdict.wrong,
      );
    });

    test('own file unknown, the size of the release: saved by the old '
        'switch, wrong', () {
      expect(judgeStored(saved: 300, release: 300), StoredVerdict.wrong);
    });

    test('own file unknown, release another size or unknown: unverified', () {
      expect(judgeStored(saved: 100, release: 300), StoredVerdict.unverified);
      expect(judgeStored(saved: 100), StoredVerdict.unverified);
    });
  });

  group('StoredCheck', () {
    final links = <int, CopyLinks?>{};
    final sizes = <String, int?>{};
    final saved = <int, int?>{};
    final busy = <int>{};
    late List<int> removed;
    late List<int> redownloaded;
    late List<String> lines;
    Object? linksError;

    Uri own(int id) => Uri.parse('https://a.invalid/own$id.mp3');
    Uri release(int id) => Uri.parse('https://a.invalid/release$id.mp3');

    setUp(() {
      links.clear();
      sizes.clear();
      saved.clear();
      busy.clear();
      removed = [];
      redownloaded = [];
      lines = [];
      linksError = null;
    });

    StoredCheck check(List<({Track track, bool pinned})> songs) => StoredCheck(
      songs: songs,
      savedBytes: (track) => saved[track.id],
      linksOf: (track) async {
        if (linksError != null) throw linksError!;
        return links[track.id];
      },
      sizeOf: (link) async => sizes['$link'],
      remove: (track) => removed.add(track.id),
      redownload: (track) async {
        redownloaded.add(track.id);
        return null;
      },
      isBusy: (track) => busy.contains(track.id),
      log: lines.add,
      pause: Duration.zero,
    );

    void vkHas(int id, {int? ownSize, int? releaseSize}) {
      links[id] = (own: own(id), release: () async => release(id));
      sizes['${own(id)}'] = ownSize;
      sizes['${release(id)}'] = releaseSize;
    }

    test('removes the live file saved for a studio song, keeps the '
        'right one, and is done', () async {
      saved[1] = 5000; // the own file
      vkHas(1, ownSize: 5000, releaseSize: 7000);
      saved[2] = 7000; // the release, saved when the own file failed
      vkHas(2, releaseSize: 7000);
      final summary = await check([
        (track: song(1), pinned: false),
        (track: song(2), pinned: false),
      ]).run();
      expect(removed, [2]);
      expect(summary.same, 1);
      expect(summary.removed, 1);
      expect(summary.complete, isTrue);
      expect(lines, hasLength(2));
      expect(lines[0], contains('song 1 same'));
      expect(lines[1], contains('song 2 REMOVED'));
      expect(lines.join(), isNot(contains('invalid')), reason: 'no links');
    });

    test('a downloaded song with a wrong file is downloaded again from its '
        'own file', () async {
      saved[1] = 7000;
      vkHas(1, ownSize: 5000);
      await check([(track: song(1), pinned: true)]).run();
      expect(removed, [1]);
      expect(redownloaded, [1]);
      expect(lines.single, contains('downloaded again'));
    });

    test('a downloaded wrong file whose own file VK cannot send is removed, '
        'not downloaded again', () async {
      saved[1] = 7000;
      vkHas(1, releaseSize: 7000);
      await check([(track: song(1), pinned: true)]).run();
      expect(removed, [1]);
      expect(redownloaded, isEmpty);
      expect(lines.single, contains('own file not available'));
    });

    test('nothing to compare with: the file stays', () async {
      saved[1] = 5000;
      vkHas(1, releaseSize: 7000);
      saved[2] = 5000;
      links[2] = null; // no logged-in account has it
      final summary = await check([
        (track: song(1), pinned: false),
        (track: song(2), pinned: false),
      ]).run();
      expect(removed, isEmpty);
      expect(summary.unverified, 2);
      expect(summary.complete, isTrue);
    });

    test(
      'a playing song and a failed line are left for the next start',
      () async {
        saved[1] = 7000;
        vkHas(1, ownSize: 5000);
        busy.add(1);
        var summary = await check([(track: song(1), pinned: false)]).run();
        expect(removed, isEmpty);
        expect(summary.complete, isFalse);

        busy.clear();
        linksError = VkException('VK server error 502', transient: true);
        summary = await check([(track: song(1), pinned: false)]).run();
        expect(removed, isEmpty);
        expect(summary.notReached, 1);
        expect(summary.complete, isFalse);

        linksError = TimeoutException('no answer');
        summary = await check([(track: song(1), pinned: false)]).run();
        expect(summary.complete, isFalse);
      },
    );

    test('a refusal from VK leaves the file, unverified', () async {
      saved[1] = 7000;
      linksError = VkException('login expired');
      final summary = await check([(track: song(1), pinned: false)]).run();
      expect(removed, isEmpty);
      expect(summary.unverified, 1);
      expect(summary.complete, isTrue);
    });

    test('a saved file that is gone is skipped', () async {
      vkHas(1, ownSize: 5000);
      final summary = await check([(track: song(1), pinned: false)]).run();
      expect(summary.checked, 0);
      expect(removed, isEmpty);
    });
  });

  group('remoteAudioSize', () {
    late HttpServer server;
    final http = HttpClient();
    final asked = <String?>[];

    setUp(() async {
      asked.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        asked.add(request.headers.value(HttpHeaders.rangeHeader));
        final response = request.response;
        switch (request.uri.path) {
          case '/song.mp3':
            response
              ..statusCode = HttpStatus.partialContent
              ..headers.contentType = ContentType('audio', 'mpeg')
              ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/8574662')
              ..contentLength = 1
              ..add([0]);
          case '/whole.mp3':
            response
              ..headers.contentType = ContentType('audio', 'mpeg')
              ..contentLength = 3000
              ..add(List.filled(3000, 1));
          case '/error.mp3':
            response
              ..statusCode = HttpStatus.gatewayTimeout
              ..headers.contentType = ContentType.html
              ..write('<html>504</html>');
        }
        await response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('reads the whole size from one byte', () async {
      expect(await remoteAudioSize(at('/song.mp3'), http), 8574662);
      expect(asked.single, 'bytes=0-0');
    });

    test('a server that sends the whole file gives its length', () async {
      expect(await remoteAudioSize(at('/whole.mp3'), http), 3000);
    });

    test('an error page has no size', () async {
      expect(await remoteAudioSize(at('/error.mp3'), http), isNull);
    });

    test('a playlist link is not asked at all', () async {
      expect(await remoteAudioSize(at('/x/index.m3u8'), http), isNull);
      expect(asked, isEmpty);
    });
  });
}
