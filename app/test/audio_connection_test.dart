import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test(
    'one download reuses connections and Stop prevents further requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>{};
      var requests = 0;
      server.listen((request) async {
        requests++;
        ports.add(request.connectionInfo!.remotePort);
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final cache = AudioCache(
        Directory.systemTemp,
        (_) async => 1,
        fixturePort: server.port,
      );
      final source = Uri.parse('http://127.0.0.1:${server.port}/one.ts');
      try {
        expect(await cache.fetch(source), [1, 2, 3]);
        expect(await cache.fetch(source.resolve('two.ts')), [1, 2, 3]);
        expect(ports.length, 1);
        expect(requests, 2);
        cache.cancel();
        await expectLater(cache.fetch(source), throwsA(isA<ProofFailure>()));
        expect(requests, 2);
      } finally {
        cache.cancel();
        await server.close(force: true);
      }
    },
  );
}
