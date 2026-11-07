import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/song_generator.dart';
import 'package:ownsemble/library/track.dart';
import 'package:path/path.dart' as p;

NewTrack song(String key, String artist, String title, {int addedAt = 0}) =>
    NewTrack(
      sourceKey: key,
      artist: artist,
      title: title,
      durationSec: 200,
      addedAt: addedAt,
    );

void main() {
  late LibraryStore store;
  late int vk;
  setUp(() {
    store = LibraryStore.open(':memory:');
    vk = store.ensureSource(TrackSource.vk, account: '42', name: 'VK');
  });
  tearDown(() => store.close());

  group('songs', () {
    test('Cyrillic text survives a round trip through a database file', () {
      final dir = Directory.systemTemp.createTempSync('ownsemble_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'library.db');
      final file = LibraryStore.open(path);
      final source = file.ensureSource(
        TrackSource.vk,
        account: '1',
        name: 'ВК Тест',
      );
      final id = file.upsertAll(source, [
        song('1_1', 'Земфира', 'Хочешь? «Ёлка» — всё'),
      ]).single;
      final stack = file.createStack('Вечер у моря');
      file.addToStack(stack, id);
      file.writeSetting('последняя_песня', '{"title": "Ёлка"}');
      file.saveAudioFile(id, p.join('кэш', 'Песня.mp3'), 1);
      file.close();

      final reopened = LibraryStore.open(path);
      final track = reopened.loadAll().single;
      expect(track.artist, 'Земфира');
      expect(track.title, 'Хочешь? «Ёлка» — всё');
      expect(track.localPath, p.join('кэш', 'Песня.mp3'));
      expect(reopened.sources().single.name, 'ВК Тест');
      expect(reopened.stacks().single.name, 'Вечер у моря');
      expect(reopened.readSetting('последняя_песня'), '{"title": "Ёлка"}');
      reopened.close();
    });

    test('upsert updates an existing song', () {
      final first = store.upsertAll(vk, [song('1_1', 'Old Name', 'Song')]);
      final second = store.upsertAll(vk, [song('1_1', 'Новое Имя', 'Song')]);
      expect(second, first);
      expect(store.count(), 1);
      expect(store.loadAll().single.artist, 'Новое Имя');
    });

    test('the same key in two sources is two songs', () {
      final other = store.ensureSource(TrackSource.vk, account: '7', name: 'B');
      store.upsertAll(vk, [song('1_1', 'A', 'B')]);
      store.upsertAll(other, [song('1_1', 'A', 'B')]);
      expect(store.count(), 2);
      expect(store.loadAll().map((t) => t.sourceId).toSet(), {vk, other});
    });

    test('loadAll lists the newest songs first', () {
      store.upsertAll(vk, [
        song('1_1', 'A', 'old', addedAt: 100),
        song('1_2', 'B', 'new', addedAt: 300),
        song('1_3', 'C', 'middle', addedAt: 200),
      ]);
      expect(store.loadAll().map((t) => t.title), ['new', 'middle', 'old']);
    });

    test('album, covers and tint are stored and loaded', () {
      store.upsertAll(vk, [
        const NewTrack(
          sourceKey: '1_1',
          artist: 'A',
          title: 'B',
          album: 'Альбом',
          durationSec: 1,
          addedAt: 0,
          coverUrl: 'https://example.invalid/135.jpg',
          coverLargeUrl: 'https://example.invalid/600.jpg',
          coverMidUrl: 'https://example.invalid/300.jpg',
          coverFullUrl: 'https://example.invalid/1200.jpg',
          tint: 0xFF8A2BE2,
        ),
      ]);
      final track = store.loadAll().single;
      expect(track.album, 'Альбом');
      expect(track.coverUrl, 'https://example.invalid/135.jpg');
      expect(track.coverLargeUrl, 'https://example.invalid/600.jpg');
      expect(track.coverMidUrl, 'https://example.invalid/300.jpg');
      expect(track.coverFullUrl, 'https://example.invalid/1200.jpg');
      expect(track.tint, 0xFF8A2BE2);
      expect(track.source, TrackSource.vk);
    });

    test('generated library is deterministic and searchable', () {
      final gen = store.ensureSource(
        TrackSource.generated,
        account: 'generator',
        name: 'Generated songs',
      );
      final songs = generateSongs(2000);
      expect(
        generateSongs(2000).map((s) => s.title),
        songs.map((s) => s.title),
      );
      store.upsertAll(gen, songs);
      expect(store.count(), 2000);
      expect(SearchIndex(store.loadAll()).search('елка'), isNotEmpty);
    });
  });

  group('sources', () {
    test('ensureSource returns the same id for the same account', () {
      expect(store.ensureSource(TrackSource.vk, account: '42', name: 'VK'), vk);
      expect(store.sources(), hasLength(1));
    });

    test('a source without an account is claimed by the first account', () {
      final fresh = LibraryStore.open(':memory:');
      addTearDown(fresh.close);
      final legacy = fresh.ensureSource(
        TrackSource.vk,
        account: null,
        name: 'VK',
      );
      fresh.upsertAll(legacy, [song('1_1', 'A', 'B')]);
      final claimed = fresh.ensureSource(
        TrackSource.vk,
        account: '99',
        name: 'VK',
      );
      expect(claimed, legacy);
      expect(fresh.sources().single.account, '99');
      final second = fresh.ensureSource(
        TrackSource.vk,
        account: '100',
        name: 'VK 2',
      );
      expect(second, isNot(legacy));
    });

    test('sources report song counts and the last sync', () {
      store.upsertAll(vk, [song('1_1', 'A', 'B'), song('1_2', 'C', 'D')]);
      store.recordSync(vk, atMs: 1000);
      var info = store.sources().single;
      expect(info.songCount, 2);
      expect(info.goneCount, 0);
      expect(info.lastSyncAtMs, 1000);
      expect(info.lastSyncError, isNull);

      store.recordSync(vk, error: 'Нет сети', atMs: 2000);
      info = store.sources().single;
      expect(info.lastSyncAtMs, 2000);
      expect(info.lastSyncError, 'Нет сети');
    });
  });

  group('sync writes', () {
    test('upsertTracks reports added and changed songs only', () {
      final first = store.upsertTracks(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
      ]);
      expect(first.changedIds, first.ids);

      final same = store.upsertTracks(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
      ]);
      expect(same.ids, first.ids);
      expect(same.changedIds, isEmpty);

      final renamed = store.upsertTracks(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'Б', 'два'),
        song('1_3', 'C', 'three'),
      ]);
      expect(renamed.ids.take(2), first.ids);
      expect(renamed.changedIds, [first.ids[1], renamed.ids[2]]);
      expect(store.loadAll().map((t) => t.title), contains('два'));
    });

    test('songs marked gone stay, and come back when listed again', () {
      final ids = store.upsertAll(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
      ]);
      store.saveAudioFile(ids[0], 'cache/a.mp3', 10);
      store.addPlay(ids[0], atMs: 1);
      final stack = store.createStack('Стек');
      store.addToStack(stack, ids[0]);

      expect(store.markGone(vk, ['1_1', '1_404'], atMs: 500), 1);
      expect(store.markGone(vk, ['1_1'], atMs: 900), 0, reason: 'kept');
      final gone = store.loadAll().firstWhere((t) => t.id == ids[0]);
      expect(gone.isGone, isTrue);
      expect(gone.goneAtMs, 500);
      expect(gone.isCached, isTrue);
      expect(store.count(), 2);
      expect(store.history().single.trackId, ids[0]);
      expect(store.stackEntries(stack).single.trackId, ids[0]);
      expect(store.sources().single.goneCount, 1);
      expect(store.trackKeys(vk)['1_1']?.goneAtMs, 500);
      expect(store.trackKeys(vk)['1_2']?.goneAtMs, isNull);

      final back = store.upsertTracks(vk, [song('1_1', 'A', 'one')]);
      expect(back.changedIds, [ids[0]], reason: 'a cleared mark is a change');
      expect(store.loadAll().every((t) => !t.isGone), isTrue);
    });

    test('marking gone only touches the given source', () {
      final other = store.ensureSource(TrackSource.vk, account: '7', name: 'B');
      store.upsertAll(vk, [song('1_1', 'A', 'B')]);
      store.upsertAll(other, [song('1_1', 'A', 'B')]);
      store.markGone(other, ['1_1']);
      expect(store.loadAll().map((t) => (t.sourceId, t.isGone)).toSet(), {
        (vk, false),
        (other, true),
      });
    });
  });

  group('stored audio', () {
    late int id;
    setUp(() => id = store.upsertAll(vk, [song('1_1', 'A', 'B')]).single);

    test('a cached file is kept when a sync updates the song', () {
      store.saveAudioFile(id, r'C:\cache\Песня.mp3', 5000);
      store.upsertAll(vk, [song('1_1', 'A', 'B')]);
      final track = store.loadAll().single;
      expect(track.localPath, r'C:\cache\Песня.mp3');
      expect(track.isCached, isTrue);
      expect(track.isDownloaded, isFalse);
    });

    test('pinning makes a cached song downloaded, unpinning undoes it', () {
      store.saveAudioFile(id, 'cache/a.mp3', 10);
      store.setPinned(id, true);
      expect(store.loadAll().single.isDownloaded, isTrue);
      store.setPinned(id, false);
      expect(store.loadAll().single.isDownloaded, isFalse);
      expect(store.loadAll().single.isCached, isTrue);
    });

    test('caching a downloaded song again keeps it downloaded', () {
      store.saveAudioFile(id, 'cache/a.mp3', 10, pinned: true);
      store.saveAudioFile(id, 'cache/a2.mp3', 20);
      final track = store.loadAll().single;
      expect(track.isDownloaded, isTrue);
      expect(track.localPath, 'cache/a2.mp3');
    });

    test('removing stored audio leaves the song in the library', () {
      store.saveAudioFile(id, 'cache/a.mp3', 10, pinned: true);
      store.removeAudioFile(id);
      expect(store.loadAll().single.isCached, isFalse);
      expect(store.count(), 1);
    });
  });

  group('history', () {
    test('plays are listed newest first, repeats included', () {
      final ids = store.upsertAll(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
      ]);
      store.addPlay(ids[0], atMs: 100);
      store.addPlay(ids[1], atMs: 200);
      store.addPlay(ids[0], atMs: 300);
      expect(store.history().map((e) => e.trackId), [ids[0], ids[1], ids[0]]);
      expect(store.history().map((e) => e.playedAtMs), [300, 200, 100]);
      expect(store.history(limit: 1).single.playedAtMs, 300);
    });

    test('a play keeps how it started, how long it was heard and how it '
        'ended', () {
      final ids = store.upsertAll(vk, [song('1_1', 'A', 'один')]);
      final old = store.addPlay(ids[0], atMs: 50);
      final play = store.beginPlay(
        ids[0],
        start: PlayStart.next,
        shuffle: true,
        atMs: 100,
      );
      expect(store.lastPlay()?.id, play);
      expect(store.lastPlay()?.ended, isNull);
      store.updatePlay(play, listenedMs: 4000);
      store.updatePlay(play, listenedMs: 61500, ended: PlayEnd.skipped);
      final entry = store.history().first;
      expect(entry.playedAtMs, 100);
      expect(entry.started, PlayStart.next);
      expect(entry.shuffle, isTrue);
      expect(entry.listenedMs, 61500);
      expect(entry.ended, PlayEnd.skipped);
      // Plays recorded before schema 9 say nothing about these.
      final before = store.history().firstWhere((e) => e.id == old);
      expect(before.started, isNull);
      expect(before.shuffle, isNull);
      expect(before.listenedMs, isNull);
      expect(before.ended, isNull);
    });

    test('plays in the same millisecond keep their order', () {
      final ids = store.upsertAll(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
      ]);
      store.addPlay(ids[0], atMs: 100);
      store.addPlay(ids[1], atMs: 100);
      expect(store.history().first.trackId, ids[1]);
    });
  });

  group('stacks', () {
    late List<int> ids;
    late int stack;
    setUp(() {
      ids = store.upsertAll(vk, [
        song('1_1', 'A', 'one'),
        song('1_2', 'B', 'two'),
        song('1_3', 'C', 'three'),
      ]);
      stack = store.createStack('Вечер');
    });

    test('adding puts a song on top', () {
      for (final id in ids) {
        store.addToStack(stack, id);
      }
      expect(store.stackEntries(stack).map((e) => e.trackId), [
        ids[2],
        ids[1],
        ids[0],
      ]);
    });

    test('the same song can be added again; the old entry stays', () {
      store.addToStack(stack, ids[0]);
      store.addToStack(stack, ids[1]);
      store.addToStack(stack, ids[0]);
      expect(store.stackEntries(stack).map((e) => e.trackId), [
        ids[0],
        ids[1],
        ids[0],
      ]);
      expect(store.stacks().single.entryCount, 3);
    });

    test('removing one entry keeps other entries of the same song', () {
      final older = store.addToStack(stack, ids[0]);
      store.addToStack(stack, ids[1]);
      final newer = store.addToStack(stack, ids[0]);
      store.removeStackEntry(older);
      expect(store.stackEntries(stack).map((e) => e.id), [newer, isNot(older)]);
      expect(store.stackEntries(stack).map((e) => e.trackId), [ids[0], ids[1]]);
    });

    test('stacks are separate lists', () {
      final other = store.createStack('Run');
      store.addToStack(stack, ids[0]);
      store.addToStack(other, ids[1]);
      expect(store.stackEntries(stack).map((e) => e.trackId), [ids[0]]);
      expect(store.stackEntries(other).map((e) => e.trackId), [ids[1]]);
      expect(store.stacks().map((s) => s.name), ['Вечер', 'Run']);
    });
  });

  group('favorites', () {
    late List<int> ids;
    setUp(() {
      ids = store.upsertAll(vk, [
        song('1_1', 'Кино', 'Группа крови'),
        song('1_2', 'Земфира', 'Хочешь?'),
        song('1_3', 'Сплин', 'Выхода нет'),
      ]);
    });

    test('are listed newest first, with the date each was added', () {
      store.addFavorite(ids[1], atMs: 100);
      store.addFavorite(ids[0], atMs: 300);
      store.addFavorite(ids[2], atMs: 200);
      expect(store.favorites(), [
        (trackId: ids[0], addedAtMs: 300),
        (trackId: ids[2], addedAtMs: 200),
        (trackId: ids[1], addedAtMs: 100),
      ]);
    });

    test('adding a favorite again keeps its first date', () {
      store.addFavorite(ids[0], atMs: 100);
      store.addFavorite(ids[0], atMs: 900);
      expect(store.favorites(), [(trackId: ids[0], addedAtMs: 100)]);
    });

    test('removing takes only that song out', () {
      store.addFavorite(ids[0], atMs: 1);
      store.addFavorite(ids[1], atMs: 2);
      store.removeFavorite(ids[0]);
      store.removeFavorite(ids[2]);
      expect(store.favorites(), [(trackId: ids[1], addedAtMs: 2)]);
    });

    test('a sync that marks the song gone keeps the favorite', () {
      store.addFavorite(ids[0], atMs: 1);
      store.markGone(vk, ['1_1']);
      expect(store.favorites().single.trackId, ids[0]);
      expect(store.loadAll().firstWhere((t) => t.id == ids[0]).isGone, isTrue);
    });
  });

  group('settings', () {
    test('settings are read, overwritten and removed', () {
      expect(store.readSetting('theme'), isNull);
      store.writeSetting('theme', 'dark');
      store.writeSetting('theme', 'light');
      expect(store.readSetting('theme'), 'light');
      store.writeSetting('theme', null);
      expect(store.readSetting('theme'), isNull);
    });
  });
}
