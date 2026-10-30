import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late LibraryStore store;
  late AudioStorage storage;
  late int vk;
  late List<Track> songs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ownsemble_storage');
    store = LibraryStore.open(p.join(dir.path, 'library.db'));
    vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      for (var i = 0; i < 5; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Исполнитель',
          title: 'Песня $i',
          durationSec: 200,
          addedAt: i,
        ),
    ]);
    songs = store.loadAll().reversed.toList(); // songs[i] has key 1_i
    storage = AudioStorage(dataDir: dir.path, store: store);
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  /// Stores a file of [bytes] bytes for songs[i] as cache, stored at [at].
  String cache(int i, int bytes, {bool pinned = false}) {
    final path = storage.relativePathFor(songs[i]);
    storage.fileAt(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, i));
    storage.recordStored(songs[i], path, bytes, pinned: pinned);
    return path;
  }

  test('stored files live in the cache folder under internal names', () {
    expect(storage.relativePathFor(songs[3]), p.join('cache', 'vk_1_3.mp3'));
  });

  test('the cache limit removes the songs played longest ago', () {
    store.writeSetting(AudioStorage.limitSetting, '250');
    final paths = [for (var i = 0; i < 3; i++) cache(i, 100)];
    // Under the limit with two songs; the third pushed it over and the
    // oldest stored one (never played) went.
    expect(storage.stateOf(songs[0]).path, isNull);
    expect(storage.fileAt(paths[0]).existsSync(), isFalse);
    expect(store.cachedBytes(), 200);

    // Song 1 was played recently, so song 2 goes next.
    store.addPlay(songs[1].id);
    cache(3, 100);
    expect(storage.stateOf(songs[1]).path, isNotNull);
    expect(storage.stateOf(songs[2]).path, isNull);
    expect(storage.stateOf(songs[3]).path, isNotNull);
  });

  test('downloaded songs and the song playing are never removed', () {
    store.writeSetting(AudioStorage.limitSetting, '150');
    cache(0, 100, pinned: true);
    cache(1, 100);
    expect(store.cachedBytes(), 100, reason: 'downloads do not count');
    storage.applyLimit();
    cache(2, 100);
    expect(storage.stateOf(songs[0]).pinned, isTrue);
    expect(storage.stateOf(songs[1]).path, isNull);

    store.writeSetting(AudioStorage.limitSetting, '0');
    expect(storage.applyLimit(keep: {songs[2].id}), isEmpty);
    expect(storage.stateOf(songs[2]).path, isNotNull);
  });

  test('a file another song still uses is not deleted', () {
    store.writeSetting(AudioStorage.limitSetting, '0');
    final path = cache(0, 100, pinned: true);
    // A second, cached song borrowing the downloaded song's file (the speed
    // gate's filler songs do this).
    store.saveAudioFile(songs[1].id, path, 100);
    expect(storage.applyLimit(), isEmpty);
    expect(storage.fileAt(path).existsSync(), isTrue);
  });

  test('downloading a cached song only marks it downloaded', () async {
    cache(0, 100);
    await storage.download(songs[0], () async => fail('no fetch needed'));
    expect(storage.stateOf(songs[0]).pinned, isTrue);
    expect(store.loadAll().firstWhere((t) => t.id == songs[0].id).pinned, true);
  });

  test('a download of a song being saved while it streams waits for that '
      'save instead of fetching it again', () async {
    final path = storage.relativePathFor(songs[2]);
    final save = Completer<int?>();
    storage.noteSaving(songs[2], save.future);
    // What the player does when the save finishes.
    save.future.then((bytes) {
      storage.fileAt(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      storage.recordStored(songs[2], path, bytes!);
    });
    final download = storage.download(
      songs[2],
      () async => fail('must not fetch the song again'),
    );
    expect(storage.isDownloading(songs[2]), isTrue);
    save.complete(3);
    await download;
    expect(storage.stateOf(songs[2]), (path: path, pinned: true));
  });

  test('a canceled streaming save makes the download fetch the song', () async {
    final save = Completer<int?>();
    storage.noteSaving(songs[2], save.future);
    var fetched = false;
    final download = storage.download(songs[2], () async {
      fetched = true;
      return null; // the fetch itself is covered below
    });
    save.complete(null);
    await expectLater(download, throwsA(isA<StateError>()));
    expect(fetched, isTrue);
  });

  group('downloads over HTTP', () {
    late HttpServer server;
    final audio = List<int>.generate(70000, (i) => i % 253);
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/missing') {
          request.response.statusCode = HttpStatus.notFound;
        } else if (request.uri.path == '/broken') {
          // What VK's audio server answers for a file it cannot deliver.
          request.response.statusCode = HttpStatus.gatewayTimeout;
        } else {
          request.response.contentLength = audio.length;
          request.response.add(audio);
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('a download fetches the song and keeps it', () async {
      final notified = <bool>[];
      storage.addListener(() => notified.add(storage.isDownloading(songs[4])));
      await storage.download(
        songs[4],
        () async => Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
      );
      final state = storage.stateOf(songs[4]);
      expect(state.pinned, isTrue);
      expect(storage.fileAt(state.path!).readAsBytesSync(), audio);
      expect(notified.first, isTrue, reason: 'shown as downloading');
      expect(storage.isDownloading(songs[4]), isFalse);

      final reopened = store.loadAll().firstWhere((t) => t.id == songs[4].id);
      expect(reopened.isDownloaded, isTrue);
    });

    test('a failed download leaves nothing behind', () async {
      await expectLater(
        storage.download(
          songs[4],
          () async => Uri.parse('http://127.0.0.1:${server.port}/missing'),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(storage.stateOf(songs[4]).path, isNull);
      expect(storage.isDownloading(songs[4]), isFalse);
      final cacheDir = Directory(p.join(dir.path, 'cache'));
      expect(cacheDir.existsSync() ? cacheDir.listSync() : [], isEmpty);
    });

    test(
      'a file the server cannot deliver comes from the alternative',
      () async {
        await storage.download(
          songs[4],
          () async => Uri.parse('http://127.0.0.1:${server.port}/broken'),
          alternative: () async =>
              Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
        );
        final state = storage.stateOf(songs[4]);
        expect(state.pinned, isTrue);
        expect(storage.fileAt(state.path!).readAsBytesSync(), audio);
      },
    );

    test('with no alternative the server failure is reported', () async {
      await expectLater(
        storage.download(
          songs[4],
          () async => Uri.parse('http://127.0.0.1:${server.port}/broken'),
          alternative: () async => null,
        ),
        throwsA(
          isA<AudioServerException>().having(
            (error) => error.status,
            'status',
            HttpStatus.gatewayTimeout,
          ),
        ),
      );
      expect(storage.stateOf(songs[4]).path, isNull);
    });

    test('a song VK has no stream for cannot be downloaded', () async {
      await expectLater(
        storage.download(songs[4], () async => null),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('removing a download makes the song plain cache again', () {
    store.writeSetting(AudioStorage.limitSetting, '50');
    cache(0, 100, pinned: true);
    storage.removeDownload(songs[0], keep: {songs[0].id});
    expect(storage.stateOf(songs[0]), (
      path: storage.relativePathFor(songs[0]),
      pinned: false,
    ));
    storage.removeDownload(songs[1]); // not stored: nothing happens
    // Over the limit now, and no longer kept: it goes.
    storage.applyLimit();
    expect(storage.stateOf(songs[0]).path, isNull);
  });
}
