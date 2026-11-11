// Widget tests for the On VK part under the own search results (plan 06,
// C3): it fills in after the pause, a found song the library has shows the
// check, + adds and turns into the check, the header folds the part, and a
// search none of the own songs match still shows what VK found.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/vk/vk_sync.dart';

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

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    store.upsertAll(source, [
      vkItemToTrack(vkAudio(42, 1, title: 'Группа крови', duration: 285)),
      vkItemToTrack(vkAudio(42, 2, artist: 'Сплин', title: 'Романс')),
    ]);
    vk = FakeVk(42)
      ..catalog.addAll([
        vkAudio(-7, 10, title: 'Группа крови', duration: 286),
        vkAudio(-7, 11, title: 'Кукушка', duration: 400),
        vkAudio(-7, 12, title: 'Пачка сигарет', duration: 268),
      ]);
    library = LibraryController(store.loadAll());
    sources = ValueNotifier(store.sources());
    player = ShowingPlayer();
    playback = PlaybackController(player: player);
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

  Finder inRow(FoundSong found, String key) => find.descendant(
    of: find.byKey(ValueKey('found-${found.track.id}')),
    matching: find.byKey(ValueKey(key)),
  );

  testWidgets('the part fills in under the own results after the pause; a '
      'song you have shows the check, the others +', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(EditableText), 'кино');
    await tester.pump();
    // At once: own results and the header, searching.
    expect(find.text('Группа крови'), findsOneWidget);
    expect(find.text('ON VK'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-searching')), findsOneWidget);
    expect(vk.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(vk.searches, ['кино@0']);
    expect(find.text('3 found'), findsOneWidget);
    final found = catalog.songs;
    expect(inRow(found[0], 'song-added'), findsOneWidget);
    expect(inRow(found[1], 'add-song'), findsOneWidget);
    expect(inRow(found[2], 'add-song'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-searching')), findsNothing);
  });

  testWidgets('+ adds the song: the check comes in, a note says where it '
      'went, and the own results get the song', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'кино');
    final cuckoo = catalog.songs[1];
    await tester.tap(inRow(cuckoo, 'add-song'));
    await tester.pump();
    expect(vk.adds, ['-7_11 key11']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(inRow(cuckoo, 'song-added'), findsOneWidget);
    expect(find.text('Added "Кукушка" to Мой VK'), findsOneWidget);
    // The lists reload once the animation is over.
    await tester.pump(const Duration(milliseconds: 400));
    expect(library.visible.map((t) => t.title), contains('Кукушка'));
    expect(inRow(cuckoo, 'song-added'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a found song + adds while it plays keeps its playing mark, '
      'and a click on it still pauses', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'кино');
    final cuckoo = catalog.songs[1];
    await tester.tap(find.byKey(ValueKey('found-${cuckoo.track.id}')));
    await tester.pump();
    await tester.pump();
    expect(player.current?.id, cuckoo.track.id);
    expect(inRow(cuckoo, 'playing-bars'), findsOneWidget);
    await tester.tap(inRow(cuckoo, 'add-song'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    // The player has the library's copy now, and the found row is still
    // marked as playing.
    expect(player.current?.inLibrary, isTrue);
    expect(player.current?.title, 'Кукушка');
    expect(inRow(cuckoo, 'playing-bars'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('found-${cuckoo.track.id}')));
    await tester.pump();
    expect(player.pauseToggles, 1, reason: 'paused, not started again');
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a click on the header folds the part and unfolds it', (
    tester,
  ) async {
    await pumpScreen(tester);
    await search(tester, 'кино');
    final first = catalog.songs.first;
    expect(find.byKey(ValueKey('found-${first.track.id}')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-header')));
    await tester.pump();
    expect(find.byKey(ValueKey('found-${first.track.id}')), findsNothing);
    expect(find.text('3 found'), findsOneWidget, reason: 'header stays');
    await tester.tap(find.byKey(const ValueKey('catalog-header')));
    await tester.pump();
    expect(find.byKey(ValueKey('found-${first.track.id}')), findsOneWidget);
  });

  testWidgets('your own songs have a header that folds them; the On VK part '
      'stays (C4d)', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'кино');
    final own = library.visible.single;
    final ownRow = find.byKey(ValueKey('song-${own.id}'));
    expect(find.text('IN YOUR LIBRARY'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('own-count'))).data,
      '1 song',
    );
    expect(ownRow, findsOneWidget);
    // The header is the first row, the own song the second.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('own-header'))).dy,
      lessThan(tester.getTopLeft(ownRow).dy),
    );
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    expect(catalog.ownFolded, isTrue);
    expect(ownRow, findsNothing);
    expect(find.text('IN YOUR LIBRARY'), findsOneWidget, reason: 'stays');
    final first = catalog.songs.first;
    expect(find.byKey(ValueKey('found-${first.track.id}')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    expect(catalog.ownFolded, isFalse);
    expect(ownRow, findsOneWidget);
  });

  testWidgets('folding your own songs is remembered: a new search and a new '
      'start keep it, as for the On VK part', (tester) async {
    final settings = <String, String?>{};
    catalog.dispose();
    CatalogSearch make() => CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: ({required severalAccounts}) {},
      readSetting: (key) => settings[key],
      writeSetting: (key, value) => settings[key] = value,
    );
    catalog = make();
    await pumpScreen(tester);
    await search(tester, 'кино');
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    expect(settings[catalogOwnFoldedSetting], 'folded');
    await search(tester, 'сплин');
    expect(catalog.ownFolded, isTrue, reason: 'a new search keeps it');
    expect(find.text('Романс'), findsNothing);
    // A new start reads it back.
    catalog.dispose();
    catalog = make();
    expect(catalog.ownFolded, isTrue);
    // Its search of the words in the box runs out.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('no header when none of your songs match, and a jump to an '
      'own song unfolds them', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'кино');
    expect(library.rowsAbove, 1, reason: 'the header row');
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    // Typing on the list jumps to an own song, which must be seen.
    library.jump.type('г');
    await tester.pump();
    expect(library.jump.row, 0);
    expect(catalog.ownFolded, isFalse, reason: 'a jump to a row unfolds');
    await search(tester, 'кукушка');
    expect(library.visible, isEmpty);
    expect(find.byKey(const ValueKey('own-header')), findsNothing);
    expect(find.byKey(const ValueKey('catalog-no-own')), findsOneWidget);
    expect(library.rowsAbove, 0);
  });

  testWidgets('when none of your songs match, VK still shows what it found', (
    tester,
  ) async {
    await pumpScreen(tester);
    await search(tester, 'кукушка');
    expect(find.byKey(const ValueKey('catalog-no-own')), findsOneWidget);
    expect(find.text('None of your songs match "кукушка"'), findsOneWidget);
    expect(find.text('3 found'), findsOneWidget);
  });

  testWidgets('one letter shows no part', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'к');
    expect(find.text('ON VK'), findsNothing);
    expect(vk.searches, isEmpty);
  });
}
