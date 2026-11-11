// Widget tests for opening a found song's album from search (plan 06, C4b):
// the album name on a song VK found opens the album's place through VK's
// link on the found song, as on the library's own rows; the row menu offers
// it too; a found song without VK's album link shows its album as plain
// text; and the album's row of a found song that plays keeps the playing
// mark, so a click on it pauses instead of starting it again.
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sources_scope.dart';

import 'catalog_support.dart';

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late ValueNotifier<List<SourceInfo>> sources;
  late ShowingPlayer player;
  late PlaybackController playback;

  /// Album keys and access keys VK was asked to list.
  late List<String> albumAsks;

  /// VK's list of the album "Человеко-часы" (-5_9): the found song and one
  /// more.
  const albumReply = {
    'count': 2,
    'items': [
      {
        'owner_id': -5,
        'id': 2,
        'access_key': 'k2',
        'artist': 'Дайте танк (!)',
        'title': 'Альтернатива',
        'duration': 200,
        'track_id': 102,
      },
      {
        'owner_id': -5,
        'id': 3,
        'access_key': 'k3',
        'artist': 'Дайте танк (!)',
        'title': 'Маяк',
        'duration': 220,
        'track_id': 103,
      },
    ],
  };

  setUp(() {
    albumAsks = [];
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    store.upsertAll(source, [
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Сплин',
        title: 'Романс',
        durationSec: 180,
        addedAt: 2,
      ),
    ]);
    vk = FakeVk(42)
      ..catalog.addAll([
        {
          ...vkAudio(
            -5,
            2,
            artist: 'Дайте танк (!)',
            title: 'Альтернатива',
            duration: 200,
            trackId: 102,
          ),
          'album': {
            'id': 9,
            'owner_id': -5,
            'access_key': 'a9',
            'title': 'Человеко-часы',
          },
        },
        // VK names an album here but gives no link to it.
        {
          ...vkAudio(
            -5,
            4,
            artist: 'Дайте танк (!)',
            title: 'Альтернатива (live)',
            duration: 230,
          ),
          'album': {'title': 'Концерт'},
        },
      ]);
    Future<Object?> call(String method, Map<String, String> params) async {
      if (method != 'audio.get') return vk.call(method, params);
      albumAsks.add(
        '${params['owner_id']}_${params['album_id']} '
        '${params['access_key']}',
      );
      return jsonDecode(jsonEncode(albumReply));
    }

    library = LibraryController(
      store.loadAll(),
      albums: LibraryAlbums(
        store: store,
        apiOfSource: (id) => id == source ? call : null,
      ),
    );
    sources = ValueNotifier(store.sources());
    player = ShowingPlayer();
    playback = PlaybackController(player: player);
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? call : null,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
      onAdded: playback.adoptAdded,
    );
  });
  tearDown(() {
    catalog.dispose();
    store.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SourcesScope(
        sources: sources,
        child: MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: playback,
            catalog: catalog,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Types [text] into the search box and waits out the pause and VK.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(EditableText), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  Finder inFound(FoundSong found, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('found-${found.track.id}')),
    matching: matching,
  );

  /// Lets the album's list come in.
  Future<void> settleAlbum(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Plays the found song, opens its album from the row, and checks the
  /// album's row of it: the playing mark, and a click pauses.
  Future<void> checkMarkInAlbum(WidgetTester tester) async {
    await pumpScreen(tester);
    await search(tester, 'дайте танк');
    final found = catalog.songs.first;
    await tester.tap(find.byKey(ValueKey('found-${found.track.id}')));
    await tester.pump();
    await tester.pump();
    expect(player.current?.id, found.track.id);
    await tester.tap(inFound(found, find.text('Человеко-часы')));
    await settleAlbum(tester);
    final row = library.visible.first;
    expect(row.title, 'Альтернатива');
    expect(row.id, isNot(found.track.id), reason: "the album's own id");
    final rowFinder = find.byKey(ValueKey('song-${row.id}'));
    expect(
      find.descendant(
        of: rowFinder,
        matching: find.byKey(const ValueKey('playing-bars')),
      ),
      findsOneWidget,
    );
    // The other album song is not marked.
    expect(
      find.descendant(
        of: find.byKey(ValueKey('song-${library.visible[1].id}')),
        matching: find.byKey(const ValueKey('playing-bars')),
      ),
      findsNothing,
    );
    await tester.tap(rowFinder);
    await tester.pump();
    expect(player.pauseToggles, 1, reason: 'paused, not started again');
    expect(player.current?.id, found.track.id);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('the album name on a found row opens the album through VK; '
      'Back returns to the search', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'дайте танк');
    final found = catalog.songs.first;
    expect(found.track.title, 'Альтернатива');
    await tester.tap(inFound(found, find.text('Человеко-часы')));
    await settleAlbum(tester);
    expect(library.view.kind, ViewKind.album);
    expect(library.view.album?.title, 'Человеко-часы');
    expect(library.view.album?.link?.key, '-5_9');
    expect(library.view.album?.link?.sourceId, source);
    expect(albumAsks, ['-5_9 a9'], reason: 'with the album access key');
    expect(library.visible.map((t) => t.title), ['Альтернатива', 'Маяк']);
    expect(library.albumStatus?.load, AlbumLoad.loaded);

    // Back: the search with what VK found.
    library.goBack();
    await tester.pump();
    expect(library.view.kind, ViewKind.songs);
    expect(library.searchText.text, 'дайте танк');
  });

  testWidgets('the found row menu opens the album; without VK\'s link the '
      'album is plain text and the menu has no item', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'дайте танк');
    final live = catalog.songs[1];
    expect(live.track.album, 'Концерт');
    expect(library.albumOf(live.track), isNull);
    await tester.tap(inFound(live, find.text('Концерт')));
    await tester.pump();
    // Plain text: the click is the row's, it plays the song.
    expect(library.view.kind, ViewKind.songs);
    expect(player.current?.id, live.track.id);
    await tester.tap(
      find.byKey(ValueKey('found-${live.track.id}')),
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('menu-open-album')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final found = catalog.songs.first;
    await tester.tap(
      find.byKey(ValueKey('found-${found.track.id}')),
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('menu-open-album')));
    await settleAlbum(tester);
    expect(library.view.kind, ViewKind.album);
    expect(library.view.album?.link?.key, '-5_9');
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a found song that plays keeps its mark on its album row, and '
      'a click there pauses it', (tester) async {
    await checkMarkInAlbum(tester);
  });

  testWidgets('the mark also finds another upload of the found song: the '
      'album lists the same recording (VK track id) under its own key', (
    tester,
  ) async {
    // On real VK most found songs are uploads of the album's songs, not
    // the album's own files (catalog-18.log: 3 of 3).
    final upload = vk.catalog.first;
    upload['owner_id'] = -77;
    upload['id'] = 50;
    await checkMarkInAlbum(tester);
  });
}
