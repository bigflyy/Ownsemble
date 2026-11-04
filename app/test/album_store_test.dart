import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'library_migration_test.dart' show dropVersion5;

/// A VK song of album [albumKey] ("ownerId_albumId"), as a sync stores it.
NewTrack albumSong(
  String key,
  String title, {
  String? albumKey,
  String? albumAccess,
  int? trackId,
  int addedAt = 0,
}) => NewTrack(
  sourceKey: key,
  artist: 'Дайте танк (!)',
  title: title,
  album: albumKey == null ? null : 'Человеко-часы',
  durationSec: 200,
  addedAt: addedAt,
  vkTrackId: trackId,
  vkAlbumKey: albumKey,
  vkAlbumAccessKey: albumAccess,
);

void main() {
  group('VK items', () {
    test('keep the link of their album, whatever its title', () {
      final named = vkItemToTrack({
        'owner_id': 1,
        'id': 1,
        'album': {
          'id': 77,
          'owner_id': -2000,
          'access_key': 'album-key',
          'title': 'Человеко-часы',
        },
      });
      expect(named.vkAlbumKey, '-2000_77');
      expect(named.vkAlbumAccessKey, 'album-key');

      // "unnamed" and empty titles are real albums too.
      final unnamed = vkItemToTrack({
        'owner_id': 1,
        'id': 2,
        'album': {'id': 8, 'owner_id': -3, 'title': 'unnamed'},
      });
      expect(unnamed.vkAlbumKey, '-3_8');
      expect(unnamed.vkAlbumAccessKey, isNull);
    });

    test('without an album, or one without an id, have no link', () {
      expect(vkItemToTrack({'owner_id': 1, 'id': 1}).vkAlbumKey, isNull);
      final noId = vkItemToTrack({
        'owner_id': 1,
        'id': 1,
        'album': {'title': 'Альбом', 'access_key': 'k'},
      });
      expect(noId.vkAlbumKey, isNull);
      expect(noId.vkAlbumAccessKey, isNull);
    });
  });

  group('store', () {
    late LibraryStore store;
    late int first;
    late int second;
    setUp(() {
      store = LibraryStore.open(':memory:');
      first = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      second = store.ensureSource(TrackSource.vk, account: '2', name: 'VK');
    });
    tearDown(() => store.close());

    test('a song names its album link, and the album its songs', () {
      final ids = store.upsertAll(first, [
        albumSong(
          '1_1',
          'Профессионал',
          albumKey: '-5_9',
          albumAccess: 'a',
          addedAt: 1,
        ),
        albumSong('1_2', 'Люди', albumKey: '-5_9', addedAt: 3),
        albumSong('1_3', 'Чужая', albumKey: '-6_1', addedAt: 2),
        albumSong('1_4', 'Без альбома'),
      ]);
      expect(store.vkAlbumOf(ids[0]), (
        sourceId: first,
        key: '-5_9',
        accessKey: 'a',
      ));
      expect(store.vkAlbumOf(ids[3]), isNull);
      // Library order: newest first.
      expect(store.listedIdsInVkAlbum('-5_9'), [ids[1], ids[0]]);
      expect(store.listedIdsInVkAlbum('-7_7'), isEmpty);
    });

    test('a merged song is found through its copy\'s album link', () {
      // The listed row has no link yet; the other account's copy has one.
      final listed = store.upsertAll(first, [
        albumSong('1_1', 'Люди', trackId: 42),
      ]).single;
      store.upsertAll(second, [
        albumSong(
          '2_1',
          'Люди',
          trackId: 42,
          albumKey: '-5_9',
          albumAccess: 'b',
        ),
      ]);
      expect(store.mergeSameSongs().merged, 1);

      expect(store.vkAlbumOf(listed), (
        sourceId: second,
        key: '-5_9',
        accessKey: 'b',
      ));
      expect(store.listedIdsInVkAlbum('-5_9'), [listed]);
      expect(store.listedIdsByVkTrackId([42, 99]), {42: listed});
    });

    test('the listed song\'s own link wins over a copy\'s', () {
      final listed = store.upsertAll(first, [
        albumSong(
          '1_1',
          'Люди',
          trackId: 42,
          albumKey: '-5_9',
          albumAccess: 'own',
        ),
      ]).single;
      store.upsertAll(second, [
        albumSong(
          '2_1',
          'Люди',
          trackId: 42,
          albumKey: '-5_9',
          albumAccess: 'copy',
        ),
      ]);
      store.mergeSameSongs();
      expect(store.vkAlbumOf(listed)?.accessKey, 'own');
      expect(store.vkAlbumOf(listed)?.sourceId, first);
    });

    test('songs are found by VK track id, in chunks past 500', () {
      final ids = store.upsertAll(first, [
        for (var i = 0; i < 1200; i++)
          albumSong('1_$i', 'Песня $i', trackId: 10000 + i),
      ]);
      final found = store.listedIdsByVkTrackId([
        for (var i = 0; i < 1200; i++) 10000 + i,
        5,
      ]);
      expect(found.length, 1200);
      expect(found[10000], ids[0]);
      expect(found[11199], ids[1199]);
      expect(store.listedIdsByVkTrackId(const []), isEmpty);
    });

    test('a sync fills album links in quietly, without a change', () {
      final id = store.upsertAll(first, [albumSong('1_1', 'Люди')]).single;
      // The same song, now with its album link: not a change the list shows.
      final linked = albumSong(
        '1_1',
        'Люди',
        albumKey: '-5_9',
        albumAccess: 'a',
      );
      final withoutLink = NewTrack(
        sourceKey: linked.sourceKey,
        artist: linked.artist,
        title: linked.title,
        durationSec: linked.durationSec,
        addedAt: linked.addedAt,
      );
      expect(store.upsertTracks(first, [withoutLink]).changedIds, isEmpty);
      store.updateQuietDetails(first, [linked]);
      expect(store.vkAlbumOf(id)?.key, '-5_9');
      expect(store.vkAlbumOf(id)?.accessKey, 'a');
    });
  });

  test('version 4 gains album links and keeps its songs', () {
    final dir = Directory.systemTemp.createTempSync('ownsemble_album');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'library.db');
    final old = LibraryStore.open(path);
    final vk = old.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    final id = old.upsertAll(vk, [albumSong('1_1', 'Люди')]).single;
    old.close();
    final db = sqlite3.open(path);
    dropVersion5(db);
    db.execute('PRAGMA user_version = 4');
    db.close();

    final migrated = LibraryStore.open(path);
    addTearDown(migrated.close);
    expect(migrated.loadAll().single.title, 'Люди');
    expect(migrated.vkAlbumOf(id), isNull);
    migrated.updateQuietDetails(vk, [
      albumSong('1_1', 'Люди', albumKey: '-5_9'),
    ]);
    expect(migrated.listedIdsInVkAlbum('-5_9'), [id]);
  });
}
