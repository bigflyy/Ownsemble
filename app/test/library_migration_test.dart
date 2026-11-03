import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_schema.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Takes back what version 4 added, for tests that rebuild an older library
/// from a new one.
void dropVersion4(Database db) {
  db.execute('DROP INDEX tracks_copies');
  db.execute('ALTER TABLE tracks DROP COLUMN same_as');
  db.execute('ALTER TABLE tracks DROP COLUMN vk_track_id');
  db.execute('ALTER TABLE sources DROP COLUMN color');
  db.execute('ALTER TABLE sources DROP COLUMN removed_at_ms');
}

/// Writes a library in the speed-gate format (schema version 0).
void writeGateLibrary(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE tracks (
      id INTEGER PRIMARY KEY,
      source TEXT NOT NULL,
      source_key TEXT,
      access_key TEXT,
      artist TEXT NOT NULL,
      title TEXT NOT NULL,
      album TEXT,
      duration_sec INTEGER NOT NULL,
      added_at INTEGER NOT NULL,
      local_path TEXT,
      UNIQUE (source, source_key)
    )
  ''');
  db.execute('CREATE INDEX tracks_by_added ON tracks (added_at DESC, id DESC)');
  final cached = p.join('cache', 'vk_1_10.mp3');
  final insert = db.prepare('''
    INSERT INTO tracks (id, source, source_key, access_key, artist, title,
                        album, duration_sec, added_at, local_path)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ''');
  insert.execute([
    5, 'vk', '1_10', 'key', 'Кино', 'Звезда по имени Солнце', 'Звезда', //
    225, 300, cached,
  ]);
  insert.execute([
    6, 'vk', '1_11', null, 'Сплин', 'Выхода нет', null, 236, 200, //
    p.join('cache', 'missing.mp3'),
  ]);
  insert.execute([
    7, 'generated', 'gen-2026-0', null, 'Группа Ёж', 'Ёлка', null, 180, //
    100, cached,
  ]);
  insert.close();
  db.close();
}

void main() {
  late Directory dir;
  late String dbPath;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ownsemble_migration');
    dbPath = p.join(dir.path, 'library.db');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  int versionOf(String path) {
    final db = sqlite3.open(path);
    try {
      return db.select('PRAGMA user_version').first.values.first as int;
    } finally {
      db.close();
    }
  }

  test('a new library starts at the current version', () {
    LibraryStore.open(dbPath).close();
    expect(versionOf(dbPath), librarySchemaVersion);
  });

  test('the speed-gate library moves over with ids, text and files', () {
    writeGateLibrary(dbPath);
    final audio = File(p.join(dir.path, 'cache', 'vk_1_10.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(1234, 0));

    final store = LibraryStore.open(dbPath);
    addTearDown(store.close);
    expect(versionOf(dbPath), librarySchemaVersion);

    final tracks = {for (final t in store.loadAll()) t.id: t};
    expect(tracks.keys, [5, 6, 7]);
    expect(tracks[5]!.title, 'Звезда по имени Солнце');
    expect(tracks[5]!.album, 'Звезда');
    expect(tracks[5]!.accessKey, 'key');
    expect(tracks[7]!.artist, 'Группа Ёж');

    // The existing file is kept as plain cache; the missing one is dropped.
    expect(tracks[5]!.localPath, p.join('cache', 'vk_1_10.mp3'));
    expect(tracks[5]!.isDownloaded, isFalse);
    expect(tracks[6]!.isCached, isFalse);
    // Filler songs borrow that file and are pinned so it is never evicted.
    expect(tracks[7]!.localPath, p.join('cache', 'vk_1_10.mp3'));
    expect(tracks[7]!.isDownloaded, isTrue);
    expect(audio.existsSync(), isTrue);

    final sources = {for (final s in store.sources()) s.kind: s};
    expect(sources[TrackSource.vk]!.account, isNull);
    expect(sources[TrackSource.vk]!.songCount, 2);
    expect(sources[TrackSource.generated]!.account, 'generator');
    expect(tracks[5]!.sourceId, sources[TrackSource.vk]!.id);

    // The first sync of the test account takes over the carried-over songs.
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    expect(vk, sources[TrackSource.vk]!.id);
    expect(
      store.upsertAll(vk, [
        const NewTrack(
          sourceKey: '1_10',
          artist: 'Кино',
          title: 'Звезда по имени Солнце',
          durationSec: 225,
          addedAt: 300,
        ),
      ]),
      [5],
    );
  });

  test('opening an upgraded library again changes nothing', () {
    writeGateLibrary(dbPath);
    LibraryStore.open(dbPath).close();
    final store = LibraryStore.open(dbPath);
    addTearDown(store.close);
    expect(store.count(), 3);
    expect(store.sources(), hasLength(2));
  });

  test('version 1 gains the cover sizes and keeps its songs', () {
    // A current library taken back to version 1.
    final store = LibraryStore.open(dbPath);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 236,
        addedAt: 5,
        coverUrl: 'https://example.invalid/135.jpg',
      ),
    ]);
    store.close();
    final db = sqlite3.open(dbPath);
    db.execute('ALTER TABLE tracks DROP COLUMN cover_mid_url');
    db.execute('ALTER TABLE tracks DROP COLUMN cover_full_url');
    db.execute('DROP TABLE vk_album_titles');
    dropVersion4(db);
    db.execute('PRAGMA user_version = 1');
    db.close();

    final migrated = LibraryStore.open(dbPath);
    addTearDown(migrated.close);
    expect(versionOf(dbPath), librarySchemaVersion);
    final track = migrated.loadAll().single;
    expect(track.title, 'Выхода нет');
    expect(track.coverUrl, 'https://example.invalid/135.jpg');
    expect(track.coverMidUrl, isNull);
    expect(track.coverFullUrl, isNull);
  });

  test('version 2 gains the album titles and keeps its songs', () {
    // A current library taken back to version 2.
    final store = LibraryStore.open(dbPath);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Сплин',
        title: 'Выхода нет',
        album: 'unnamed',
        durationSec: 236,
        addedAt: 5,
      ),
    ]);
    store.close();
    final db = sqlite3.open(dbPath);
    db.execute('DROP TABLE vk_album_titles');
    dropVersion4(db);
    db.execute('PRAGMA user_version = 2');
    db.close();

    final migrated = LibraryStore.open(dbPath);
    addTearDown(migrated.close);
    expect(versionOf(dbPath), librarySchemaVersion);
    expect(migrated.loadAll().single.title, 'Выхода нет');
    expect(migrated.vkAlbumTitles(), isEmpty);

    migrated.saveVkAlbumTitle('-2_7', 'Молодость и панк-рок');
    expect(migrated.vkAlbumTitles(), {'-2_7': 'Молодость и панк-рок'});
  });

  test('a library from a newer build is refused and left alone', () {
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA user_version = ${librarySchemaVersion + 1}');
    db.close();
    expect(
      () => LibraryStore.open(dbPath),
      throwsA(isA<NewerLibraryException>()),
    );
    expect(versionOf(dbPath), librarySchemaVersion + 1);
  });
}
