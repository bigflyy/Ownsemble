import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/vk/vk_album.dart';

/// A library song of album "Человеко-часы" unless [album] says otherwise.
Track song(
  int id,
  String title, {
  String? album = 'Человеко-часы',
  int addedOrder = 0,
}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Дайте танк (!)',
  title: title,
  album: album,
  durationSec: 200,
  sourceKey: '1_$id',
);

/// A song as the album's VK list names it; [id] negative when the library
/// lacks it.
AlbumSong listed(int id, String title, {int? vkTrackId}) => (
  track: Track(
    id: id,
    sourceId: 1,
    source: TrackSource.vk,
    artist: 'Дайте танк (!)',
    title: title,
    album: 'Человеко-часы',
    durationSec: 200,
    sourceKey: '-5_${id.abs()}',
  ),
  vkTrackId: vkTrackId,
);

const album = AlbumRef(
  title: 'Человеко-часы',
  artist: 'Дайте танк (!)',
  link: (sourceId: 1, key: '-5_9', accessKey: 'a'),
);

/// An album catalog whose VK list arrives when the test completes [answer].
class FakeCatalog implements AlbumCatalog {
  /// Library ids in the album, in library order.
  List<int> libraryIdList = [];

  /// Library id of each VK track id.
  Map<int, int> owned = {};
  bool fetchable = true;
  var fetches = 0;
  Completer<List<AlbumSong>> answer = Completer();

  @override
  AlbumRef? albumOf(Track track) => track.album == null ? null : album;

  @override
  List<int> libraryIds(AlbumRef album) => libraryIdList;

  @override
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds) => {
    for (final id in vkTrackIds) id: ?owned[id],
  };

  @override
  bool canFetch(AlbumRef album) => fetchable;

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) {
    fetches++;
    return answer.future;
  }
}

List<String> titles(LibraryController library) => [
  for (final track in library.visible) track.title,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Track> tracks;
  late FakeCatalog catalog;
  late Map<String, String?> settings;

  LibraryController open() => LibraryController(
    tracks,
    albums: catalog,
    readSetting: (key) => settings[key],
    writeSetting: (key, value) => settings[key] = value,
  );

  setUp(() {
    // "Люди" and "Профессионал" are on the album, "Чужая" is another
    // version the library put in the album, "Вне альбома" has no album.
    tracks = [
      song(1, 'Люди'),
      song(2, 'Вне альбома', album: null),
      song(3, 'Профессионал'),
      song(4, 'Чужая'),
    ];
    catalog = FakeCatalog()
      ..libraryIdList = [1, 3, 4]
      ..owned = {101: 1, 103: 3};
    settings = {};
  });

  /// VK's list of the album: two library songs and two the library lacks.
  final vkList = [
    listed(-1, 'Профессионал', vkTrackId: 103),
    listed(-2, 'Альтернатива', vkTrackId: 102),
    listed(-3, 'Люди', vkTrackId: 101),
    listed(-4, 'Бардак', vkTrackId: 104),
  ];

  test(
    'an album shows the library songs at once, then the whole list',
    () async {
      final library = open();
      library.openAlbum(tracks.first);
      expect(library.view.kind, ViewKind.album);
      expect(library.view.album, album);
      expect(titles(library), ['Люди', 'Профессионал', 'Чужая']);
      expect(library.albumStatus?.load, AlbumLoad.loading);
      expect(library.albumStatus?.inLibrary, 3);
      expect(catalog.fetches, 1);

      catalog.answer.complete(vkList);
      await pumpEventQueue();
      // The album's order, the library's own song in place of its copy, the
      // version the list does not name last.
      expect(titles(library), [
        'Профессионал',
        'Альтернатива',
        'Люди',
        'Бардак',
        'Чужая',
      ]);
      expect(library.visible[0], same(tracks[2]));
      expect(library.visible[1].inLibrary, isFalse);
      expect(library.visible[2], same(tracks[0]));
      expect(library.albumStatus?.load, AlbumLoad.loaded);
      expect(library.albumStatus?.inLibrary, 3);
      expect(library.viewCount, 5);
    },
  );

  test('Back goes to the place the album was opened from', () async {
    final library = open();
    library.searchText.text = 'люди';
    expect(titles(library), ['Люди']);
    library.openAlbum(library.visible.first);
    // The album starts without the search.
    expect(library.searchText.text, '');
    expect(titles(library), ['Люди', 'Профессионал', 'Чужая']);

    library.goBack();
    expect(library.view, LibraryView.songs);
    expect(library.searchText.text, 'люди');
    expect(titles(library), ['Люди']);

    // Forward reopens the album without asking VK again once it is in.
    catalog.answer.complete(vkList);
    await pumpEventQueue();
    library.goForward();
    expect(library.view.kind, ViewKind.album);
    expect(titles(library).length, 5);
    expect(catalog.fetches, 1);
  });

  test('a failed list leaves the library songs and says why', () async {
    final library = open();
    library.openAlbum(tracks.first);
    catalog.answer.completeError(
      const AlbumNotListed('VK did not list the album: no connection to VK'),
    );
    await pumpEventQueue();
    expect(titles(library), ['Люди', 'Профессионал', 'Чужая']);
    expect(library.albumStatus?.load, AlbumLoad.failed);
    expect(library.albumStatus?.reason, contains('no connection'));
    // The rebuild after the failure does not ask VK again (it once looped).
    expect(catalog.fetches, 1);

    // Opening it again asks again.
    catalog.answer = Completer();
    library.goBack();
    library.openAlbum(tracks.first);
    expect(catalog.fetches, 2);
    expect(library.albumStatus?.load, AlbumLoad.loading);
  });

  test('with nothing to ask, the album is the library songs', () {
    catalog.fetchable = false;
    final library = open();
    library.openAlbum(tracks.first);
    expect(catalog.fetches, 0);
    expect(titles(library), ['Люди', 'Профессионал', 'Чужая']);
    expect(library.albumStatus?.load, AlbumLoad.failed);
    expect(library.albumStatus?.reason, contains('log in'));
  });

  test('a song without an album opens nothing', () {
    final library = open();
    library.openAlbum(tracks[1]);
    expect(library.view, LibraryView.songs);
  });

  test('a search in an album finds songs outside the library too', () async {
    final library = open();
    library.openAlbum(tracks.first);
    catalog.answer.complete(vkList);
    await pumpEventQueue();
    library.searchText.text = 'бардак';
    expect(titles(library), ['Бардак']);
    expect(library.visible.single.inLibrary, isFalse);
  });

  test('a list that arrives after leaving the album changes nothing', () async {
    final library = open();
    library.openAlbum(tracks.first);
    library.goBack();
    var notified = 0;
    library.addListener(() => notified++);
    catalog.answer.complete(vkList);
    await pumpEventQueue();
    expect(library.view, LibraryView.songs);
    expect(notified, 0);
  });

  test(
    'a sync that adds an album song shows it once, as the library\'s',
    () async {
      final library = open();
      library.openAlbum(tracks.first);
      catalog.answer.complete(vkList);
      await pumpEventQueue();

      // The sync added "Бардак" (VK track 104) as library row 5.
      final added = song(5, 'Бардак');
      final reloaded = [...tracks, added];
      catalog
        ..libraryIdList = [1, 3, 4, 5]
        ..owned = {...catalog.owned, 104: 5};
      library.replaceTracks(reloaded, SearchIndex(reloaded));
      expect(titles(library), [
        'Профессионал',
        'Альтернатива',
        'Люди',
        'Бардак',
        'Чужая',
      ]);
      expect(library.visible[3], same(added));
    },
  );

  test('an album is not reopened in the next run', () {
    final library = open();
    library.openAlbum(tracks.first);
    library.notePlayedFrom();
    expect(settings[LibraryController.viewSetting], 'album');
    final next = open();
    expect(next.view, LibraryView.songs);
  });

  test('a song from outside the library is found in its album', () async {
    final library = open();
    library.openAlbum(tracks.first);
    catalog.answer.complete(vkList);
    await pumpEventQueue();
    final outside = library.visible[1];
    library.notePlayedFrom();
    library.goBack();
    expect(library.view, LibraryView.songs);

    library.goToSong(outside, listRow: 1);
    expect(library.view.kind, ViewKind.album);
    expect(library.jump.row, 1);
  });

  group('VK album list', () {
    test('asks audio.get for the album, page by page', () async {
      final asked = <Map<String, String>>[];
      Future<Object?> call(String method, Map<String, String> params) async {
        expect(method, 'audio.get');
        asked.add(params);
        final offset = int.parse(params['offset']!);
        // 5 songs, one of them blocked: VK counts it but leaves it out.
        final ids = [
          for (var i = offset; i < offset + 2 && i < 5; i++)
            if (i != 2) i,
        ];
        return {
          'count': 5,
          'items': [
            for (final i in ids) {'owner_id': -5, 'id': i, 'title': 'Песня $i'},
          ],
        };
      }

      final items = await fetchVkAlbumItems(
        call,
        '-5_9',
        accessKey: 'a',
        pageSize: 2,
      );
      expect([for (final item in items) item['id']], [0, 1, 3, 4]);
      expect([for (final p in asked) p['offset']], ['0', '2', '4']);
      expect(asked.first['owner_id'], '-5');
      expect(asked.first['album_id'], '9');
      expect(asked.first['access_key'], 'a');
    });

    test('leaves out the access key when the album has none', () async {
      Map<String, String>? asked;
      await fetchVkAlbumItems((method, params) async {
        asked = params;
        return {'count': 0, 'items': <Object>[]};
      }, '-5_9');
      expect(asked!.containsKey('access_key'), isFalse);
    });
  });

  group('library albums', () {
    late LibraryStore store;
    late int source;
    setUp(() {
      store = LibraryStore.open(':memory:');
      source = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    });
    tearDown(() => store.close());

    test(
      'an album song outside the library streams through the account',
      () async {
        final id = store.upsertAll(source, [
          const NewTrack(
            sourceKey: '1_1',
            artist: 'Дайте танк (!)',
            title: 'Люди',
            album: 'unnamed-as-shown',
            durationSec: 162,
            addedAt: 1,
            vkTrackId: 101,
            vkAlbumKey: '-5_9',
            vkAlbumAccessKey: 'a',
          ),
        ]).single;
        final params = <Map<String, String>>[];
        final albums = LibraryAlbums(
          store: store,
          apiOfSource: (sourceId) => sourceId != source
              ? null
              : (method, p) async {
                  params.add(p);
                  return {
                    'count': 2,
                    'items': [
                      {
                        'owner_id': -5,
                        'id': 1,
                        'access_key': 'song-key',
                        'artist': 'Дайте танк (!)',
                        'title': 'Люди',
                        'duration': 162,
                        'track_id': 101,
                        // VK names some albums "unnamed" on their songs.
                        'album': {'owner_id': -5, 'id': 9, 'title': 'unnamed'},
                      },
                      {
                        'owner_id': -5,
                        'id': 2,
                        'artist': 'Дайте танк (!)',
                        'title': 'Альтернатива',
                        'duration': 230,
                        'track_id': 102,
                      },
                    ],
                  };
                },
        );
        final track = store.loadAll().single;
        final ref = albums.albumOf(track)!;
        expect(ref.link?.key, '-5_9');
        expect(albums.libraryIds(ref), [id]);
        expect(albums.canFetch(ref), isTrue);

        final songs = await albums.fetch(ref);
        expect(params.single['album_id'], '9');
        expect(params.single['access_key'], 'a');
        expect([for (final s in songs) s.vkTrackId], [101, 102]);
        final outside = songs.first.track;
        expect(outside.inLibrary, isFalse);
        expect(outside.sourceId, source);
        expect(outside.sourceKey, '-5_1');
        expect(outside.accessKey, 'song-key');
        expect(outside.album, 'unnamed-as-shown');
        expect(albums.libraryIdsByVkTrackId([101, 102]), {101: id});

        // The same song keeps its id; its own album link is the album's.
        final again = await albums.fetch(ref);
        expect(again.first.track.id, outside.id);
        expect(again.last.track.id, isNot(outside.id));
        expect(albums.albumOf(outside), ref);
      },
    );

    test('without a logged-in account nothing is asked', () async {
      store.upsertAll(source, [
        const NewTrack(
          sourceKey: '1_1',
          artist: 'А',
          title: 'Б',
          album: 'В',
          durationSec: 1,
          addedAt: 1,
          vkAlbumKey: '-5_9',
        ),
      ]);
      final albums = LibraryAlbums(store: store, apiOfSource: (_) => null);
      final ref = albums.albumOf(store.loadAll().single)!;
      expect(albums.canFetch(ref), isFalse);
      await expectLater(albums.fetch(ref), throwsA(isA<AlbumNotListed>()));
    });

    test('a song without a link opens the songs with its album and artist', () {
      final ids = store.upsertAll(source, [
        for (final (key, artist, album) in [
          ('1_1', 'Сплин', 'Гранатовый альбом'),
          ('1_2', 'Сплин', 'Гранатовый альбом'),
          ('1_3', 'Другой', 'Гранатовый альбом'),
          ('1_4', 'Сплин', 'Альтависта'),
        ])
          NewTrack(
            sourceKey: key,
            artist: artist,
            title: key,
            album: album,
            durationSec: 1,
            addedAt: 1,
          ),
      ]);
      final albums = LibraryAlbums(store: store, apiOfSource: (_) => null);
      final first = store.loadAll().firstWhere((t) => t.id == ids[0]);
      final ref = albums.albumOf(first)!;
      expect(ref.link, isNull);
      expect(albums.libraryIds(ref).toSet(), {ids[0], ids[1]});
    });
  });
}
