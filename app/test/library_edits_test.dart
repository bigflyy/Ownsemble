// Tests for adding, removing and restoring songs in the library (plan 06,
// C2): the row the add puts in at once, what the next sync does with it, the
// removed mark, Undo, and which found songs count as in the library.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/found_match.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_sync.dart';

import 'merge_support.dart';

/// The account the fake VK belongs to.
const me = 42;

/// A VK account's library as `audio.get` and `audio.getById` give it.
class FakeVkLibrary {
  /// The library, newest first, as raw audio items.
  final items = <Map<String, dynamic>>[];

  Future<Object?> call(String method, Map<String, String> params) async {
    switch (method) {
      case 'audio.get':
        final offset = int.parse(params['offset']!);
        final count = int.parse(params['count']!);
        return {
          'count': items.length,
          'items': items.skip(offset).take(count).toList(),
        };
      case 'audio.getById':
        // Songs removed from the library still exist on VK, with a stream.
        return [
          for (final key in params['audios']!.split(','))
            {
              'owner_id': int.parse(key.split('_')[0]),
              'id': int.parse(key.split('_')[1]),
              'url': 'https://audio.invalid/x.mp3',
            },
        ];
    }
    throw StateError('unexpected $method');
  }
}

/// One found or listed VK song.
Map<String, dynamic> vkAudio(
  int owner,
  int id, {
  String artist = 'Сплин',
  String title = 'Романс',
  int duration = 211,
  int? trackId,
  String accessKey = 'key',
}) => {
  'owner_id': owner,
  'id': id,
  'artist': artist,
  'title': title,
  'duration': duration,
  'date': 1762600000 + id,
  'access_key': accessKey,
  'url': 'https://audio.invalid/$id.mp3',
  'track_id': ?trackId,
};

void main() {
  late LibraryStore store;
  late FakeVkLibrary vk;
  late int source;

  setUp(() {
    store = LibraryStore.open(':memory:');
    vk = FakeVkLibrary();
    source = store.ensureSource(TrackSource.vk, account: '$me', name: 'VK');
  });
  tearDown(() => store.close());

  Future<VkSyncResult> sync() => syncVkSource(
    call: vk.call,
    userId: me,
    store: store,
    albumGap: Duration.zero,
  );

  /// Adds the found song [found] as VK would: the copy goes first in the VK
  /// library under [newId], and the app puts its row in at once.
  int add(Map<String, dynamic> found, int newId) {
    vk.items.insert(
      0,
      Map.of(found)
        ..['owner_id'] = me
        ..['id'] = newId
        ..['access_key'] = 'own',
    );
    final copy = vkItemToTrack(found).asAddedCopy('${me}_$newId', addedAt: 5);
    return store.upsertAll(source, [copy]).single;
  }

  List<String> listedTitles() => [for (final t in store.loadAll()) t.title];

  group('add', () {
    test('the copy is listed at once under the key the add answered '
        'with', () {
      final found = vkAudio(-2000, 1, title: 'Выхода нет', trackId: 7);
      final id = add(found, 900);
      final row = store.loadAll().single;
      expect(row.id, id);
      expect(row.sourceKey, '${me}_900');
      expect((row.artist, row.title), ('Сплин', 'Выхода нет'));
      // The found song's key is not the copy's.
      expect(row.accessKey, isNull);
    });

    test('add -> sync -> one row, the same one, with VK\'s key', () async {
      vk.items.add(vkAudio(me, 1, title: 'Старое'));
      await sync();
      final id = add(vkAudio(-2000, 5, title: 'Новое'), 901);
      final result = await sync();
      expect(result.added, 0);
      expect(listedTitles(), ['Новое', 'Старое']);
      final row = store.loadAll().first;
      expect(row.id, id);
      expect(row.accessKey, 'own');
    });
  });

  group('remove and Undo', () {
    late int id;
    setUp(() async {
      vk.items.addAll([
        vkAudio(me, 2, title: 'Мы сидели и курили'),
        vkAudio(me, 1, title: 'Романс'),
      ]);
      await sync();
      id = store.loadAll().firstWhere((t) => t.title == 'Романс').id;
      store
        ..addPlay(id, atMs: 1000)
        ..addFavorite(id, atMs: 2000);
    });

    /// What VK does on Remove, then the app's mark.
    void remove() {
      vk.items.removeWhere((item) => item['id'] == 1);
      expect(store.markRemoved(source, ['${me}_1'], atMs: 3000), 1);
    }

    test('a removed song is not listed, and its plays and favorite stay', () {
      remove();
      expect(listedTitles(), ['Мы сидели и курили']);
      expect(store.songPlays()[id]?.plays, 1);
      expect(store.favorites().single.trackId, id);
      expect(store.history().single.trackId, id);
      // History still finds the song it points at.
      expect([for (final t in store.loadRemoved()) t.id], [id]);
    });

    test('marking twice counts once', () {
      remove();
      expect(store.markRemoved(source, ['${me}_1']), 0);
    });

    test(
      'remove -> sync -> still not listed, not counted gone again',
      () async {
        remove();
        final result = await sync();
        expect(result.newlyGone, 0);
        expect(listedTitles(), ['Мы сидели и курили']);
      },
    );

    test('Undo brings the same row back with its plays and favorite', () {
      remove();
      final back = store.restoreRemoved(
        source,
        vkItemToTrack(vkAudio(me, 1, title: 'Романс')),
      );
      expect(back, id);
      final row = store.loadAll().firstWhere((t) => t.title == 'Романс');
      expect(row.id, id);
      expect(row.isGone, isFalse);
      expect(store.songPlays()[id]?.plays, 1);
      expect(store.favorites().single.trackId, id);
      expect(store.loadRemoved(), isEmpty);
    });

    test('restore -> sync -> back, one row', () async {
      remove();
      await sync();
      vk.items.add(vkAudio(me, 1, title: 'Романс'));
      store.restoreRemoved(source, vkItemToTrack(vkAudio(me, 1)));
      final result = await sync();
      expect(result.added, 0);
      expect(listedTitles(), ['Мы сидели и курили', 'Романс']);
      expect(store.loadAll().where((t) => t.id == id), hasLength(1));
      expect(store.loadAll().firstWhere((t) => t.id == id).isGone, isFalse);
    });

    test('a sync that still lists a removed song does not bring it '
        'back', () async {
      // The sync read the page before VK removed the song.
      store.markRemoved(source, ['${me}_1']);
      await sync();
      expect(listedTitles(), ['Мы сидели и курили']);
    });

    test('a removed song is no longer in its album', () {
      final row = vkItemToTrack(
        vkAudio(me, 3, title: 'Орбит без сахара', trackId: 77)
          ..['album'] = {
            'id': 9,
            'owner_id': -2,
            'title': 'Альтависта',
            'access_key': 'a',
          },
      );
      final albumSong = store.upsertAll(source, [row]).single;
      expect(store.listedIdsInVkAlbum('-2_9'), [albumSong]);
      expect(store.listedIdsByVkTrackId([77]), {77: albumSong});
      expect(store.listedIdsWithAlbum('Альтависта', 'Сплин'), [albumSong]);
      store.markRemoved(source, ['${me}_3']);
      expect(store.listedIdsInVkAlbum('-2_9'), isEmpty);
      expect(store.listedIdsByVkTrackId([77]), isEmpty);
      expect(store.listedIdsWithAlbum('Альтависта', 'Сплин'), isEmpty);
    });
  });

  group('a song in two accounts', () {
    late int other;
    setUp(() {
      other = store.ensureSource(TrackSource.vk, account: '43', name: 'VK 2');
      store.upsertAll(source, [vkItemToTrack(vkAudio(me, 1))]);
      store.upsertAll(other, [vkItemToTrack(vkAudio(43, 1))]);
      mergeSameFiles(store);
      expect(store.loadAll().single.copies, hasLength(1));
    });

    test('removed from one account it stays listed, without that '
        'account\'s copy', () {
      store.markRemoved(other, ['43_1']);
      final row = store.loadAll().single;
      expect(row.copies, isEmpty);
      expect(row.isGone, isFalse);
    });

    test('removed from the listed row\'s account it stays listed by the '
        'other copy', () {
      store.markRemoved(source, ['${me}_1']);
      final row = store.loadAll().single;
      expect(row.goneAtMs, isNotNull);
      expect(row.copies.single.sourceKey, '43_1');
      expect(row.isGone, isFalse);
    });

    test('removed from both it is not listed', () {
      store
        ..markRemoved(source, ['${me}_1'])
        ..markRemoved(other, ['43_1']);
      expect(store.loadAll(), isEmpty);
    });
  });

  group('FoundMatcher', () {
    late int listed;
    setUp(() {
      listed = store.upsertAll(source, [
        vkItemToTrack(
          vkAudio(
            me,
            1,
            artist: 'Кино',
            title: 'Звезда по имени Солнце',
            duration: 225,
            trackId: 500,
          ),
        ),
      ]).single;
    });

    int? match(Map<String, dynamic> found) =>
        FoundMatcher(store.songRows()).listedIdOf(vkItemToTrack(found));

    test('the account\'s own copy, by key', () {
      expect(match(vkAudio(me, 1, title: 'другое имя')), listed);
    });

    test('another upload VK calls the same recording, by track id', () {
      expect(
        match(vkAudio(-7, 9, title: 'Zvezda', duration: 300, trackId: 500)),
        listed,
      );
    });

    test('another upload with the same name and about the same length', () {
      expect(
        match(
          vkAudio(
            -7,
            9,
            artist: 'КИНО',
            title: 'Звезда по имени солнце!',
            duration: 226,
          ),
        ),
        listed,
      );
    });

    test('ё and е count as one letter', () {
      store.upsertAll(source, [
        vkItemToTrack(vkAudio(me, 2, artist: 'Ёлка', title: 'Прованс')),
      ]);
      expect(
        match(vkAudio(-7, 3, artist: 'Елка', title: 'Прованс')),
        isNotNull,
      );
    });

    test('the same name with another length is another cut: not in the '
        'library', () {
      expect(
        match(
          vkAudio(
            -7,
            9,
            artist: 'Кино',
            title: 'Звезда по имени Солнце',
            duration: 260,
          ),
        ),
        isNull,
      );
    });

    test('another song is not in the library', () {
      expect(match(vkAudio(-7, 9, title: 'Кукушка', trackId: 501)), isNull);
    });

    test('a removed song is not in the library any more', () {
      store.markRemoved(source, ['${me}_1']);
      expect(match(vkAudio(me, 1)), isNull);
      expect(match(vkAudio(-7, 9, trackId: 500)), isNull);
    });

    test('a copy in another account answers with the listed song', () {
      final other = store.ensureSource(
        TrackSource.vk,
        account: '43',
        name: 'VK 2',
      );
      store.upsertAll(other, [
        vkItemToTrack(
          vkAudio(
            43,
            1,
            artist: 'Кино',
            title: 'Звезда по имени Солнце',
            duration: 225,
            trackId: 500,
          ),
        ),
      ]);
      mergeSameFiles(store);
      expect(store.loadAll().single.id, listed);
      expect(match(vkAudio(43, 1)), listed);
    });
  });
}
