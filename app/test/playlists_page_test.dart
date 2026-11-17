// Widget tests for the Playlists place (plan 08, B2): the account's made
// and followed playlists as cards (followed albums left out), a card
// opening its playlist as an ordinary song list with the library's own song
// in place and + on the others, songs VK gives no file for greyed, Play and
// Shuffle, and the narrow window.

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/playlists.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';

import 'catalog_support.dart';
import 'recs_support.dart';

/// One item of audio.getPlaylists for the account 42.
Map<String, dynamic> playlistItem(
  int id,
  String title, {
  bool followed = false,
  bool album = false,
  required int count,
}) => {
  'id': id,
  'owner_id': 42,
  'title': title,
  'count': count,
  'update_time': 100 + id,
  'access_key': 'pl$id',
  'type': album ? 'album' : 'ugc',
  if (followed || album) 'original': {'owner_id': -5, 'playlist_id': id},
};

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late VkPlaylists playlists;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;
  late ShowingPlayer player;
  late List<Map<String, dynamic>> items;
  late Map<String, List<Map<String, dynamic>>> songs;

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    // The library has the made playlist's first song, as its own upload
    // with another key: the row is the library's song.
    store.upsertAll(source, [
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Кино',
        title: 'Закрой за мной дверь',
        durationSec: 205,
        addedAt: 2,
      ),
    ]);
    items = [
      playlistItem(1, 'В дорогу', count: 4),
      playlistItem(2, 'Чужой плейлист', followed: true, count: 2),
      playlistItem(3, 'Альбом', album: true, count: 1),
    ];
    songs = {
      '42_1': [
        recSong(-7, 10),
        recSong(-7, 11, title: 'Звезда по имени Солнце', duration: 225),
        recSong(-7, 12, title: 'Кукушка', duration: 400),
        recSong(-7, 13, title: 'Не в регионе', restricted: 2),
      ],
      '42_2': [
        recSong(-7, 20, title: 'Группа крови', duration: 286),
        recSong(-7, 21, title: 'Пачка сигарет', duration: 268),
      ],
      '42_3': [recSong(-7, 30, title: 'Альбомная')],
    };
    vk = FakeVk(42);
    Future<Object?> call(String method, Map<String, String> params) async {
      if (method == 'audio.getPlaylists') {
        return {'count': items.length, 'items': items};
      }
      if (method == 'audio.get' && params['album_id'] != null) {
        final list = songs['${params['owner_id']}_${params['album_id']}']!;
        return {'count': list.length, 'items': list};
      }
      return vk.call(method, params);
    }

    library = LibraryController(store.loadAll());
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
    playlists = VkPlaylists(
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? call : null,
      outside: OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong),
    );
    library.vkLists = playlists;
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  Future<void> openPlaylists(
    WidgetTester tester, {
    double width = 1400,
    double height = 900,
  }) async {
    tester.view.physicalSize = Size(width, height);
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
            playlists: playlists,
            settings: ShellSettings.inMemory(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('the page shows the made and the followed playlists, no '
      'album', (tester) async {
    await openPlaylists(tester);
    expect(find.byKey(const ValueKey('playlists-page')), findsOneWidget);
    expect(find.text('YOUR PLAYLISTS'), findsOneWidget);
    expect(find.text('PLAYLISTS YOU FOLLOW'), findsOneWidget);
    expect(find.byKey(const ValueKey('list-card-В дорогу')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('list-card-Чужой плейлист')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('list-card-Альбом')), findsNothing);
    expect(find.text('4 songs'), findsOneWidget);
    expect(find.text('2 songs'), findsOneWidget);
    expect(find.text('later'), findsOneWidget, reason: 'only Artists');
    expect(find.text('From VK, updated at each sync'), findsOneWidget);
  });

  testWidgets('a card opens its playlist: own song, + on the others, '
      'greyed restricted song', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(find.text('В дорогу'), findsWidgets);
    expect(library.visible, hasLength(4));
    expect(library.visible.first.inLibrary, isTrue);
    expect(library.visible.skip(1).every((t) => !t.inLibrary), isTrue);
    expect(find.byKey(ValueKey('add-${library.visible[1].id}')), findsOne);
    expect(
      find.byKey(ValueKey('add-${library.visible.first.id}')),
      findsNothing,
    );
    expect(find.text('Your playlist on VK. 1 in your library'), findsOneWidget);
    expect(find.byKey(const ValueKey('restricted-2')), findsOneWidget);
    expect(
      find.byKey(ValueKey('add-${library.visible.last.id}')),
      findsNothing,
    );
    // Back returns to the page.
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.playlists);
  });

  testWidgets('a followed playlist says so', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-Чужой плейлист')));
    await tester.pumpAndSettle();
    expect(
      find.text('A playlist you follow on VK. 0 in your library'),
      findsOneWidget,
    );
  });

  testWidgets('a card\'s Play plays the playlist without the restricted '
      'song, the library\'s own song first', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-play-В дорогу')));
    // The playing card's mark moves: nothing settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.current?.title, 'Закрой за мной дверь');
    expect(player.current?.inLibrary, isTrue);
    expect(playback.queue.context, hasLength(3));
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the heading\'s Shuffle turns shuffle on and plays', (
    tester,
  ) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    expect(playback.shuffle, isFalse);
    await tester.tap(find.byKey(const ValueKey('list-shuffle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(playback.shuffle, isTrue);
    expect(playback.queue.context, hasLength(3));
    expect(player.current, isNotNull);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  // User, 2026-11-18: "not very clear which playlist is playing now".
  testWidgets('the playing playlist is marked: its card after Shuffle, and '
      'the player says where it plays from', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('list-shuffle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(library.view.kind, ViewKind.playlists);
    expect(find.byKey(const ValueKey('list-playing-В дорогу')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('list-playing-Чужой плейлист')),
      findsNothing,
    );
    final from = find.byKey(const ValueKey('player-from'));
    expect(
      find.descendant(of: from, matching: find.textContaining('В дорогу')),
      findsOneWidget,
    );
    // The line opens the list it plays from.
    await tester.tap(from);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(library.view.kind, ViewKind.vkList);
    expect(library.view.album?.title, 'В дорогу');

    // Another card's Play moves the mark to that card.
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('list-play-Чужой плейлист')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('list-playing-Чужой плейлист')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('list-playing-В дорогу')), findsNothing);
    expect(
      find.descendant(of: from, matching: find.textContaining('Чужой')),
      findsOneWidget,
    );
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a row click plays the playlist without the songs VK gives '
      'no file for', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    final second = library.visible[1];
    await tester.tap(find.byKey(ValueKey('entry-${second.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.current?.id, second.id);
    expect(playback.queue.context, hasLength(3));
    expect(
      playback.queue.context.map((t) => t.title),
      isNot(contains('Не в регионе')),
    );
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Back to a playlist after a refresh shows its new songs', (
    tester,
  ) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    expect(library.visible, hasLength(4));
    library.showView(LibraryView.songs);
    await tester.pumpAndSettle();
    songs['42_1'] = songs['42_1']!.take(2).toList();
    items[0]['count'] = 2;
    items[0]['update_time'] = 999;
    await playlists.refresh();
    await tester.pumpAndSettle();
    library.goBack();
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(library.visible, hasLength(2));
  });

  testWidgets('a playlist removed on VK while open says so', (tester) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    items.removeAt(0);
    await playlists.refresh();
    await tester.pumpAndSettle();
    expect(library.visible.where((t) => !t.inLibrary), isEmpty);
    expect(find.textContaining('no longer lists this playlist'), findsWidgets);
  });

  testWidgets("a greyed row's Play next and Add to queue are off", (
    tester,
  ) async {
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
    await tester.pumpAndSettle();
    final greyed = library.visible.last;
    await tester.tap(
      find.byKey(ValueKey('entry-${greyed.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final key in ['menu-play-next', 'menu-add-to-queue']) {
      final item = tester.widget<PopupMenuItem<Object>>(
        find.byKey(ValueKey(key)),
      );
      expect(item.enabled, isFalse, reason: key);
    }
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a song VK blocks in the playlist that the library has plays '
      'as the library\'s song from the card too', (tester) async {
    songs['42_1']![0] = recSong(-7, 10, restricted: 2);
    await openPlaylists(tester);
    await tester.tap(find.byKey(const ValueKey('list-play-В дорогу')));
    // The playing card's mark moves: nothing settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.current?.inLibrary, isTrue);
    expect(playback.queue.context, hasLength(3));
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('no playlists on VK: the page says so', (tester) async {
    items = [];
    await openPlaylists(tester);
    expect(find.textContaining('No playlists on VK yet'), findsOneWidget);
  });

  testWidgets('narrow: the cards wrap and nothing overflows', (tester) async {
    await openPlaylists(tester, width: 760);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('list-card-Чужой плейлист')),
      findsOneWidget,
    );
  });
}
