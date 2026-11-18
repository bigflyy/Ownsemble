// Editing VK playlists from the app's places (plan 08, C4): the row menu's
// Add to playlist... (a second menu, "already in" greyed, New playlist...),
// Remove from this playlist with its Undo bar, every entry its own row (two
// VK copies of one library song), the heading's Rename / Delete /
// Unfollow, and the Playlists page's New playlist. VK is the fake that does
// what real VK did on the test account (playlist_edits_support.dart).

import 'dart:async';

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

import 'playlist_edits_support.dart';
import 'catalog_support.dart' show ShowingPlayer;

void main() {
  late LibraryStore store;
  late EditVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late VkPlaylists playlists;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;
  late FakePlaylist mine;
  late FakePlaylist theirs;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final source = store.ensureSource(
      TrackSource.vk,
      account: '10000',
      name: 'Мой VK',
    );
    vk = EditVk();
    for (final id in [1, 2, 3]) {
      vk.song(10000, id, trackId: 100 + id);
      vk.library.add('10000_$id');
    }
    store.upsertAll(source, [
      for (final id in [1, 2, 3])
        NewTrack(
          sourceKey: '10000_$id',
          artist: 'Исполнитель',
          title: 'Песня $id',
          durationSec: 200,
          addedAt: id,
          vkTrackId: 100 + id,
        ),
    ]);
    vk.song(555, 8, trackId: 88);
    theirs = vk.followed('Чужой', '555_3');
    theirs.songs.add(vk.known['555_8']!);
    mine = vk.made('Мой', [vk.known['10000_1']!, vk.known['10000_2']!]);

    library = LibraryController(store.loadAll());
    sources = ValueNotifier(store.sources());
    playback = PlaybackController(player: ShowingPlayer());
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
      onAdded: playback.adoptAdded,
    );
    playlists = VkPlaylists(
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? vk.call : null,
      outside: OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong),
    );
    library.vkLists = playlists;
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  String keyOf(FakePlaylist list) => '10000_${list.id}';

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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
    // The fake VK answers on timers: the test's pumps move them.
    unawaited(playlists.refresh());
    await tester.pumpAndSettle();
  }

  Future<void> openPlaylist(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('list-card-$title')));
    await tester.pumpAndSettle();
  }

  Future<void> rowMenu(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  /// Lets the bar at the bottom run out: its time starts once it is in.
  Future<void> closeBar(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 7));
    // The bar slides out; then VK's replies come on timers: a few pumps let
    // the write and its read-back through.
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<PopupMenuItem<Object?>>(find.byKey(ValueKey(key))).enabled;

  testWidgets('Add to playlist from a library row: the second menu greys a '
      'playlist that has the song; a choice puts it on top on VK', (
    tester,
  ) async {
    await openApp(tester);
    await rowMenu(tester, 'Песня 1');
    await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
    await tester.pumpAndSettle();
    expect(enabled(tester, 'add-to-playlist-${keyOf(mine)}'), isFalse);
    expect(find.text('already in'), findsOneWidget);
    expect(
      find.byKey(ValueKey('add-to-playlist-${keyOf(theirs)}')),
      findsNothing,
      reason: 'a followed playlist takes no songs',
    );
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await rowMenu(tester, 'Песня 3');
    await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
    await tester.pumpAndSettle();
    expect(enabled(tester, 'add-to-playlist-${keyOf(mine)}'), isTrue);
    await tester.tap(find.byKey(ValueKey('add-to-playlist-${keyOf(mine)}')));
    await tester.pumpAndSettle();
    expect(vk.keysOf(mine), ['10000_3', '10000_1', '10000_2']);
    expect(find.text('Added to Мой'), findsOneWidget);
  });

  testWidgets('New playlist... from the row menu makes one with the song', (
    tester,
  ) async {
    await openApp(tester);
    await rowMenu(tester, 'Песня 2');
    await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-playlist-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      'Свежий',
    );
    await tester.tap(find.byKey(const ValueKey('playlist-name-ok')));
    await tester.pumpAndSettle();
    expect(vk.playlists.first.title, 'Свежий');
    expect(vk.keysOf(vk.playlists.first), ['10000_2']);
    expect(find.text('Made Свежий'), findsOneWidget);
  });

  testWidgets('two VK copies of one library song are two rows of the '
      'playlist, each taken out on its own', (tester) async {
    // A copy VK made of song 1's recording, next to song 1 itself.
    mine.songs.insert(0, vk.song(10000, 50, trackId: 101));
    await openApp(tester);
    await openPlaylist(tester, 'Мой');
    expect(library.visible.map((t) => t.title), [
      'Песня 1',
      'Песня 1',
      'Песня 2',
    ]);
    expect(library.visible.first.inLibrary, isTrue);
    expect(library.entryIdAt(0), isNot(library.entryIdAt(1)));
    await rowMenu(tester, 'Песня 1');
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-playlist')));
    await tester.pumpAndSettle();
    expect(library.visible.map((t) => t.title), ['Песня 1', 'Песня 2']);
    // The bar closes: VK is told, the copy alone goes.
    await closeBar(tester);
    expect(vk.keysOf(mine), ['10000_1', '10000_2']);
  });

  testWidgets('Remove from this playlist: Undo brings the row back and '
      'tells VK nothing', (tester) async {
    await openApp(tester);
    await openPlaylist(tester, 'Мой');
    await rowMenu(tester, 'Песня 2');
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-playlist')));
    await tester.pumpAndSettle();
    expect(library.visible.map((t) => t.title), ['Песня 1']);
    expect(find.text('Taken out of Мой'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-undo')));
    await tester.pumpAndSettle();
    expect(library.visible.map((t) => t.title), ['Песня 1', 'Песня 2']);
    await closeBar(tester);
    expect(vk.calls.where((c) => c.contains('removeFromPlaylist')), isEmpty);
    expect(vk.keysOf(mine), ['10000_1', '10000_2']);
  });

  testWidgets('a followed playlist: no Remove in its rows; its heading '
      'offers Unfollow, with Undo', (tester) async {
    await openApp(tester);
    await openPlaylist(tester, 'Чужой');
    await rowMenu(tester, 'Песня 8');
    expect(
      find.byKey(const ValueKey('menu-remove-from-playlist')),
      findsNothing,
    );
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlist-rename')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-unfollow')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.playlists, reason: 'back on the page');
    expect(find.byKey(const ValueKey('list-card-Чужой')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-undo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('list-card-Чужой')), findsOneWidget);
    await closeBar(tester);
    expect(vk.playlists.map((l) => l.title), contains('Чужой'));
  });

  testWidgets('Rename shows the new name in the heading; Delete asks, then '
      'goes back and the playlist is gone on VK', (tester) async {
    await openApp(tester);
    await openPlaylist(tester, 'Мой');
    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      'Новое имя',
    );
    await tester.tap(find.byKey(const ValueKey('playlist-name-ok')));
    await tester.pumpAndSettle();
    expect(mine.title, 'Новое имя');
    expect(find.text('Новое имя'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Новое имя?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-delete-yes')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.playlists);
    expect(vk.playlists.map((l) => l.title), ['Чужой']);
    expect(find.byKey(const ValueKey('list-card-Новое имя')), findsNothing);
    expect(find.text('Deleted Новое имя'), findsOneWidget);
  });

  /// Drags the row [from] of the open list by its handle [rows] rows down
  /// (up when negative), in small steps as a mouse does.
  Future<void> dragRow(WidgetTester tester, int from, double rows) async {
    final handle = find.byKey(
      ValueKey('drag-entry-${library.entryIdAt(from)}'),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    const steps = 12;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, rows * rowHeight / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
  }

  List<String> titles() => [for (final t in library.visible) t.title];

  testWidgets('a made playlist\'s rows move by their handle: the row goes '
      'there at once and VK gets the move by key', (tester) async {
    mine.songs.add(vk.known['10000_3']!);
    await openApp(tester);
    await openPlaylist(tester, 'Мой');
    expect(titles(), ['Песня 1', 'Песня 2', 'Песня 3']);
    // The last row to the top: named before the first one.
    await dragRow(tester, 2, -2.2);
    expect(titles(), ['Песня 3', 'Песня 1', 'Песня 2']);
    expect(vk.keysOf(mine), ['10000_3', '10000_1', '10000_2']);
    expect(find.text('VK did not move the song'), findsNothing);
    // The first row to the bottom: named after the last one.
    await dragRow(tester, 0, 2.6);
    expect(vk.keysOf(mine), ['10000_1', '10000_2', '10000_3']);
    expect(titles(), ['Песня 1', 'Песня 2', 'Песня 3']);
  });

  testWidgets('two copies of one library song: the drag moves the copy '
      'that was dragged', (tester) async {
    mine.songs.add(vk.song(10000, 50, trackId: 101));
    await openApp(tester);
    await openPlaylist(tester, 'Мой');
    expect(titles(), ['Песня 1', 'Песня 2', 'Песня 1']);
    await dragRow(tester, 2, -2.2);
    expect(vk.keysOf(mine), ['10000_50', '10000_1', '10000_2']);
  });

  testWidgets('no handles in a followed playlist, or while a search '
      'narrows a made one', (tester) async {
    await openApp(tester);
    await openPlaylist(tester, 'Чужой');
    expect(find.byKey(const ValueKey('playlist-reorder')), findsNothing);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('list-card-Мой')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    library.searchText.text = '2';
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(titles(), ['Песня 2']);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });

  testWidgets('the Playlists page\'s New playlist makes one and opens it', (
    tester,
  ) async {
    await openApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlists-new-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      'Пустой',
    );
    await tester.tap(find.byKey(const ValueKey('playlist-name-ok')));
    await tester.pumpAndSettle();
    expect(vk.playlists.first.title, 'Пустой');
    expect(library.view.kind, ViewKind.vkList);
    expect(find.text('Пустой'), findsWidgets);
  });
}
