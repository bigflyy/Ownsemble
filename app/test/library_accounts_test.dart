import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

NewTrack song(
  String key,
  String title, {
  int? trackId,
  int seconds = 200,
  String artist = 'Земфира',
  String? accessKey,
  int addedAt = 0,
}) => NewTrack(
  sourceKey: key,
  artist: artist,
  title: title,
  durationSec: seconds,
  addedAt: addedAt,
  vkTrackId: trackId,
  accessKey: accessKey,
);

void main() {
  late LibraryStore store;
  late int first;
  late int second;
  setUp(() {
    store = LibraryStore.open(':memory:');
    first = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    second = store.ensureSource(TrackSource.vk, account: '2', name: 'VK');
  });
  tearDown(() => store.close());

  /// Adds one song to each account; returns their row ids.
  (int, int) sharedSong({
    int firstTrackId = 7,
    int secondTrackId = 7,
    bool merge = true,
  }) {
    final a = store.upsertAll(first, [
      song('1_1', 'Хочешь?', trackId: firstTrackId, accessKey: 'key-1'),
    ]).single;
    final b = store.upsertAll(second, [
      song('2_1', 'Хочешь?', trackId: secondTrackId, accessKey: 'key-2'),
    ]).single;
    if (merge) store.mergeSameSongs();
    return (a, b);
  }

  group('colors', () {
    test('each account gets the next free color', () {
      final third = store.ensureSource(
        TrackSource.vk,
        account: '3',
        name: 'VK',
      );
      expect(
        {for (final s in store.sources()) s.id: s.color},
        {first: 1, second: 2, third: 3},
      );
    });

    test('a color freed by a removed account is used again', () {
      store.removeSource(first);
      final third = store.ensureSource(
        TrackSource.vk,
        account: '3',
        name: 'VK',
      );
      expect(store.sources().firstWhere((s) => s.id == third).color, 1);
    });

    test('with every color taken they repeat', () {
      for (var account = 3; account <= sourceColorCount + 1; account++) {
        store.ensureSource(TrackSource.vk, account: '$account', name: 'VK');
      }
      expect(store.sources().last.color, inInclusiveRange(1, sourceColorCount));
    });

    test('the user can pick another one', () {
      store.setSourceColor(second, 5);
      expect(store.sources().last.color, 5);
    });
  });

  group('names', () {
    test('a chosen name stays when the account name arrives', () {
      store.renameSource(first, 'Рабочий');
      store.nameSource(first, 'Анна', placeholder: 'VK');
      store.nameSource(second, 'Анна', placeholder: 'VK');
      expect(store.sources().map((s) => s.name), ['Рабочий', 'Анна']);
    });
  });

  group('merging', () {
    test('one song in two accounts lists once, with both copies', () {
      final (a, _) = sharedSong();
      final track = store.loadAll().single;
      expect(track.id, a);
      expect(track.sourceId, first);
      expect(track.copies.single.sourceId, second);
      expect(track.copies.single.sourceKey, '2_1');
      expect(track.copies.single.accessKey, 'key-2');
      expect(track.isFrom(first), isTrue);
      expect(track.isFrom(second), isTrue);
    });

    test('each account still counts its own songs', () {
      sharedSong();
      expect(store.sources().map((s) => s.songCount), [1, 1]);
    });

    test('a sync of either account still reaches its own row', () {
      sharedSong();
      store.upsertAll(second, [
        song('2_1', 'Хочешь?', trackId: 7, accessKey: 'new-key'),
      ]);
      expect(store.loadAll().single.copies.single.accessKey, 'new-key');
    });

    test('nothing to do with one account', () {
      store.upsertAll(first, [
        song('1_1', 'А', trackId: 7),
        song('1_2', 'А', trackId: 7),
      ]);
      expect(store.mergeSameSongs().merged, 0);
      expect(store.loadAll(), hasLength(2));
    });

    test('running it again changes nothing', () {
      sharedSong();
      expect(store.mergeSameSongs().merged, 0);
    });

    test('a removed account does not take part', () {
      final (a, _) = sharedSong(merge: false);
      store.addPlay(a);
      store.removeSource(first);
      store.upsertAll(second, [song('2_2', 'Другая', trackId: 9)]);
      expect(store.mergeSameSongs().merged, 0);
    });
  });

  group('a merged song that one account lost', () {
    test('is not gone while another account has it', () {
      sharedSong();
      store.markGone(first, ['1_1']);
      final track = store.loadAll().single;
      expect(track.goneAtMs, isNotNull);
      expect(track.isGone, isFalse);
    });

    test('is gone when no account has it', () {
      sharedSong();
      store.markGone(first, ['1_1']);
      store.markGone(second, ['2_1']);
      expect(store.loadAll().single.isGone, isTrue);
    });
  });

  group('what was made of a row before it merged', () {
    test('History, Stacks and audio move to the listed row', () {
      final (a, b) = sharedSong(merge: false);
      store.addPlay(b);
      final stack = store.createStack('Вечер');
      store.addToStack(stack, b);
      store.saveAudioFile(b, 'cache/vk_2_1.mp3', 10, pinned: true);

      expect(store.mergeSameSongs().unusedFiles, isEmpty);

      expect(store.history().single.trackId, a);
      expect(store.stackEntries(stack).single.trackId, a);
      final track = store.loadAll().single;
      expect(track.localPath, 'cache/vk_2_1.mp3');
      expect(track.pinned, isTrue);
    });

    test('with audio on both rows one file stays, kept if either was', () {
      final (a, b) = sharedSong(merge: false);
      store.saveAudioFile(a, 'cache/vk_1_1.mp3', 10);
      store.saveAudioFile(b, 'cache/vk_2_1.mp3', 10, pinned: true);

      expect(store.mergeSameSongs().unusedFiles, ['cache/vk_2_1.mp3']);

      final track = store.loadAll().single;
      expect(track.localPath, 'cache/vk_1_1.mp3');
      expect(track.pinned, isTrue);
    });
  });

  group('removing an account', () {
    test('takes its songs out of the lists and out of the sources', () {
      store.upsertAll(first, [song('1_1', 'Своя')]);
      store.upsertAll(second, [song('2_1', 'Чужая')]);
      store.removeSource(second);
      expect(store.loadAll().single.title, 'Своя');
      expect(store.sources().single.id, first);
    });

    test('keeps a played, stacked or stored song, marked gone', () {
      final ids = store.upsertAll(second, [
        song('2_1', 'В истории'),
        song('2_2', 'На стопке'),
        song('2_3', 'На диске'),
        song('2_4', 'Ничего'),
      ]);
      store.addPlay(ids[0]);
      store.addToStack(store.createStack('Вечер'), ids[1]);
      store.saveAudioFile(ids[2], 'cache/vk_2_3.mp3', 10);

      store.removeSource(second);

      final left = store.loadAll();
      expect(
        left.map((t) => t.title),
        unorderedEquals(['В истории', 'На стопке', 'На диске']),
      );
      expect(left.every((t) => t.isGone), isTrue);
      expect(store.sources().single.id, first);
    });

    test('a merged song stays, on the other account', () {
      final (a, b) = sharedSong();
      store.addPlay(a);
      store.saveAudioFile(a, 'cache/vk_1_1.mp3', 10);

      store.removeSource(first);

      final track = store.loadAll().single;
      expect(track.id, b);
      expect(track.sourceId, second);
      expect(track.copies, isEmpty);
      expect(track.isGone, isFalse);
      expect(track.localPath, 'cache/vk_1_1.mp3');
      expect(store.history().single.trackId, b);
    });

    test('the other copies follow the song to its new row', () {
      final third = store.ensureSource(
        TrackSource.vk,
        account: '3',
        name: 'VK',
      );
      final (_, b) = sharedSong(merge: false);
      final c = store.upsertAll(third, [
        song('3_1', 'Хочешь?', trackId: 7),
      ]).single;
      store.mergeSameSongs();

      store.removeSource(first);

      final track = store.loadAll().single;
      expect(track.id, b);
      expect(track.copies.single.sourceKey, '3_1');
      expect(c, isNot(b));
    });

    test('removing the copy\'s account leaves the listed song alone', () {
      final (a, _) = sharedSong();
      store.removeSource(second);
      final track = store.loadAll().single;
      expect(track.id, a);
      expect(track.copies, isEmpty);
    });

    test('logging in to it again brings it back', () {
      final id = store.upsertAll(second, [song('2_1', 'В истории')]).single;
      store.addPlay(id);
      store.removeSource(second);
      expect(store.sources().map((s) => s.id), [first]);

      final again = store.ensureSource(
        TrackSource.vk,
        account: '2',
        name: 'VK',
      );
      expect(again, second);
      expect(store.sources().map((s) => s.id), [first, second]);
      store.upsertAll(second, [song('2_1', 'В истории')]);
      expect(store.loadAll().single.isGone, isFalse);
    });
  });

  test('a version 3 library gains colors and keeps its songs', () {
    final dir = Directory.systemTemp.createTempSync('ownsemble_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'library.db');
    final old = LibraryStore.open(path);
    final a = old.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    old.ensureSource(TrackSource.vk, account: '2', name: 'VK');
    old.upsertAll(a, [song('1_1', 'Выхода нет', trackId: 7)]);
    old.close();

    final db = sqlite3.open(path);
    db.execute('DROP INDEX tracks_copies');
    db.execute('ALTER TABLE tracks DROP COLUMN same_as');
    db.execute('ALTER TABLE tracks DROP COLUMN vk_track_id');
    db.execute('ALTER TABLE sources DROP COLUMN color');
    db.execute('ALTER TABLE sources DROP COLUMN removed_at_ms');
    db.execute('PRAGMA user_version = 3');
    db.close();

    final migrated = LibraryStore.open(path);
    addTearDown(migrated.close);
    expect(migrated.loadAll().single.title, 'Выхода нет');
    expect(migrated.sources().map((s) => s.color), [1, 2]);
  });
}
