import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/storage/cover_store.dart';
import 'package:path/path.dart' as p;

/// Smallest bytes the store accepts as an image.
final jpeg = [0xFF, 0xD8, ...List.filled(30, 0)];

/// A local image server: counts requests and can hold answers back.
class FakeImages {
  late HttpServer _server;
  final requested = <String>[];
  Completer<void>? gate;
  int status = 200;
  List<int> body = jpeg;
  int running = 0;
  int mostAtOnce = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requested.add(request.uri.path);
      running++;
      if (running > mostAtOnce) mostAtOnce = running;
      await gate?.future;
      running--;
      request.response.statusCode = status;
      request.response.add(body);
      await request.response.close();
    });
  }

  String url(String name, {String query = 'size=135'}) =>
      'http://127.0.0.1:${_server.port}/$name.jpg?$query';

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory dir;
  late FakeImages images;
  late CoverStore covers;

  setUp(() async {
    // Cyrillic on purpose: the data folder may have any name.
    final root = Directory.systemTemp.createTempSync('covers');
    dir = Directory(p.join(root.path, 'обложки'))..createSync();
    images = FakeImages();
    await images.start();
    covers = CoverStore(dataDir: dir.path, maxDownloads: 2);
    await covers.load();
  });

  tearDown(() async {
    covers.close();
    await images.stop();
    dir.parent.deleteSync(recursive: true);
  });

  Future<String?> fetch(CoverStore store, String url) {
    final done = Completer<String?>();
    store.fetch(url, done.complete);
    return done.future;
  }

  test('the key ignores the host and keeps path and query apart', () {
    final key = coverKey('https://sun9-1.example/impg/a.jpg?size=135&sign=x');
    expect(key, coverKey('https://sun9-77.example/impg/a.jpg?size=135&sign=x'));
    expect(
      key,
      isNot(coverKey('https://a.example/impg/a.jpg?size=600&sign=x')),
    );
    expect(
      key,
      isNot(coverKey('https://a.example/impg/b.jpg?size=135&sign=x')),
    );
    expect(key, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(coverKey('not a link'), isNull);
  });

  test('a cover downloads once, stays stored, known after restart', () async {
    final url = images.url('a');
    expect(covers.storedPath(url), isNull);

    final path = await fetch(covers, url);

    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), jpeg);
    expect(covers.storedPath(url), path);
    await fetch(covers, url);
    expect(images.requested, hasLength(1));

    final restarted = CoverStore(dataDir: dir.path);
    addTearDown(restarted.close);
    await restarted.load();
    expect(restarted.storedPath(url), path);
  });

  test('the same cover from another host counts as stored', () async {
    final path = await fetch(covers, images.url('a'));
    final moved = images.url('a').replaceFirst('127.0.0.1', 'localhost');
    expect(covers.storedPath(moved), path);
  });

  test('two tiles asking at once share one download', () async {
    images.gate = Completer();
    final url = images.url('a');
    final first = fetch(covers, url);
    final second = fetch(covers, url);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    images.gate!.complete();

    expect(await first, await second);
    expect(images.requested, hasLength(1));
  });

  test('downloads are limited and the newest request goes first', () async {
    images.gate = Completer();
    final all = [for (var i = 0; i < 5; i++) fetch(covers, images.url('s$i'))];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(images.running, 2);
    images.gate!.complete();
    await Future.wait(all);

    expect(images.mostAtOnce, lessThanOrEqualTo(2));
    expect(images.requested.sublist(2), ['/s4.jpg', '/s3.jpg', '/s2.jpg']);
  });

  test('a canceled request never downloads and is never answered', () async {
    images.gate = Completer();
    final first = fetch(covers, images.url('a'));
    final second = fetch(covers, images.url('b'));
    var answered = false;
    final request = covers.fetch(images.url('gone'), (_) => answered = true);
    request!.cancel();
    images.gate!.complete();
    await Future.wait([first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(images.requested, isNot(contains('/gone.jpg')));
    expect(answered, isFalse);
  });

  test('one of two tiles canceling keeps the download for the other', () async {
    images.gate = Completer();
    final url = images.url('shared');
    final kept = fetch(covers, url);
    covers.fetch(url, (_) => fail('canceled'))!.cancel();
    images.gate!.complete();

    expect(await kept, isNotNull);
  });

  test('an error status gives null and is not asked again soon', () async {
    var now = DateTime(2026, 10, 30);
    final store = CoverStore(
      dataDir: dir.path,
      retryAfter: const Duration(minutes: 10),
      clock: () => now,
    );
    addTearDown(store.close);
    await store.load();
    images.status = 404;
    final url = images.url('missing');

    expect(await fetch(store, url), isNull);
    expect(store.isUnavailable(url), isTrue);
    expect(await fetch(store, url), isNull);
    expect(images.requested, hasLength(1));

    now = now.add(const Duration(minutes: 11));
    images.status = 200;
    expect(store.isUnavailable(url), isFalse);
    expect(await fetch(store, url), isNotNull);
  });

  test('an error page sent with status 200 is not stored', () async {
    images.body = '<html>nothing here, sorry</html>'.codeUnits;
    final url = images.url('page');

    expect(await fetch(covers, url), isNull);
    expect(covers.storedPath(url), isNull);
    expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('a dead network pauses every download, then they work again', () async {
    var now = DateTime(2026, 10, 30);
    final store = CoverStore(
      dataDir: dir.path,
      offlinePause: const Duration(seconds: 30),
      clock: () => now,
    );
    addTearDown(store.close);
    await store.load();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = 'http://127.0.0.1:${closed.port}/dead.jpg?size=135';
    await closed.close();

    expect(await fetch(store, deadUrl), isNull);
    // Another cover is not even tried while the network is down.
    expect(store.isUnavailable(images.url('b')), isTrue);
    expect(await fetch(store, images.url('b')), isNull);
    expect(images.requested, isEmpty);

    now = now.add(const Duration(seconds: 31));
    expect(await fetch(store, images.url('b')), isNotNull);
  });

  test('requests made before the list of stored covers wait for it', () async {
    final url = images.url('a');
    final path = await fetch(covers, url);
    final restarted = CoverStore(dataDir: dir.path);
    addTearDown(restarted.close);

    final early = fetch(restarted, url);
    await restarted.load();

    expect(await early, path);
    expect(images.requested, hasLength(1));
  });
}
