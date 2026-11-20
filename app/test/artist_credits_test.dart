import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A song of the test account as a sync stores it, with [artists].
NewTrack credited(
  String key,
  String title, {
  String artist = 'Дайте танк (!)',
  List<ArtistCredit> artists = const [],
}) => NewTrack(
  sourceKey: key,
  artist: artist,
  title: title,
  durationSec: 200,
  addedAt: 0,
  artists: artists,
);

const tank = ArtistCredit(vkId: '111', name: 'Дайте танк (!)', domain: 'tank');
const rita = ArtistCredit(
  vkId: '222',
  name: 'Рита Вихрия',
  domain: 'rita',
  featured: true,
);

void main() {
  group('VK items', () {
    test('carry their main, then featured artists, Cyrillic intact', () {
      final song = vkItemToTrack({
        'owner_id': 1,
        'id': 1,
        'artist': 'Дайте танк (!) feat. Рита Вихрия',
        'title': 'Песня',
        'main_artists': [
          {'id': '111', 'name': ' Дайте танк (!) ', 'domain': 'tank'},
        ],
        'featured_artists': [
          {'id': '222', 'name': 'Рита Вихрия', 'domain': 'rita'},
        ],
      });
      expect(song.artists, [tank, rita]);
    });

    test('skip artists without an id or a name, and repeats of one id', () {
      final song = vkItemToTrack({
        'owner_id': 1,
        'id': 1,
        'main_artists': [
          {'name': 'Без id'},
          {'id': '111', 'name': ''},
          {'id': '111', 'name': 'Дайте танк (!)', 'domain': 'tank'},
          {'id': 333, 'name': 'Число вместо текста'},
        ],
        'featured_artists': [
          {'id': '111', 'name': 'Дайте танк (!)'},
        ],
      });
      expect(song.artists, [
        tank,
        const ArtistCredit(vkId: '333', name: 'Число вместо текста'),
      ]);
    });

    test('without artist lists have none', () {
      expect(vkItemToTrack({'owner_id': 1, 'id': 1}).artists, isEmpty);
    });
  });

  group('the store', () {
    late LibraryStore store;
    late int vk;
    setUp(() {
      store = LibraryStore.open(':memory:');
      vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    });
    tearDown(() => store.close());

    test('keeps each row\'s artists in order', () {
      final ids = store.upsertAll(vk, [
        credited('1_1', 'Песня', artists: const [tank, rita]),
        credited('1_2', 'Без артистов'),
      ]);
      expect(store.artistCredits(), {
        ids[0]: [tank, rita],
      });
    });

    test('a sync fills artists in: not a song change, but said apart', () {
      final id = store.upsertAll(vk, [credited('1_1', 'Люди')]).single;
      final filled = store.upsertTracks(vk, [
        credited('1_1', 'Люди', artists: const [tank]),
      ]);
      expect(filled.changedIds, isEmpty);
      expect(filled.creditsChanged, isTrue);
      expect(store.artistCredits()[id], [tank]);

      final again = store.upsertTracks(vk, [
        credited('1_1', 'Люди', artists: const [tank]),
      ]);
      expect(again.creditsChanged, isFalse);
    });

    test('a changed list replaces the old one; an empty one clears it', () {
      final id = store.upsertAll(vk, [
        credited('1_1', 'Песня', artists: const [tank, rita]),
      ]).single;
      expect(
        store.upsertTracks(vk, [
          credited('1_1', 'Песня', artists: const [rita]),
        ]).creditsChanged,
        isTrue,
      );
      expect(store.artistCredits()[id], [rita]);
      expect(
        store.upsertTracks(vk, [credited('1_1', 'Песня')]).creditsChanged,
        isTrue,
      );
      expect(store.artistCredits(), isEmpty);
    });

    test('a found song added with its artists keeps them on the copy', () {
      final found = credited('-5_9', 'Песня', artists: const [tank]);
      final id = store.upsertAll(vk, [
        found.asAddedCopy('1_77', addedAt: 5),
      ]).single;
      expect(store.artistCredits()[id], [tank]);
    });

    test('other cover links keep the artists', () {
      final song = credited('1_1', 'Песня', artists: const [tank]);
      expect(
        song
            .withCovers(
              coverUrl: 'a',
              coverLargeUrl: null,
              coverMidUrl: null,
              coverFullUrl: null,
            )
            .artists,
        [tank],
      );
    });
  });

  test('version 14 gains the artist tables and keeps its songs', () {
    final dir = Directory.systemTemp.createTempSync('ownsemble_artists');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'library.db');
    final old = LibraryStore.open(path);
    final vk = old.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    final id = old.upsertAll(vk, [credited('1_1', 'Люди')]).single;
    old.close();
    final db = sqlite3.open(path);
    db.execute('DROP TABLE track_artists');
    db.execute('DROP TABLE artist_photos');
    db.execute('PRAGMA user_version = 14');
    db.close();

    final migrated = LibraryStore.open(path);
    addTearDown(migrated.close);
    expect(migrated.loadAll().single.title, 'Люди');
    expect(migrated.artistCredits(), isEmpty);
    migrated.upsertTracks(vk, [
      credited('1_1', 'Люди', artists: const [tank]),
    ]);
    expect(migrated.artistCredits()[id], [tank]);
  });

  test('version 15 gains artists on found uploads; lists found before are '
      'searched again', () {
    final dir = Directory.systemTemp.createTempSync('ownsemble_artists');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'library.db');
    final old = LibraryStore.open(path);
    final vk = old.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    final id = old.upsertAll(vk, [credited('1_1', 'Люди')]).single;
    old.saveFoundVersions(id, [
      const SongVersion(
        key: '-5_1',
        artist: 'Дайте танк (!)',
        title: 'Люди',
        listedSec: 200,
      ),
    ], atMs: 1000);
    old.close();
    final db = sqlite3.open(path);
    db.execute('ALTER TABLE found_versions DROP COLUMN artists');
    db.execute('PRAGMA user_version = 15');
    db.close();

    final migrated = LibraryStore.open(path);
    addTearDown(migrated.close);
    final found = migrated.foundVersions(id)!;
    expect(found.versions.single.title, 'Люди');
    expect(found.versions.single.artists, isEmpty);
    expect(found.foundAtMs, 0);
  });
}
