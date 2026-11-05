import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_file_print.dart';

import 'mp3_samples.dart';

void main() {
  late HttpServer server;
  late HttpClient http;
  final song = songOf(
    219.2,
    tag: id3Tag('Операция Пластилин - Ты и я', padding: 30000),
  );
  // The same size, one byte other in the middle: another file.
  final changed = [...song]..[song.length ~/ 2] ^= 0xff;
  var ignoreRanges = false;

  setUp(() async {
    ignoreRanges = false;
    http = HttpClient();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final bytes = switch (request.uri.path) {
        '/changed' => changed,
        '/longer' => songOf(226.5),
        _ => song,
      };
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final response = request.response
        ..headers.contentType = ContentType('audio', 'mpeg');
      if (range == null || ignoreRanges) {
        response
          ..contentLength = bytes.length
          ..add(bytes);
      } else {
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!).clamp(0, bytes.length - 1);
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          )
          ..add(bytes.sublist(start, end + 1));
      }
      await response.close();
    });
  });

  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('reads the size, the length and the samples', () async {
    final print = (await printRemote(http, at('/song')))!;
    expect(print.bytes, song.length);
    expect(print.seconds, closeTo(219.2, 0.3));
    expect(print.hasFile, isTrue);
  });

  test('the same file prints the same; a changed byte does not', () async {
    final first = (await printRemote(http, at('/song')))!;
    final again = (await printRemote(http, at('/song')))!;
    final other = (await printRemote(http, at('/changed')))!;
    expect(first.sameFileAs(again), isTrue);
    expect(other.bytes, first.bytes);
    expect(first.sameFileAs(other), isFalse);
  });

  test('another recording differs in size and length', () async {
    final first = (await printRemote(http, at('/song')))!;
    final longer = (await printRemote(http, at('/longer')))!;
    expect(first.sameFileAs(longer), isFalse);
    expect(longer.seconds, closeTo(226.5, 0.3));
  });

  test('a server that ignores ranges gives no print', () async {
    // Its answers would all be the file's start, never the quarters.
    ignoreRanges = true;
    expect(await printRemote(http, at('/song')), isNull);
  });
}
