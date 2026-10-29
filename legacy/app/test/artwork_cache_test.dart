import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/artwork_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ownsemble-art-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  late Uint8List png;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF83AB62), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 2);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  test('artwork rejects unsafe destinations before any request', () async {
    expect(
      allowedArtwork(Uri.parse('https://sun1.vkuserphoto.ru/generated.jpg')),
      isTrue,
    );
    expect(
      allowedArtwork(
        Uri.parse('https://sun1.vkuserphoto.ru.attacker.test/generated.jpg'),
      ),
      isFalse,
    );
    var requests = 0;
    final cache = ArtworkCache(
      dir,
      fetch: (uri) async {
        requests++;
        return ArtworkResponse(png, 'image/png');
      },
    );
    for (final url in [
      'http://test.userapi.com/a',
      'https://userapi.com.attacker.test/a',
      'https://u:p@test.userapi.com/a',
      'https://test.userapi.com:8443/a',
    ]) {
      await expectLater(
        cache.obtain(Uri.parse(url)),
        throwsA(isA<ProofFailure>()),
      );
    }
    expect(requests, 0);
  });

  test('one in-flight image is shared and identical album bytes deduplicate on disk', () async {
    var requests = 0;
    final cache = ArtworkCache(
      dir,
      fetch: (uri) async {
        requests++;
        return ArtworkResponse(png, 'image/png');
      },
    );
    final uri = Uri.parse('https://test.userapi.com/generated.png');
    final keys = await Future.wait([cache.obtain(uri), cache.obtain(uri)]);
    expect(keys[0], keys[1]);
    expect(requests, 1);
    final next = await cache.obtain(
      Uri.parse('https://test.userapi.com/other.png'),
    );
    expect(next, keys.first);
    expect(dir.listSync().whereType<File>().length, 1);
    expect(cache.localFile(next)!.existsSync(), isTrue);
  });

  test('a slow cover does not stall other covers and at most four fetch together', () async {
    final started = <String>[];
    final gates = <String, Completer<ArtworkResponse>>{};
    var active = 0, peak = 0;
    final cache = ArtworkCache(
      dir,
      fetch: (uri) async {
        started.add(uri.path);
        active++;
        if (active > peak) peak = active;
        final response =
            await (gates[uri.path] = Completer<ArtworkResponse>()).future;
        active--;
        return response;
      },
    );
    final jobs = [
      for (var i = 0; i < 7; i++)
        cache.obtain(Uri.parse('https://test.userapi.com/$i.png')),
    ];
    // Drain only scheduling microtasks. The first network request remains hung.
    await Future<void>.delayed(Duration.zero);
    final firstBatch = List<String>.of(started);
    // Release every requested response even on the old sequential implementation.
    while (gates.length < 7 || gates.values.any((gate) => !gate.isCompleted)) {
      for (final gate in gates.values.toList()) {
        if (!gate.isCompleted) gate.complete(ArtworkResponse(png, 'image/png'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final keys = await Future.wait(jobs);
    expect(firstBatch, ['/0.png', '/1.png', '/2.png', '/3.png']);
    expect(peak, 4);
    expect(keys.toSet().length, 1);
    expect(dir.listSync().whereType<File>().length, 1);
    cache.close();
  });

  test(
    'oversized, non-image and corrupt responses never publish cache files',
    () async {
      for (final response in [
        ArtworkResponse(Uint8List(2 * 1024 * 1024 + 1), 'image/png'),
        ArtworkResponse(png, 'text/html'),
        ArtworkResponse(Uint8List.fromList([1, 2, 3]), 'image/png'),
      ]) {
        final cache = ArtworkCache(dir, fetch: (uri) async => response);
        await expectLater(
          cache.obtain(Uri.parse('https://test.userapi.com/generated.png')),
          throwsA(isA<ProofFailure>()),
        );
        expect(dir.listSync(), isEmpty);
      }
    },
  );

  test('every redirect hop is guarded before following it', () async {
    var requests = 0;
    final cache = ArtworkCache(
      dir,
      fetch: (uri) async {
        requests++;
        return ArtworkResponse(
          Uint8List(0),
          '',
          redirect: Uri.parse('https://attacker.test/image.png'),
        );
      },
    );
    await expectLater(
      cache.obtain(Uri.parse('https://test.userapi.com/generated.png')),
      throwsA(isA<ProofFailure>()),
    );
    expect(requests, 1);
  });

  test(
    'extreme image dimensions are rejected before decode can inflate them',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xFF83AB62), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final wide = await picture.toImage(8193, 100);
      final data = (await wide.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      wide.dispose();
      picture.dispose();
      final cache = ArtworkCache(
        dir,
        fetch: (_) async => ArtworkResponse(data, 'image/png'),
      );
      await expectLater(
        cache.obtain(Uri.parse('https://test.userapi.com/wide.png')),
        throwsA(isA<ProofFailure>()),
      );
      expect(dir.listSync(), isEmpty);
      cache.close();
    },
  );

  test('a viewport jump discards obsolete queued covers and prioritizes its destination', () async {
    final gates = <String, Completer<ArtworkResponse>>{};
    final wanted = <int>{0, 1, 2, 3, 4, 5, 6};
    final cache = ArtworkCache(
      dir,
      fetch: (uri) => (gates[uri.path] = Completer<ArtworkResponse>()).future,
    );
    final old = [
      for (var i = 0; i < 7; i++)
        cache.obtain(
          Uri.parse('https://test.userapi.com/$i.png'),
          needed: () => wanted.contains(i),
        ),
    ];
    final oldChecks = [
      for (final job in old) expectLater(job, throwsA(isA<ProofFailure>())),
    ];
    await Future<void>.delayed(Duration.zero);
    wanted.clear();
    cache.prune();
    final destination = cache.obtain(
      Uri.parse('https://test.userapi.com/destination.png'),
      needed: () => true,
      priority: 10,
    );
    for (final gate in gates.values.toList()) {
      gate.complete(ArtworkResponse(png, 'image/png'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(gates.keys, contains('/destination.png'));
    expect(gates.keys, isNot(contains('/4.png')));
    gates['/destination.png']!.complete(ArtworkResponse(png, 'image/png'));
    await Future.wait(oldChecks);
    expect(cache.localFile(await destination), isNotNull);
    expect(dir.listSync().whereType<File>().length, 1);
    cache.close();
  });

  test(
    'shared cover stays wanted when one of its visible consumers leaves',
    () async {
      var first = true, second = true, requests = 0;
      final gate = Completer<ArtworkResponse>();
      final cache = ArtworkCache(
        dir,
        fetch: (uri) {
          requests++;
          return gate.future;
        },
      );
      final source = Uri.parse('https://test.userapi.com/shared.png');
      final a = cache.obtain(source, needed: () => first);
      final b = cache.obtain(source, needed: () => second);
      await Future<void>.delayed(Duration.zero);
      first = false;
      cache.prune();
      gate.complete(ArtworkResponse(png, 'image/png'));
      expect(await a, await b);
      expect(requests, 1);
      second = false;
      cache.close();
    },
  );

  test('offline mode blocks artwork requests and cancels publication of a pending image', () async {
    var allowed = false, requests = 0;
    final gate = Completer<ArtworkResponse>();
    final cache = ArtworkCache(
      dir,
      networkAllowed: () => allowed,
      fetch: (uri) {
        requests++;
        return gate.future;
      },
    );
    final uri = Uri.parse('https://test.userapi.com/generated.png');
    await expectLater(cache.obtain(uri), throwsA(isA<ProofFailure>()));
    expect(requests, 0);
    allowed = true;
    final pending = cache.obtain(uri);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    allowed = false;
    cache.cancel();
    gate.complete(ArtworkResponse(png, 'image/png'));
    await expectLater(pending, throwsA(isA<ProofFailure>()));
    expect(dir.listSync(), isEmpty);
  });

  test(
    'cancel invalidates queued and late covers even after network is reenabled',
    () async {
      var requests = 0;
      final gate = Completer<ArtworkResponse>();
      final cache = ArtworkCache(
        dir,
        fetch: (uri) {
          requests++;
          return gate.future;
        },
      );
      final tasks = [
        for (var i = 0; i < 7; i++)
          cache.obtain(Uri.parse('https://test.userapi.com/$i.png')),
      ];
      final checks = [
        for (final task in tasks)
          expectLater(task, throwsA(isA<ProofFailure>())),
      ];
      await Future<void>.delayed(Duration.zero);
      cache.cancel();
      gate.complete(ArtworkResponse(png, 'image/png'));
      await Future.wait(checks);
      expect(requests, lessThanOrEqualTo(4));
      expect(dir.listSync(), isEmpty);
      cache.close();
    },
  );
}
