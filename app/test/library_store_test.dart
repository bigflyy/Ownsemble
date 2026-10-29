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
          tint: 0xFF8A2BE2,
        ),
      ]);
      final track = store.loadAll().single;
      expect(track.album, 'Альбом');
      expect(track.coverUrl, 'https://example.invalid/135.jpg');
      expect(track.coverLargeUrl, 'https://example.invalid/600.jpg');
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
