import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test('transfer timings identify headers and first bytes without exporting URLs', () async {
    // Serve multiple generated chunks to prove first-byte timing is emitted once.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.add(List.filled(65536, 1));
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.add(List.filled(65536, 2));
      await request.response.close();
    });
    // Collect only fixed numeric/category events from the generated transfer.
    final events = <Map<String, Object>>[];
    // Preserve normal destination guards while enabling the single fixture port.
    final cache = AudioCache(
      Directory.systemTemp,
      (_) async => 1,
      fixturePort: server.port,
      onDiagnostic: events.add,
    );
    try {
      await cache.fetch(
        Uri.parse(
          'http://127.0.0.1:${server.port}/private-generated-path.mp3?private=1',
        ),
      );
      expect(
        events.map((event) => event['stage']),
        containsAllInOrder([
          'transfer_started',
          'transfer_headers',
          'transfer_first_bytes',
          'transfer_finished',
        ]),
      );
      expect(
        events
            .where((event) => event['stage'] == 'transfer_first_bytes')
            .length,
        1,
      );
      expect(events.last['bytes'], 131072);
      expect(events.toString(), isNot(contains('private-generated')));
      expect(events.toString(), isNot(contains('127.0.0.1')));
    } finally {
      cache.cancel();
      await server.close(force: true);
    }
  });

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
