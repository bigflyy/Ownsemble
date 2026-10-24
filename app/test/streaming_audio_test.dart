import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/media/streaming_audio.dart';
import 'package:ownsemble/media/hls_mp3.dart';

void main() {
  test('an incomplete MP3 exposes a growing body without inviting a blocking EOF metadata probe', () async {
    // Hold the final bytes while enough of the generated source is available to stream.
    final tail = Completer<void>();
    // Keep all network access on a generated local fixture server.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 8;
      request.response.add([1, 2, 3, 4]);
      await request.response.flush();
      await tail.future;
      request.response.add([5, 6, 7, 8]);
      await request.response.close();
    });
    // Exercise the real relay without native audio or any persistent catalog.
    final stream = StreamingAudio(
      AudioCache(
        Directory.systemTemp,
        (_) async => 1,
        fixturePort: server.port,
      ),
      Uri.parse('http://127.0.0.1:${server.port}/audio.mp3'),
    );
    // Keep host proxy settings from changing the generated loopback request.
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      // Model FFmpeg's initial open-ended range probe, not a user seek.
      final request = await client.getUrl(await stream.open());
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      // Require correct growing-response framing instead of a misleading complete length.
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.contentLength, -1);
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      // Confirm bytes remain unchanged and the final response still ends normally.
      tail.complete();
      expect(await response.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
    } finally {
      // Release the held server callback after either the expected failure or success.
      if (!tail.isCompleted) tail.complete();
      client.close(force: true);
      await stream.close(cancel: true);
      await server.close(force: true);
    }
  });

  test(
    'source preparation warms only two segments and shares their requests',
    () async {
      final audio = Uint8List.fromList([
        255,
        251,
        144,
        0,
        ...List.filled(413, 1),
      ]);
      final counts = <String, int>{};
      final network = AudioCache(
        Directory.systemTemp,
        (_) async => 3,
        resourceLoader: (uri, {required userAgent, required limit}) async {
          counts.update(uri.path, (n) => n + 1, ifAbsent: () => 1);
          if (uri.path.endsWith('.m3u8')) {
            return Uint8List.fromList(
              utf8.encode('''#EXTM3U
#EXT-X-TARGETDURATION:1
#EXTINF:1,
one.ts
#EXTINF:1,
two.ts
#EXTINF:1,
three.ts
#EXT-X-ENDLIST
'''),
            );
          }
          if (uri.path == '/three.ts') {
            throw StateError('Preparation exceeded its bound');
          }
          return audio;
        },
      );
      final stream = StreamingAudio(
        network,
        Uri.parse('https://test.vkuseraudio.net/audio.m3u8'),
      );
      try {
        await Future.wait([stream.prepare(), stream.prepare()]);
        expect(stream.prepared, isTrue);
        expect(counts, {'/audio.m3u8': 1, '/one.ts': 1, '/two.ts': 1});
        expect(network.networkRequests, 0);
      } finally {
        await stream.close(cancel: true);
      }
    },
  );
  test('streaming removes AES keys and preserves MP3 frames across implicit IV and rotation', () async {
    final aes = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
    final audio = Uint8List.fromList([
      255,
      251,
      144,
      0,
      ...List.filled(413, 1),
    ]);
    final encrypted = <String, List<int>>{};
    for (final item in [('one', 7, 9), ('two', 8, 10)]) {
      encrypted['/${item.$1}.ts'] = (await aes.encrypt(
        audio,
        secretKey: SecretKey(List.filled(16, item.$2)),
        nonce: [...List.filled(15, 0), item.$3],
      )).cipherText;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final counts = <String, int>{};
    server.listen((request) async {
      final path = request.uri.path;
      counts.update(path, (n) => n + 1, ifAbsent: () => 1);
      if (path == '/audio.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:9\n#EXT-X-KEY:METHOD=AES-128,URI="one.key"\n#EXTINF:1,\none.ts\n#EXT-X-KEY:METHOD=AES-128,URI="two.key",IV=0x0a\n#EXTINF:1,\ntwo.ts\n#EXT-X-ENDLIST\n',
        );
      } else if (path.endsWith('.key')) {
        request.response.add(List.filled(16, path == '/one.key' ? 7 : 8));
      } else {
        request.response.add(encrypted[path]!);
      }
      await request.response.close();
    });
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-stream-iv-',
    );
    final network = AudioCache(
      folder,
      (_) async => 1,
      fixturePort: server.port,
    );
    final stream = StreamingAudio(
      network,
      Uri.parse('http://127.0.0.1:${server.port}/audio.m3u8'),
    );
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final local = await stream.open();
      final manifest = await utf8.decoder
          .bind(await (await client.getUrl(local)).close())
          .join();
      expect(manifest, isNot(contains('EXT-X-KEY')));
      var index = 0;
      for (final path
          in manifest.split('\n').where((line) => line.startsWith('/'))) {
        final response = await (await client.getUrl(local.resolve(path)))
            .close();
        final packet = Uint8List.fromList(
          await response.expand((v) => v).toList(),
        );
        expect(normalizeMp3Segment(packet), audio);
        expect(String.fromCharCodes(packet.take(3)), 'ID3');
        final clockOffset =
            20 + 'com.apple.streaming.transportStreamTimestamp'.length + 1;
        expect(
          ByteData.sublistView(packet).getUint64(clockOffset),
          index++ * 90000,
        );
      }
      expect(counts.values, everyElement(1));
    } finally {
      client.close(force: true);
      await stream.close(cancel: true);
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  });
  test(
    'packed audio clocks wrap at 33 bits without changing encoded frames',
    () {
      final audio = Uint8List.fromList([
        255,
        251,
        144,
        0,
        ...List.filled(413, 1),
      ]);
      final packet = packHlsMp3Segment(audio, 0x200000000 + 123);
      final clockOffset =
          20 + 'com.apple.streaming.transportStreamTimestamp'.length + 1;
      expect(ByteData.sublistView(packet).getUint64(clockOffset), 123);
      expect(normalizeMp3Segment(packet), audio);
      expect(() => packHlsMp3Segment(audio, -1), throwsA(isA<ProofFailure>()));
    },
  );
  test(
    'cancelling a shared stream never publishes a partial offline asset',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tail = Completer<void>();
      server.listen((request) async {
        try {
          request.response.bufferOutput = false;
          request.response.contentLength = 8;
          request.response.add([1, 2, 3, 4]);
          await request.response.flush();
          await tail.future;
          request.response.add([5, 6, 7, 8]);
          await request.response.close();
        } catch (_) {
          /* Expected cancellation. */
        }
      });
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-cancel-stream-',
      );
      final network = AudioCache(
        folder,
        (_) async => 30,
        fixturePort: server.port,
      );
      final source = Uri.parse('http://127.0.0.1:${server.port}/audio.mp3');
      final stream = StreamingAudio(network, source);
      final cache = AudioCache(
        folder,
        (_) async => 30,
        fixturePort: server.port,
        resourceLoader: stream.fetch,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final saved = cache.save(
          const Track('1_1', 'Generated', 'Fixture', 30),
          source,
        );
        final failure = expectLater(saved, throwsA(isA<ProofFailure>()));
        final response = await (await client.getUrl(await stream.open()))
            .close();
        final reader = StreamIterator(response);
        expect(await reader.moveNext(), isTrue);
        await stream.close(cancel: true);
        await failure;
        expect(await Directory('${folder.path}/1_1').exists(), isFalse);
        expect(await Directory('${folder.path}/1_1.partial').exists(), isFalse);
        await reader.cancel();
      } finally {
        if (!tail.isCompleted) tail.complete();
        client.close(force: true);
        await stream.close(cancel: true);
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'player receives audio before download finishes, with one upstream request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tail = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.bufferOutput = false;
        request.response.contentLength = 8;
        request.response.add([1, 2, 3, 4]);
        await request.response.flush();
        await tail.future;
        request.response.add([5, 6, 7, 8]);
        await request.response.close();
      });
      final temp = await Directory.systemTemp.createTemp('ownsemble-stream-');
      final network = AudioCache(
        temp,
        (_) async => 1,
        fixturePort: server.port,
      );
      final source = Uri.parse('http://127.0.0.1:${server.port}/audio.mp3');
      final session = StreamingAudio(network, source);
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        var complete = false;
        final cache = session.fetch(source).then((bytes) {
          complete = true;
          return bytes;
        });
        final response = await (await client.getUrl(await session.open()))
            .close();
        final reader = StreamIterator(response);
        expect(await reader.moveNext(), isTrue);
        expect(reader.current, [1, 2, 3, 4]);
        expect(complete, isFalse);
        tail.complete();
        final remaining = <int>[];
        while (await reader.moveNext()) {
          remaining.addAll(reader.current);
        }
        expect(remaining, [5, 6, 7, 8]);
        expect(await cache, [1, 2, 3, 4, 5, 6, 7, 8]);
        expect(requests, 1);
        final ranged = await client.getUrl(await session.open());
        ranged.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
        final slice = await ranged.close();
        expect(slice.statusCode, 206);
        expect(
          slice.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 2-5/8',
        );
        expect(await slice.expand((bytes) => bytes).toList(), [3, 4, 5, 6]);
        expect(requests, 1);
      } finally {
        if (!tail.isCompleted) tail.complete();
        client.close(force: true);
        await session.close(cancel: true);
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    },
  );

  test('HLS player and complete cache share resources; local URLs hide source queries', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final counts = <String, int>{};
    server.listen((request) async {
      counts.update(request.uri.path, (n) => n + 1, ifAbsent: () => 1);
      if (request.uri.path == '/audio.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts?temporary=synthetic\n#EXT-X-ENDLIST\n',
        );
      } else {
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('ownsemble-hls-stream-');
    final network = AudioCache(temp, (_) async => 1, fixturePort: server.port);
    final source = Uri.parse('http://127.0.0.1:${server.port}/audio.m3u8');
    final session = StreamingAudio(network, source);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final local = await session.open();
      final response = await (await client.getUrl(local)).close();
      final manifest = await utf8.decoder.bind(response).join();
      expect(manifest, contains('#EXT-X-ENDLIST'));
      expect(manifest, isNot(contains('temporary')));
      expect(manifest, isNot(contains('http')));
      final segment = manifest
          .split('\n')
          .firstWhere((line) => line.startsWith('/'));
      final streamed = await (await client.getUrl(local.resolve(segment)))
          .close();
      expect(await streamed.expand((v) => v).toList(), [1, 2, 3, 4]);
      expect(
        await session.fetch(source.resolve('segment.ts?temporary=synthetic')),
        [1, 2, 3, 4],
      );
      expect(counts, {'/audio.m3u8': 1, '/segment.ts': 1});
      final unknown = await (await client.getUrl(
        local.replace(path: '/unknown.mp3'),
      )).close();
      expect(unknown.statusCode, 404);
      await unknown.drain<void>();
      final badRange = await client.getUrl(local.resolve(segment));
      badRange.headers.set(HttpHeaders.rangeHeader, 'bytes=100-101');
      final rejected = await badRange.close();
      expect(rejected.statusCode, 416);
      await rejected.drain<void>();
    } finally {
      client.close(force: true);
      await session.close(cancel: true);
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });

  test('offline and non-approved destinations remain blocked', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ownsemble-block-stream-',
    );
    final network = AudioCache(temp, (_) async => 1)..offline = true;
    final session = StreamingAudio(
      network,
      Uri.parse('https://vkuseraudio.net/audio.mp3'),
    );
    try {
      await expectLater(
        session.fetch(session.source),
        throwsA(isA<ProofFailure>()),
      );
      network.offline = false;
      await expectLater(
        session.fetch(Uri.parse('https://example.com/audio.mp3')),
        throwsA(isA<ProofFailure>()),
      );
    } finally {
      await session.close();
      await temp.delete(recursive: true);
    }
  });
}
