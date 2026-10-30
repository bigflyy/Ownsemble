import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/playback/stream_proxy.dart';

void main() {
  late HttpServer upstream;
  late StreamProxy proxy;
  final audio = List<int>.generate(100000, (i) => i % 251);
  final client = HttpClient();
  // How many more requests to /flaky drop their connection.
  var flakyDrops = 0;

  setUp(() async {
    // Stand-in for the CDN: serves [audio] with Range support.
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (request.uri.path == '/slow' &&
          request.headers.value(HttpHeaders.rangeHeader) == null) {
        // Sends the audio in ten parts, 30 ms apart (ranges: answered at
        // once, below).
        request.response
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..contentLength = audio.length;
        for (var i = 0; i < 10; i++) {
          request.response.add(audio.sublist(i * 10000, (i + 1) * 10000));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path == '/short') {
        // Announces the whole song, sends half and drops the connection.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n'
          'Content-Length: ${audio.length}\r\n\r\n',
        );
        socket.add(audio.sublist(0, 50000));
        await socket.flush();
        socket.destroy();
        return;
      }
      if (request.uri.path == '/flaky' && flakyDrops > 0) {
        // A lossy line: the connection drops before any answer arrives.
        flakyDrops--;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      if (request.uri.path == '/broken') {
        // What VK's audio server sometimes answers: an HTML error page.
        request.response
          ..statusCode = HttpStatus.gatewayTimeout
          ..headers.contentType = ContentType.html
          ..write('<!DOCTYPE HTML PUBLIC><html>504</html>');
        await request.response.close();
        return;
      }
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

  test('an error page from upstream is reported, not passed on', () async {
    final stream = proxy.add(
      Uri.parse('http://127.0.0.1:${upstream.port}/broken'),
    );
    final (response, body) = await get(stream.localUri);
    expect(response.statusCode, HttpStatus.badGateway);
    expect(body, isEmpty);
    expect(await stream.upstreamFailure, HttpStatus.gatewayTimeout);
  });

  group('a file the audio server cannot deliver', () {
    Uri broken() => Uri.parse('http://127.0.0.1:${upstream.port}/broken');
    Uri good() => Uri.parse('http://127.0.0.1:${upstream.port}/a');

    test('plays from the alternative link instead', () async {
      final logged = proxy.requests.first;
      final stream = proxy.add(broken(), alternative: () async => good());
      final (response, body) = await get(stream.localUri);
      expect(response.statusCode, HttpStatus.ok);
      expect(body, audio);
      final log = await logged;
      expect(log.status, HttpStatus.ok);
      expect(log.tries, contains('status 504, trying the other link'));
      await expectLater(
        stream.upstreamFailure.timeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('seeks use the alternative link too, without asking again', () async {
      var asked = 0;
      final stream = proxy.add(
        broken(),
        alternative: () async {
          asked++;
          return good();
        },
      );
      await get(stream.localUri);
      final (response, body) = await get(
        stream.localUri,
        range: 'bytes=99000-',
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(body, audio.sublist(99000));
      expect(asked, 1);
    });

    test('is saved from the alternative link', () async {
      final dir = Directory.systemTemp.createTempSync('ownsemble_alt');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = File('${dir.path}/vk_1_2.mp3');
      final stream = proxy.add(
        broken(),
        cacheTo: target,
        alternative: () async => good(),
      );
      await get(stream.localUri);
      expect(await stream.stored, audio.length);
      expect(target.readAsBytesSync(), audio);
    });

    test('is reported when there is no alternative after all', () async {
      final stream = proxy.add(broken(), alternative: () async => null);
      final (response, body) = await get(stream.localUri);
      expect(response.statusCode, HttpStatus.badGateway);
      expect(body, isEmpty);
      expect(await stream.upstreamFailure, HttpStatus.gatewayTimeout);
    });

    test('is reported when asking for the alternative fails', () async {
      final stream = proxy.add(
        broken(),
        alternative: () async => throw StateError('VK is down'),
      );
      final (response, _) = await get(stream.localUri);
      expect(response.statusCode, HttpStatus.badGateway);
      expect(await stream.upstreamFailure, HttpStatus.gatewayTimeout);
    });
  });

  test('a dropped connection is tried again before any audio', () async {
    flakyDrops = 2;
    final stream = proxy.add(
      Uri.parse('http://127.0.0.1:${upstream.port}/flaky'),
    );
    final (response, body) = await get(stream.localUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(body, audio);
    expect(flakyDrops, 0);
  });

  test('upstream failure becomes a bad gateway', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final stream = proxy.add(Uri.parse('http://127.0.0.1:$port/a'));
    final (response, _) = await get(stream.localUri);
    expect(response.statusCode, HttpStatus.badGateway);
  });

  test('each request is logged with its range, tries and timing', () async {
    flakyDrops = 1;
    final logs = <ProxyRequestLog>[];
    final subscription = proxy.requests.listen(logs.add);
    final stream = proxy.add(
      Uri.parse('http://127.0.0.1:${upstream.port}/flaky'),
    );
    await get(stream.localUri);
    await get(stream.localUri, range: 'bytes=99000-');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();

    expect(logs, hasLength(2));
    final (whole, seek) = (logs[0], logs[1]);
    expect(whole.fromByte, isNull);
    expect(whole.tries, hasLength(2));
    expect(whole.tries.last, endsWith('ms ok'));
    expect(whole.status, HttpStatus.ok);
    expect(whole.bytes, audio.length);
    expect(whole.end, 'done');
    expect(whole.asked, isNull);
    expect(seek.asked, 'bytes=99000-');
    expect(seek.ranges, 'content-range');
    expect(seek.fromByte, 99000);
    expect(seek.tries, hasLength(1));
    expect(seek.status, HttpStatus.partialContent);
    expect(seek.bytes, 1000);
    expect(seek.headersMs, lessThanOrEqualTo(seek.firstByteMs!));
    expect(
      seek.toString(),
      startsWith('proxy range from 99000: asked bytes=99000-, tries ['),
    );
    expect(seek.toString(), endsWith('1000 bytes in ${seek.totalMs} ms, done'));
  });

  test('a request with no answer is logged as such', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final logged = proxy.requests.first;
    final stream = proxy.add(Uri.parse('http://127.0.0.1:$port/a'));
    await get(stream.localUri, range: 'bytes=10-');
    final log = await logged;
    expect(log.end, 'no answer');
    expect(log.status, 0);
    expect(log.headersMs, isNull);
    expect(log.tries, hasLength(4));
    expect(log.toString(), isNot(contains('127.0.0.1')));
  });

  group('saving while streaming', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ownsemble_tee'));
    tearDown(() => dir.deleteSync(recursive: true));

    File target() => File('${dir.path}/vk_1_2.mp3');
    File part() => File('${target().path}.part');

    /// Opens [uri] with a raw socket, reads at least [bytes] bytes of the
    /// reply and hangs up, as mpv does when it seeks or stops.
    Future<void> readAndHangUp(Uri uri, int bytes) async {
      final socket = await Socket.connect(uri.host, uri.port);
      socket.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
      var received = 0;
      final enough = Completer<void>();
      socket.listen((data) {
        received += data.length;
        if (received >= bytes && !enough.isCompleted) enough.complete();
      }, onError: (_) {});
      await enough.future;
      socket.destroy();
    }

    test('the whole file is saved while it plays', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/a'),
        cacheTo: target(),
      );
      final (_, body) = await get(stream.localUri);
      expect(body, audio);
      expect(await stream.stored, audio.length);
      expect(target().readAsBytesSync(), audio);
      expect(part().existsSync(), isFalse);
    });

    test('reports how much is saved, out of the whole size', () async {
      final seen = <(int, int)>[];
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/slow'),
        cacheTo: target(),
        onSaved: (written, total) => seen.add((written, total)),
      );
      await get(stream.localUri);
      await stream.stored;
      expect(seen.length, greaterThan(1), reason: 'reported along the way');
      expect(seen.last, (audio.length, audio.length));
      expect(seen.first.$1, lessThan(audio.length));
    });

    test('a "bytes=0-" request is saved too', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/a'),
        cacheTo: target(),
      );
      final (response, body) = await get(stream.localUri, range: 'bytes=0-');
      expect(response.statusCode, HttpStatus.partialContent);
      expect(body, audio);
      expect(await stream.stored, audio.length);
      expect(target().readAsBytesSync(), audio);
    });

    test('saving goes on after the player hangs up (a seek)', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/slow'),
        cacheTo: target(),
      );
      await readAndHangUp(stream.localUri, 100);
      expect(await stream.stored, audio.length);
      expect(target().readAsBytesSync(), audio);
    });

    test('a canceled save leaves no file', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/slow'),
        cacheTo: target(),
      );
      await readAndHangUp(stream.localUri, 100);
      proxy.cancelCachingExcept(null);
      expect(await stream.stored, isNull);
      expect(target().existsSync(), isFalse);
      expect(part().existsSync(), isFalse);
    });

    test('the stream kept by cancelCachingExcept is still saved', () async {
      final keep = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/slow'),
        cacheTo: target(),
      );
      final other = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/a'),
        cacheTo: File('${dir.path}/other.mp3'),
      );
      await readAndHangUp(keep.localUri, 100);
      proxy.cancelCachingExcept(keep);
      expect(await other.stored, isNull, reason: 'never started, canceled');
      expect(await keep.stored, audio.length);
    });

    test('a seek stops a running save, so the seek gets the line', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/slow'),
        cacheTo: target(),
      );
      await readAndHangUp(stream.localUri, 100);
      final (_, body) = await get(stream.localUri, range: 'bytes=99000-');
      expect(body, audio.sublist(99000));
      expect(await stream.stored, isNull);
      expect(target().existsSync(), isFalse);
      expect(part().existsSync(), isFalse);
    });

    test('a seek request alone saves nothing', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/a'),
        cacheTo: target(),
      );
      final (_, body) = await get(stream.localUri, range: 'bytes=99000-');
      expect(body, audio.sublist(99000));
      stream.cancelCaching();
      expect(await stream.stored, isNull);
      expect(target().existsSync(), isFalse);
    });

    test('a body shorter than announced is not saved', () async {
      final stream = proxy.add(
        Uri.parse('http://127.0.0.1:${upstream.port}/short'),
        cacheTo: target(),
      );
      try {
        await get(stream.localUri);
      } on HttpException {
        // The player sees the cut too.
      }
      expect(await stream.stored, isNull);
      expect(target().existsSync(), isFalse);
      expect(part().existsSync(), isFalse);
    });
  });
}
