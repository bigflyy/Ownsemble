import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_generator.dart';
import 'package:ownsemble/library/track.dart';
import 'package:path/path.dart' as p;

NewTrack song(String key, String artist, String title, {int addedAt = 0}) =>
    NewTrack(
      source: TrackSource.vk,
      sourceKey: key,
      artist: artist,
      title: title,
      durationSec: 200,
      addedAt: addedAt,
    );

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.open(':memory:'));
  tearDown(() => store.close());

  test('Cyrillic text survives a round trip through a database file', () {
    final dir = Directory.systemTemp.createTempSync('ownsemble_test');
    final path = p.join(dir.path, 'library.db');
    final file = LibraryStore.open(path);
    file.upsertAll([song('1_1', 'Земфира', 'Хочешь? «Ёлка» — всё')]);
    file.close();
    final reopened = LibraryStore.open(path);
    final track = reopened.loadAll().single;
    expect(track.artist, 'Земфира');
    expect(track.title, 'Хочешь? «Ёлка» — всё');
    reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('search folds ё, ignores case and matches word prefixes', () {
    final ids = store.upsertAll([
      song('1_1', 'Ёлка', 'Прованс'),
      song('1_2', 'Кино', 'Звезда по имени Солнце'),
      song('1_3', 'Metallica', 'Nothing Else Matters'),
    ]);
    expect(store.search('елка'), {ids[0]});
    expect(store.search('ЁЛК'), {ids[0]});
    expect(store.search('звезда солн'), {ids[1]});
    expect(store.search('солнце кино'), {ids[1]});
    expect(store.search('meta noth'), {ids[2]});
    expect(store.search('кино metallica'), isEmpty);
    expect(store.search('  '), isNull);
  });

  test('upsert updates an existing song and its search entry', () {
    final first = store.upsertAll([song('1_1', 'Old Name', 'Song')]).single;
    final second = store.upsertAll([song('1_1', 'Новое Имя', 'Song')]).single;
    expect(second, first);
    expect(store.count(), 1);
    expect(store.search('old'), isEmpty);
    expect(store.search('новое'), {first});
  });

  test('loadAll lists the newest songs first', () {
    store.upsertAll([
      song('1_1', 'A', 'old', addedAt: 100),
      song('1_2', 'B', 'new', addedAt: 300),
      song('1_3', 'C', 'middle', addedAt: 200),
    ]);
    expect(store.loadAll().map((t) => t.title), ['new', 'middle', 'old']);
  });

  test('local path is kept when a sync does not know it', () {
    final id = store.upsertAll([song('1_1', 'A', 'B')]).single;
    store.setLocalPath(id, r'C:\cache\Песня.mp3');
    store.upsertAll([song('1_1', 'A', 'B')]);
    expect(store.loadAll().single.localPath, r'C:\cache\Песня.mp3');
  });

  test('generated library is deterministic, searchable and playable', () {
    final songs = generateSongs(2000, audioFiles: ['a.mp3', 'b.mp3']);
    expect(generateSongs(2000).map((s) => s.title), songs.map((s) => s.title));
    store.upsertAll(songs);
    expect(store.count(), 2000);
    expect(store.search('елка')!.length, greaterThan(0));
    expect(store.loadAll().every((t) => t.isCached), isTrue);
  });
}
