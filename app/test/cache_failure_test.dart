import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test('empty source capture is unresolved, not a VK restriction', () {
    expect(
      () => selectSource({}),
      throwsA(
        isA<ProofFailure>().having(
          (error) => error.category,
          'category',
          'audio_source_not_resolved',
        ),
      ),
    );
  });

  test(
    'VK audio CDN authorities retain the strict audio destination boundary',
    () {
      expect(
        allowedAudio(
          Uri.parse('https://music.vkuseraudio.ru/audio/index.m3u8'),
        ),
        isTrue,
      );
      for (final url in [
        'https://vkuseraudio.ru.attacker.test/audio.mp3',
        'https://notvkuseraudio.ru/audio.mp3',
        'http://music.vkuseraudio.ru/audio.mp3',
        'https://user:secret@music.vkuseraudio.ru/audio.mp3',
        'https://music.vkuseraudio.ru:8443/audio.mp3',
      ]) {
        expect(allowedAudio(Uri.parse(url)), isFalse);
      }
    },
  );

  test(
    'download stages keep receipt separate from validation/publication',
    () async {
      final folder = await Directory.systemTemp.createTemp('ownsemble-stages-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final stages = <String>[];
      try {
        final cache = AudioCache(
          folder,
          (_) async {
            expect(stages.last, 'decoding');
            expect(await Directory('${folder.path}/1_1').exists(), isFalse);
            return 4;
          },
          fixturePort: server.port,
          onStage: stages.add,
        );
        final asset = await cache.save(
          const Track('1_1', 'Track', 'Artist', 4),
          Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
        );
        expect(stages, ['receiving', 'decoding', 'publishing']);
        expect(asset.bytes, 3);
      } finally {
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
  );
  test('Cancel aborts a silent active HTTP request without waiting for its timeout', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-http-cancel-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    server.listen((request) {
      if (!arrived.isCompleted) arrived.complete();
    });
    final cache = AudioCache(folder, (_) async => 4, fixturePort: server.port);
    try {
      final download = cache.save(
        const Track('1_1', 'Track', 'Artist', 4),
        Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
      );
      final result = expectLater(download, throwsA(isA<ProofFailure>()));
      await arrived.future.timeout(const Duration(seconds: 3));
      cache.cancel();
      await result.timeout(const Duration(seconds: 2));
      expect(await folder.list().length, 0);
    } finally {
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  });
  test(
    'cancelled downloads never publish offline-ready audio and clean staging',
    () async {
      final folder = await Directory.systemTemp.createTemp('ownsemble-cancel-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add(List.filled(1024, 1));
        await request.response.close();
      });
      var cancelled = false;
      try {
        final cache = AudioCache(
          folder,
          (_) async => 4,
          fixturePort: server.port,
          cancelled: () => cancelled,
          onProgress: (_) {
            cancelled = true;
          },
        );
        await expectLater(
          cache.save(
            const Track('1_1', 'Track', 'Artist', 4),
            Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
          ),
          throwsA(isA<ProofFailure>()),
        );
        expect(await folder.list().length, 0);
      } finally {
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
  );
  test('offline guard sends no requests', () async {
    final folder = await Directory.systemTemp.createTemp('ownsemble-offline-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add([1]);
      await request.response.close();
    });
    try {
      final cache = AudioCache(folder, (_) async => 4, fixturePort: server.port)
        ..offline = true;
      await expectLater(
        cache.fetch(Uri.parse('http://127.0.0.1:${server.port}/a.mp3')),
        throwsA(isA<ProofFailure>()),
      );
      expect(requests, 0);
    } finally {
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  });
  test('failed decode never publishes a complete asset', () async {
    final folder = await Directory.systemTemp.createTemp('ownsemble-fail-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    try {
      final cache = AudioCache(
        folder,
        (_) async => throw const ProofFailure('decoder_invalid_data'),
        fixturePort: server.port,
      );
      await expectLater(
        cache.save(
          const Track('1_1', 'Track', 'Artist', 4),
          Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
        ),
        throwsA(isA<ProofFailure>()),
      );
      expect(await folder.list().length, 0);
    } finally {
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  });
}
