import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';

/// One song on the fake VK.
class FakeSong {
  const FakeSong(this.id, this.title, {this.blocked = false});

  final int id;
  final String title;

  /// Blocked songs have no stream and are hidden from paged replies.
  final bool blocked;

  Map<String, dynamic> toItem() => {
    'owner_id': FakeVk.userId,
    'id': id,
    'access_key': 'k$id',
    'artist': 'Исполнитель',
    'title': title,
    'duration': 200,
    'date': 1000 + id,
    'url': blocked ? '' : 'https://example.invalid/$id.mp3',
  };
}

/// VK as the test account showed it (2026-10-30): one big page returns
/// blocked songs without a stream, paged replies leave them out but count
/// them, and `audio.getById` finds every song that still exists on VK.
class FakeVk {
  static const userId = 42;

  /// The account's library, newest first.
  final library = <FakeSong>[];

  /// Songs that exist on VK but are not in the library.
  final elsewhere = <FakeSong>[];

  Object? failWith;
  void Function(int offset)? onPage;

  /// Builds the items VK returns, when a test needs other fields.
  Map<String, dynamic> Function(FakeSong song)? itemOverride;
  int audioGetCalls = 0;
  int getByIdCalls = 0;

  /// What `audio.getPlaylistById` answers, by "ownerId_albumId".
  final albums = <String, Object>{};

  /// Every `audio.getPlaylistById` request, with its parameters.
  final albumRequests = <Map<String, String>>[];

  Map<String, dynamic> item(FakeSong song) =>
      itemOverride?.call(song) ?? song.toItem();

  FakeSong song(int id, {String? title, bool blocked = false}) =>
      FakeSong(id, title ?? 'Песня $id', blocked: blocked);

  Future<Object?> call(String method, Map<String, String> params) async {
    if (failWith != null) throw failWith!;
    switch (method) {
      case 'audio.get':
        audioGetCalls++;
        final offset = int.parse(params['offset']!);
        final count = int.parse(params['count']!);
        onPage?.call(offset);
        final paged = count < library.length;
        return {
          'count': library.length,
          'items': [
            for (final song in library.skip(offset).take(count))
              if (!(paged && song.blocked)) item(song),
          ],
        };
      case 'audio.getById':
        getByIdCalls++;
        final wanted = params['audios']!
            .split(',')
            .map((id) => id.split('_').take(2).join('_'))
            .toSet();
        return [
          for (final song in [...library, ...elsewhere])
            if (wanted.contains('${userId}_${song.id}')) item(song),
        ];
      case 'audio.getPlaylistById':
        albumRequests.add(params);
        final answer =
            albums['${params['owner_id']}_${params['playlist_id']}'] ??
            VkException('audio.getPlaylistById error 100: no such album');
        if (answer is String) return {'title': answer, 'count': 3};
        throw answer;
    }
    throw StateError('unexpected $method');
  }
}

/// Fake `audio.get` over [total] songs where the ids in [blocked] are counted
/// but never returned, as VK does.
Future<Object?> Function(String, Map<String, String>) fakeAudioGet(
  int total,
  Set<int> blocked,
  List<int> offsetsSeen,
) {
  return (method, params) async {
    expect(method, 'audio.get');
    final offset = int.parse(params['offset']!);
    final count = int.parse(params['count']!);
    offsetsSeen.add(offset);
    return {
      'count': total,
      'items': [
        for (var id = offset; id < offset + count && id < total; id++)
          if (!blocked.contains(id))
            {'owner_id': 5, 'id': id, 'artist': 'A', 'title': 'T $id'},
      ],
    };
  };
}

void main() {
  test(
    'offset advances by page size even when pages omit blocked songs',
    () async {
      final offsets = <int>[];
      final library = await fetchVkLibrary(
        fakeAudioGet(126, {3, 60, 125}, offsets),
        5,
        pageSize: 50,
      );
      expect(offsets, [0, 50, 100]);
      expect(library.pages, 3);
      expect(library.declaredCount, 126);
      expect(library.items.length, 123);
      expect(library.items.map(vkSourceKey).toSet().length, 123);
    },
  );

  test('a page made only of blocked songs does not stop the sync', () async {
    final offsets = <int>[];
    final library = await fetchVkLibrary(
      fakeAudioGet(30, {for (var i = 10; i < 20; i++) i}, offsets),
      5,
      pageSize: 10,
    );
    expect(offsets, [0, 10, 20]);
    expect(library.items.length, 20);
  });

  test('an empty library takes one request', () async {
    final offsets = <int>[];
    final library = await fetchVkLibrary(fakeAudioGet(0, {}, offsets), 5);
    expect(offsets, [0]);
    expect(library.items, isEmpty);
  });

  test('VK items become library songs with trimmed Cyrillic text', () {
    final track = vkItemToTrack({
      'owner_id': -2001,
      'id': 77,
      'access_key': 'k',
      'artist': ' Сплин ',
      'title': 'Выхода нет ',
      'duration': 236,
      'date': 1700000000,
      'album': {'title': 'Альбом'},
    });
    expect(track.sourceKey, '-2001_77');
    expect(track.accessKey, 'k');
    expect(track.artist, 'Сплин');
    expect(track.title, 'Выхода нет');
    expect(track.album, 'Альбом');
    expect(track.durationSec, 236);
    expect(track.coverUrl, isNull);
  });

  test('covers come from the song thumb, else from the album', () {
    Map<String, String> thumb(String name) => {
      'photo_34': '$name-34',
      'photo_135': '$name-135',
      'photo_300': '$name-300',
      'photo_600': '$name-600',
      'photo_1200': '$name-1200',
    };
    final own = vkItemToTrack({
      'owner_id': 1,
      'id': 1,
      'thumb': thumb('song'),
      'album': {'title': 'Альбом', 'thumb': thumb('album')},
      'main_color': '#1a2B3c',
    });
    expect(own.coverUrl, 'song-135');
    expect(own.coverLargeUrl, 'song-600');
    expect(own.coverMidUrl, 'song-300');
    expect(own.coverFullUrl, 'song-1200');
    expect(own.tint, 0xFF1A2B3C);

    final albumOnly = vkItemToTrack({
      'owner_id': 1,
      'id': 2,
      'album': {'title': 'Альбом', 'thumb': thumb('album')},
    });
    expect(albumOnly.coverUrl, 'album-135');
    expect(albumOnly.tint, isNull);

    // VK's generic placeholder: a thumb on a song without an album.
    final noAlbum = vkItemToTrack({
      'owner_id': 1,
      'id': 3,
      'thumb': thumb('placeholder'),
      'main_color': '#1a2B3c',
    });
    expect(noAlbum.coverUrl, isNull);
    expect(noAlbum.coverLargeUrl, isNull);

    // Withdrawn songs: an album with no title, and the same placeholder.
    final untitledAlbum = vkItemToTrack({
      'owner_id': 1,
      'id': 4,
      'thumb': thumb('placeholder'),
      'album': {'title': ' '},
    });
    expect(untitledAlbum.coverUrl, isNull);
  });

  group('album names', () {
    Map<String, dynamic> songOf(Map<String, dynamic> album) => {
      'owner_id': 1,
      'id': 1,
      'album': album,
      'thumb': {'photo_135': 'cover-135'},
    };
    const unnamed = {'id': 7, 'owner_id': -2, 'title': 'unnamed'};

    test('"unnamed" is not a name, and its song keeps its real cover', () {
      final track = vkItemToTrack(songOf(unnamed));
      expect(track.album, isNull);
      expect(track.coverUrl, 'cover-135');
    });

    test('the real title of an "unnamed" album is shown', () {
      final track = vkItemToTrack(
        songOf(unnamed),
        albumTitles: {'-2_7': 'Молодость и панк-рок'},
      );
      expect(track.album, 'Молодость и панк-рок');
    });

    test('a title VK gives on the song wins over a stored one', () {
      final track = vkItemToTrack(
        songOf({'id': 7, 'owner_id': -2, 'title': 'Новое имя'}),
        albumTitles: {'-2_7': 'Старое имя'},
      );
      expect(track.album, 'Новое имя');
    });

    test('an empty title and no album object both show nothing', () {
      expect(vkItemToTrack(songOf({'title': ' '})).album, isNull);
      expect(vkItemToTrack({'owner_id': 1, 'id': 1}).album, isNull);
    });
  });

  group('syncVkSource', () {
    late LibraryStore store;
    late FakeVk vk;
    setUp(() {
      store = LibraryStore.open(':memory:');
      vk = FakeVk();
    });
    tearDown(() => store.close());

    Future<VkSyncResult> sync({int pageSize = 200}) => syncVkSource(
      call: vk.call,
      userId: FakeVk.userId,
      store: store,
      pageSize: pageSize,
      albumGap: Duration.zero,
    );

    Track byKey(String key) =>
        store.loadAll().firstWhere((t) => t.sourceKey == key);

    /// Makes [songs] the library, with each song's album from [albumOf].
    void useAlbums(
      List<FakeSong> songs,
      Map<String, dynamic> Function(FakeSong song) albumOf,
    ) {
      vk.library.addAll(songs);
      vk.itemOverride = (song) => song.toItem()..['album'] = albumOf(song);
    }

    Map<String, dynamic> unnamedAlbum(int id, {String key = 'albumkey'}) => {
      'id': id,
      'owner_id': -2,
      'access_key': key,
      'title': 'unnamed',
    };

    group('album titles', () {
      test('the first sync shows the songs and leaves the titles', () async {
        useAlbums([vk.song(1)], (_) => unnamedAlbum(7));
        vk.albums['-2_7'] = 'Байполар';
        final result = await sync();
        expect(result.added, 1);
        expect(result.albumsSkipped, 1);
        expect(vk.albumRequests, isEmpty);
        expect(byKey('42_1').album, isNull);
      });

      test('the next sync asks once per album and stores the title', () async {
        useAlbums([
          vk.song(1),
          vk.song(2),
          vk.song(3),
        ], (song) => unnamedAlbum(song.id == 3 ? 8 : 7));
        vk.albums['-2_7'] = 'Байполар';
        vk.albums['-2_8'] = 'Молодость и панк-рок';
        await sync();

        final result = await sync();
        expect(result.updated, 3);
        expect(result.albumsSkipped, 0);
        expect(vk.albumRequests, hasLength(2));
        expect(vk.albumRequests.first, {
          'owner_id': '-2',
          'playlist_id': '7',
          'access_key': 'albumkey',
        });
        expect(byKey('42_1').album, 'Байполар');
        expect(byKey('42_2').album, 'Байполар');
        expect(byKey('42_3').album, 'Молодость и панк-рок');

        // The titles are kept: no more questions and nothing to reload.
        final third = await sync();
        expect(third.changedLibrary, isFalse);
        expect(vk.albumRequests, hasLength(2));
      });

      test('a new access key of the album does not ask again', () async {
        var key = 'first';
        useAlbums([vk.song(1)], (_) => unnamedAlbum(7, key: key));
        vk.albums['-2_7'] = 'Байполар';
        await sync();
        await sync();
        key = 'second';
        await sync();
        expect(vk.albumRequests, hasLength(1));
        expect(byKey('42_1').album, 'Байполар');
      });

      test('an album with a name of its own is not asked about', () async {
        useAlbums([vk.song(1)], (_) => {'id': 7, 'title': 'Альбом'});
        await sync();
        await sync();
        expect(vk.albumRequests, isEmpty);
        expect(byKey('42_1').album, 'Альбом');
      });

      test('a refused album is skipped and asked again next time', () async {
        useAlbums([
          vk.song(1),
          vk.song(2),
        ], (song) => unnamedAlbum(song.id == 1 ? 7 : 8));
        vk.albums['-2_8'] = 'Байполар';
        await sync();

        final result = await sync();
        expect(result.updated, 1);
        expect(store.sources().single.lastSyncError, isNull);
        expect(byKey('42_1').album, isNull);
        expect(byKey('42_2').album, 'Байполар');

        vk.albums['-2_7'] = 'Молодость';
        await sync();
        expect(byKey('42_1').album, 'Молодость');
        expect(vk.albumRequests, hasLength(3));
      });

      test('a dead line stops the lookups, not the sync', () async {
        useAlbums([
          vk.song(1),
          vk.song(2),
          vk.song(3),
        ], (song) => unnamedAlbum(song.id));
        vk.albums['-2_1'] = 'Первый';
        vk.albums['-2_2'] = VkException('stalled', transient: true);
        vk.albums['-2_3'] = 'Третий';
        await sync();

        final result = await sync();
        expect(vk.albumRequests, hasLength(2), reason: 'stopped at the second');
        expect(result.updated, 1);
        expect(store.sources().single.lastSyncError, isNull);
        expect(byKey('42_1').album, 'Первый');

        vk.albums['-2_2'] = 'Второй';
        await sync();
        expect(byKey('42_2').album, 'Второй');
        expect(byKey('42_3').album, 'Третий');
        expect(vk.albumRequests, hasLength(4), reason: 'the first is kept');
      });

      test('an album reply without a title stays unknown', () async {
        useAlbums([vk.song(1)], (_) => unnamedAlbum(7));
        vk.albums['-2_7'] = '  ';
        await sync();
        await sync();
        expect(store.vkAlbumTitles(), isEmpty);
        expect(byKey('42_1').album, isNull);
      });
    });

    test('the first sync adds every listed song with Cyrillic text', () async {
      vk.library.addAll([
        vk.song(1, title: 'Звезда по имени Солнце'),
        vk.song(2),
        vk.song(3, blocked: true),
      ]);
      final result = await sync();
      expect(result.added, 3);
      expect(result.newlyGone, 0);
      expect(result.changedLibrary, isTrue);
      expect(
        store.loadAll().map((t) => t.title),
        contains('Звезда по имени Солнце'),
      );
      final source = store.sources().single;
      expect(source.account, '${FakeVk.userId}');
      expect(source.lastSyncAtMs, isNotNull);
      expect(source.lastSyncError, isNull);
    });

    test('a second sync with no changes writes nothing', () async {
      vk.library.addAll([vk.song(1), vk.song(2)]);
      await sync();
      final again = await sync();
      expect(again.changedLibrary, isFalse);
      expect(
        [again.added, again.updated, again.back, again.newlyGone],
        [0, 0, 0, 0],
      );
    });

    test('a cover served from another host is not a change', () async {
      Map<String, dynamic> withCover(FakeSong song, String host, String sign) =>
          song.toItem()
            ..['album'] = {'title': 'Альбом'}
            ..['thumb'] = {
              'photo_135': 'https://$host/c/1.jpg?size=135&sign=$sign',
              'photo_300': 'https://$host/c/1.jpg?size=300&sign=$sign',
              'photo_600': 'https://$host/c/1.jpg?size=600&sign=$sign',
              'photo_1200': 'https://$host/c/1.jpg?size=1200&sign=$sign',
            };
      final first = vk.song(1);
      vk.itemOverride = (song) => withCover(song, 'img1.example', 'a');
      vk.library.add(first);
      await sync();
      vk.itemOverride = (song) => withCover(song, 'img7.example', 'a');
      expect((await sync()).changedLibrary, isFalse);
      // Not every host has every image, so the newest host is kept: a cover
      // that could not be had gets another chance with the next start.
      final moved = byKey('${FakeVk.userId}_1');
      expect(moved.coverUrl, contains('img7.example'));
      expect(moved.coverMidUrl, contains('img7.example'));
      expect(moved.coverLargeUrl, contains('img7.example'));
      expect(moved.coverFullUrl, contains('img7.example'));

      vk.itemOverride = (song) => withCover(song, 'img7.example', 'b');
      expect((await sync()).updated, 1, reason: 'a new image is a change');
      expect(byKey('${FakeVk.userId}_1').coverUrl, contains('sign=b'));
      expect(byKey('${FakeVk.userId}_1').coverFullUrl, contains('sign=b'));
    });

    test('a renamed song counts as updated, not added', () async {
      vk.library.addAll([vk.song(1), vk.song(2)]);
      await sync();
      vk.library[1] = vk.song(2, title: 'Новое название');
      final result = await sync();
      expect(result.added, 0);
      expect(result.updated, 1);
      expect(byKey('${FakeVk.userId}_2').title, 'Новое название');
    });

    test('a song removed from a fully listed library is marked gone, kept '
        'and comes back when re-added', () async {
      vk.library.addAll([vk.song(1), vk.song(2), vk.song(3)]);
      await sync();
      final removed = vk.library.removeAt(1);
      vk.elsewhere.add(removed); // still exists on VK, just not in the library
      final result = await sync();
      expect(result.newlyGone, 1);
      expect(vk.getByIdCalls, 0, reason: 'nothing hidden, no lookup needed');
      expect(byKey('${FakeVk.userId}_2').isGone, isTrue);
      expect(store.count(), 3);
      expect(store.sources().single.goneCount, 1);

      expect((await sync()).newlyGone, 0, reason: 'marked once');

      vk.library.insert(0, removed);
      final back = await sync();
      expect(back.back, 1);
      expect(back.added, 0);
      expect(byKey('${FakeVk.userId}_2').isGone, isFalse);
    });

    test('when VK hides blocked songs, only songs it really lost are marked '
        'gone', () async {
      // Page size 2 makes VK page, and paged replies hide blocked songs.
      vk.library.addAll([
        vk.song(1),
        vk.song(2, blocked: true),
        vk.song(3),
        vk.song(4),
        vk.song(5),
      ]);
      await sync(pageSize: 200);
      expect(store.count(), 5);

      final deleted = vk.library.removeAt(3); // song 4: deleted from VK
      final removed = vk.library.removeAt(3); // song 5: removed from library
      vk.elsewhere.add(removed);
      vk.elsewhere.add(vk.song(6)); // unrelated song on VK
      expect(deleted.id, 4);

      final result = await sync(pageSize: 2);
      expect(vk.getByIdCalls, greaterThan(0));
      expect(result.listed, 2);
      expect(result.declared, 3);
      expect(result.newlyGone, 2);
      expect(byKey('${FakeVk.userId}_2').isGone, isFalse, reason: 'blocked');
      expect(byKey('${FakeVk.userId}_4').isGone, isTrue, reason: 'deleted');
      expect(byKey('${FakeVk.userId}_5').isGone, isTrue, reason: 'removed');
    });

    test('a removed blocked song is gone when VK hides nothing', () async {
      vk.library.addAll([vk.song(1), vk.song(2, blocked: true)]);
      await sync();
      vk.elsewhere.add(vk.library.removeAt(1));
      expect((await sync()).newlyGone, 1);
    });

    test('gone checks run in batches', () async {
      vk.library.addAll([for (var i = 0; i < 120; i++) vk.song(i)]);
      vk.library.add(vk.song(999, blocked: true));
      await sync();
      vk.library.removeRange(0, 120);
      final checked = <int>[];
      final known = store.trackKeys(store.sources().single.id);
      await findGoneKeys(
        vk.call,
        {
          for (final e in known.entries)
            if (!e.key.endsWith('_999')) e.key: e.value.accessKey,
        },
        vkHidSongs: true,
        batchSize: 50,
        onChecked: (done, total) => checked.add(done),
      );
      expect(vk.getByIdCalls, 3);
      expect(checked, [50, 100, 120]);
    });

    test('a failed sync records why and marks nothing gone', () async {
      vk.library.addAll([vk.song(1), vk.song(2)]);
      await sync();
      vk.library.clear();
      vk.failWith = VkException('audio.get error 5: User authorization failed');
      await expectLater(sync(), throwsA(isA<VkException>()));
      final source = store.sources().single;
      expect(source.lastSyncError, contains('authorization failed'));
      expect(source.goneCount, 0);

      vk.failWith = null;
      vk.library.addAll([vk.song(1), vk.song(2)]);
      await sync();
      expect(store.sources().single.lastSyncError, isNull);
    });

    test('a library that changes while it is read is read again', () async {
      vk.library.addAll([for (var i = 0; i < 5; i++) vk.song(i)]);
      vk.onPage = (offset) {
        // A song is added on VK right after the first page was read.
        if (offset == 2 && vk.library.length == 5) {
          vk.library.insert(0, vk.song(100));
        }
      };
      final result = await sync(pageSize: 2);
      expect(result.listed, 6);
      expect(result.added, 6);
      expect(vk.audioGetCalls, 2 + 3, reason: 'two pages, then a full read');
    });

    test('progress goes from reading pages to saving', () async {
      vk.library.addAll([for (var i = 0; i < 5; i++) vk.song(i)]);
      final seen = <SyncProgress>[];
      await syncVkSource(
        call: vk.call,
        userId: FakeVk.userId,
        store: store,
        pageSize: 2,
        onProgress: seen.add,
      );
      expect(seen.first.stage, SyncStage.reading);
      expect(seen.last.stage, SyncStage.saving);
      final pages = seen.where((p) => p.done > 0).map((p) => p.done);
      expect(pages, [1, 2, 3]);
      final fractions = seen.map((p) => p.fraction).toList();
      expect(fractions, orderedEquals([...fractions]..sort()));
    });
  });

  test('sync errors become short messages without links', () {
    expect(
      describeSyncError(VkException('web_token refused: type=error')),
      'VK login expired, log in again',
    );
    expect(
      describeSyncError(const SocketException('Failed host lookup')),
      'no connection to VK',
    );
    expect(
      describeSyncError(StateError('bad https://vk.ru/x?token=1 reply')),
      'Bad state: bad <url> reply',
    );
  });

  test('odd main colors are ignored', () {
    expect(parseVkColor('#fff'), isNull);
    expect(parseVkColor('зелёный'), isNull);
    expect(parseVkColor(12), isNull);
    expect(parseVkColor('ff0000'), 0xFFFF0000);
  });
}
