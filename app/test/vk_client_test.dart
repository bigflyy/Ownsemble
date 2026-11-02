import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_client.dart';

/// [VkClient] answering `audio.getById` from a map of song ids to audio.
class FakeVkAudio extends VkClient {
  FakeVkAudio(this.songs) : super(const []);

  final Map<String, Map<String, dynamic>> songs;

  @override
  Future<Object?> call(String method, Map<String, String> params) async {
    expect(method, 'audio.getById');
    return [?songs[params['audios']]];
  }
}

/// [VkClient] answering `audio.getById` with [links], one per request; the
/// last one repeats.
class ScriptedVkLinks extends VkClient {
  ScriptedVkLinks(this.links) : super(const []);

  final List<String> links;
  int asked = 0;

  @override
  Future<Object?> call(String method, Map<String, String> params) async {
    final link = links[asked < links.length ? asked : links.length - 1];
    asked++;
    return [
      {'url': link},
    ];
  }
}

void main() {
  group('resolveStream', () {
    const copy = '660306161_456239124';
    const release = '-2001514945_75514945';
    Map<String, dynamic> audio(
      String url, {
      int? trackId = 20587574,
      String? releaseId = release,
      int? restricted,
    }) => {
      'url': url,
      'track_id': ?trackId,
      'release_audio_id': ?releaseId,
      'content_restricted': ?restricted,
    };

    test('gives the link, the recording and its official release', () async {
      final vk = FakeVkAudio({'${copy}_key': audio('https://a.invalid/1.mp3')});
      final stream = await vk.resolveStream(copy, 'key');
      expect(stream.link, Uri.parse('https://a.invalid/1.mp3'));
      expect(stream.restricted, isFalse);
      expect(stream.trackId, 20587574);
      expect(stream.releaseKey, release);
    });

    group('an HLS playlist link instead of the MP3', () {
      const playlist = 'https://a.invalid/x/index.m3u8?extra=secret';
      const song = 'https://a.invalid/x/song.mp3?extra=secret';

      test('a new link is asked for and it brings the MP3', () async {
        final vk = ScriptedVkLinks([playlist, song]);
        final stream = await vk.resolveStream(copy, 'key');
        expect(stream.link, Uri.parse(song));
        expect(stream.playlistLinks, 1);
        expect(vk.asked, 2);
      });

      test('a link to the MP3 is taken at once', () async {
        final vk = ScriptedVkLinks([song]);
        final stream = await vk.resolveStream(copy, 'key');
        expect(stream.playlistLinks, 0);
        expect(vk.asked, 1);
      });

      test('only the path decides, not the query', () async {
        final vk = ScriptedVkLinks(['https://a.invalid/song.mp3?x=index.m3u8']);
        expect((await vk.resolveStream(copy, 'key')).playlistLinks, 0);
      });

      test('it gives up after a few and hands over what VK gave', () async {
        final vk = ScriptedVkLinks([playlist]);
        final stream = await vk.resolveStream(copy, 'key');
        expect(stream.link, Uri.parse(playlist));
        expect(stream.playlistLinks, 4);
        expect(vk.asked, 4);
      });
    });

    test('a song VK withdrew has no link and is marked restricted', () async {
      final vk = FakeVkAudio({copy: audio('', restricted: 1)});
      final stream = await vk.resolveStream(copy, null);
      expect(stream.link, isNull);
      expect(stream.restricted, isTrue);
    });

    test('other restriction codes are not read as withdrawn', () async {
      final vk = FakeVkAudio({copy: audio('', restricted: 2)});
      expect((await vk.resolveStream(copy, null)).restricted, isFalse);
    });

    test('a song VK does not know has no link', () async {
      final stream = await FakeVkAudio({}).resolveStream(copy, null);
      expect(stream.link, isNull);
      expect(stream.restricted, isFalse);
    });

    test('the release link comes from the official release', () async {
      final vk = FakeVkAudio({
        copy: audio('https://a.invalid/broken.mp3'),
        release: audio('https://b.invalid/good.mp3'),
      });
      final stream = await vk.resolveStream(copy, null);
      expect(
        await vk.releaseLink(stream),
        Uri.parse('https://b.invalid/good.mp3'),
      );
    });

    test('another recording is never used as the release link', () async {
      final vk = FakeVkAudio({
        copy: audio('https://a.invalid/broken.mp3'),
        release: audio('https://b.invalid/other.mp3', trackId: 1),
      });
      final stream = await vk.resolveStream(copy, null);
      expect(await vk.releaseLink(stream), isNull);
    });

    test('no release link without a release or a known recording', () async {
      final vk = FakeVkAudio({
        'a': audio('https://a.invalid/1.mp3', releaseId: null),
        'b': audio('https://a.invalid/2.mp3', trackId: null),
        release: audio('https://b.invalid/good.mp3', trackId: null),
      });
      expect(await vk.releaseLink(await vk.resolveStream('a', null)), isNull);
      expect(await vk.releaseLink(await vk.resolveStream('b', null)), isNull);
    });
  });

  group('postVkForm', () {
    late HttpServer server;
    final http = HttpClient();
    final reply = utf8.encode(jsonEncode({'response': 'Привет, ёлка'}));

    setUp(() async {
      // Stand-in for VK: /trickle sends the reply in 8 parts 100 ms apart,
      // /stall sends half and then nothing, /error answers 504 with HTML.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        // Unbuffered, so each flush really reaches the client at once.
        final response = request.response..bufferOutput = false;
        switch (request.uri.path) {
          case '/trickle':
            final part = (reply.length / 8).ceil();
            for (var start = 0; start < reply.length; start += part) {
              final end = start + part < reply.length
                  ? start + part
                  : reply.length;
              response.add(reply.sublist(start, end));
              await response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            await response.close();
          case '/stall':
            response.add(reply.sublist(0, reply.length ~/ 2));
            await response.flush();
            await Future<void>.delayed(const Duration(seconds: 2));
            await response.close().catchError((_) {});
          case '/error':
            response
              ..statusCode = 504
              ..write('<html>504 Gateway Time-out</html>');
            await response.close();
        }
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test(
      'a slow but steady reply may take longer than the silence limit',
      () async {
        final clock = Stopwatch()..start();
        final decoded = await postVkForm(
          http,
          at('/trickle'),
          form: {'q': 'кино'},
          cookieHeader: '',
          silence: const Duration(milliseconds: 400),
          total: const Duration(seconds: 5),
        );
        expect(clock.elapsedMilliseconds, greaterThan(400));
        expect(decoded['response'], 'Привет, ёлка');
      },
    );

    test('a reply that goes silent fails as a transient error', () async {
      final failure = await postVkForm(
        http,
        at('/stall'),
        form: const {},
        cookieHeader: '',
        silence: const Duration(milliseconds: 300),
        total: const Duration(seconds: 5),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(failure, isA<VkException>());
      expect(isTransientVkError(failure!), isTrue);
    });

    test('the total limit still ends a reply that never finishes', () async {
      final failure = await postVkForm(
        http,
        at('/trickle'),
        form: const {},
        cookieHeader: '',
        silence: const Duration(seconds: 1),
        total: const Duration(milliseconds: 250),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(failure, isA<VkException>());
      expect(isTransientVkError(failure!), isTrue);
    });

    test('a VK server error page is transient, not a JSON error', () async {
      final failure = await postVkForm(
        http,
        at('/error'),
        form: const {},
        cookieHeader: '',
        silence: const Duration(seconds: 1),
        total: const Duration(seconds: 5),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(failure, isA<VkException>());
      expect((failure! as VkException).message, contains('504'));
      expect(isTransientVkError(failure), isTrue);
    });
  });

  group('retryTransient', () {
    test(
      'sends again after transient failures and returns the answer',
      () async {
        var tries = 0;
        final answer = await retryTransient(() async {
          tries++;
          if (tries == 1) throw const SocketException('connection timed out');
          if (tries == 2) throw VkException('VK went silent', transient: true);
          return 'ok';
        }, firstDelay: Duration.zero);
        expect(answer, 'ok');
        expect(tries, 3);
      },
    );

    test('gives up after the last attempt with the last error', () async {
      var tries = 0;
      await expectLater(
        retryTransient(
          () async {
            tries++;
            throw const SocketException('down');
          },
          attempts: 3,
          firstDelay: Duration.zero,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(tries, 3);
    });

    test('does not repeat a refusal such as an expired login', () async {
      var tries = 0;
      await expectLater(
        retryTransient(() async {
          tries++;
          throw VkException('web_token refused: type=error');
        }, firstDelay: Duration.zero),
        throwsA(isA<VkException>()),
      );
      expect(tries, 1);
    });
  });
}
