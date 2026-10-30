import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_client.dart';

void main() {
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
