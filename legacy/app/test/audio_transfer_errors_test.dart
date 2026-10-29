import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/media/streaming_audio.dart';

/// Verify that relay failures retain their original sanitized transfer cause.
void main() {
  test(
    'destination rejection identifies a redirect without exporting its URL',
    () async {
      // Redirect generated traffic to a blocked host without requesting that host.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://blocked.example/private-generated-value.mp3',
        );
        await request.response.close();
      });
      // Allow only the initial local fixture destination.
      final cache = AudioCache(
        Directory.systemTemp,
        (_) async => 1,
        fixturePort: server.port,
      );
      try {
        await expectLater(
          cache.fetch(
            Uri.parse('http://127.0.0.1:${server.port}/generated.mp3'),
          ),
          throwsA(
            isA<AudioDestinationFailure>()
                .having(
                  (error) => error.diagnostic['redirect'],
                  'redirect',
                  true,
                )
                .having((error) => error.diagnostic['https'], 'https', false)
                .having(
                  (error) =>
                      error.diagnostic.toString().contains('private-generated'),
                  'private path exported',
                  false,
                ),
          ),
        );
        expect(cache.networkRequests, 1);
      } finally {
        cache.cancel();
        await server.close(force: true);
      }
    },
  );

  test('an upstream HTTP rejection retains its status code', () async {
    // Serve a controlled rejection without receiving any private request data.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });
    // Allow only this generated loopback fixture through the normal cache guard.
    final cache = AudioCache(
      Directory.systemTemp,
      (_) async => 1,
      fixturePort: server.port,
    );
    try {
      await expectLater(
        cache.fetch(Uri.parse('http://127.0.0.1:${server.port}/generated.mp3')),
        throwsA(
          isA<ProofFailure>()
              .having(
                (error) => error.category,
                'category',
                'audio_http_failed',
              )
              .having((error) => error.code, 'HTTP status', 403),
        ),
      );
    } finally {
      cache.cancel();
      await server.close(force: true);
    }
  });

  test('the relay preserves an upstream failure after returning 502', () async {
    // Fail a generated transfer without contacting any provider host.
    final cache = AudioCache(
      Directory.systemTemp,
      (_) async => 1,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          throw const ProofFailure('audio_http_failed', code: 403),
    );
    // Exercise the real token-scoped loopback relay used by the native player.
    final stream = StreamingAudio(
      cache,
      Uri.parse('https://test.vkuseraudio.net/generated.mp3'),
    );
    // Read only the generated local response; never inspect real media bytes.
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      // Open the relay and wait until its controlled transfer fails.
      final response = await (await client.getUrl(await stream.open())).close();
      await response.drain<void>();
      expect(response.statusCode, 502);
      expect(stream.failure?.category, 'audio_http_failed');
      expect(stream.failure?.code, 403);
      await stream.close(cancel: true);
      expect(stream.failure?.category, 'audio_http_failed');
    } finally {
      client.close(force: true);
      await stream.close(cancel: true);
    }
  });

  test('manifest parsing failures remain distinguishable from player failures', () async {
    // Return an invalid generated manifest through the existing resource seam.
    final cache = AudioCache(
      Directory.systemTemp,
      (_) async => 1,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList(utf8.encode('generated invalid manifest')),
    );
    // Exercise manifest handling through the actual local player endpoint.
    final stream = StreamingAudio(
      cache,
      Uri.parse('https://test.vkuseraudio.net/generated.m3u8'),
    );
    // Keep generated relay requests outside system proxy configuration.
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      // Read the generated failure response without exposing any upstream URL.
      final response = await (await client.getUrl(await stream.open())).close();
      await response.drain<void>();
      expect(response.statusCode, 502);
      expect(stream.failure?.category, 'hls_invalid_manifest');
    } finally {
      client.close(force: true);
      await stream.close(cancel: true);
    }
  });
}
