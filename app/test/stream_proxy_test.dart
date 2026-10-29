import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/playback/stream_proxy.dart';

void main() {
  late HttpServer upstream;
  late StreamProxy proxy;
  final audio = List<int>.generate(100000, (i) => i % 251);
  final client = HttpClient();

  setUp(() async {
    // Stand-in for the CDN: serves [audio] with Range support.
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final response = request.response
        ..headers.contentType = ContentType('audio', 'mpeg');
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${audio.length - 1}/${audio.length}',
          );
      }
      response.contentLength = audio.length - start;
      response.add(audio.sublist(start));
      await response.close();
    });
    proxy = await StreamProxy.start();
  });

  tearDown(() async {
    await proxy.close();
    await upstream.close(force: true);
  });

  Future<(HttpClientResponse, List<int>)> get(Uri uri, {String? range}) async {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.fold<List<int>>([], (all, c) => all..addAll(c));
    return (response, body);
  }

  test('passes the whole body and times the first chunk', () async {
    final stream = proxy.add(
      Uri.parse('http://127.0.0.1:${upstream.port}/песня.mp3'),
    );
    expect(stream.localUri.host, '127.0.0.1');
    final (response, body) = await get(stream.localUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'audio/mpeg');
    expect(body, audio);
    expect(await stream.networkFirstChunkMs, greaterThanOrEqualTo(0));
  });

  test('passes range requests through for seeking', () async {
    final stream = proxy.add(Uri.parse('http://127.0.0.1:${upstream.port}/a'));
    final (response, body) = await get(stream.localUri, range: 'bytes=99000-');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 99000-99999/100000',
    );
    expect(body, audio.sublist(99000));
  });

  test('unknown streams are not found', () async {
    final stream = proxy.add(Uri.parse('http://127.0.0.1:${upstream.port}/a'));
    final unknown = stream.localUri.replace(path: '/s/0000.mp3');
    final (response, _) = await get(unknown);
    expect(response.statusCode, HttpStatus.notFound);
  });

  test('upstream failure becomes a bad gateway', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final stream = proxy.add(Uri.parse('http://127.0.0.1:$port/a'));
    final (response, _) = await get(stream.localUri);
    expect(response.statusCode, HttpStatus.badGateway);
  });
}
