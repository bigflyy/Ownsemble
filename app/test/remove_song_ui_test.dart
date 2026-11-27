// Widget tests for Remove from library (plan 06, C5): the row menu offers
// it, the row slides out, a note offers Undo for 6 s and Undo brings the row
// back; a failure keeps the row and says why; a found song you have removes
// your copy; a song in two accounts offers both or one.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/song_remover.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/vk/vk_sync.dart';

import 'catalog_support.dart';
import 'merge_support.dart';

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late SongRemover remover;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;
  late int romance;

  void reload() {
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    sources.value = store.sources();
  }

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    final ids = store.upsertAll(source, [
      vkItemToTrack(vkAudio(42, 1, title: 'Группа крови', duration: 285)),
      vkItemToTrack(vkAudio(42, 2, artist: 'Сплин', title: 'Романс')),
    ]);
    romance = ids[1];
    vk = FakeVk(42)
      ..catalog.addAll([
        vkAudio(-7, 10, title: 'Группа крови', duration: 286),
        vkAudio(-7, 11, title: 'Кукушка', duration: 400),
      ]);
    library = LibraryController(
      store.loadAll(),
      removedSongs: store.loadRemoved,
    );
    sources = ValueNotifier(store.sources());
    playback = PlaybackController(player: ShowingPlayer());
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: ({required severalAccounts}) => reload(),
    );
    remover = SongRemover(
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: reload,
    );
  });
  tearDown(() {
    remover.dispose();
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
            remover: remover,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets the note at the bottom finish sliding in; its 6 s start then.
  Future<void> noteIn(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Right-clicks the row [rowKey] and waits for its menu.
  Future<void> openMenu(WidgetTester tester, String rowKey) async {
    await tester.tap(
      find.byKey(ValueKey(rowKey)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Remove slides the row out, the note offers Undo, Undo '
      'brings the same row back with a flash', (tester) async {
    await pumpScreen(tester);
    await openMenu(tester, 'song-$romance');
    expect(find.text('Remove from library'), findsOneWidget);
    // One account: nothing to choose between.
    expect(find.textContaining(' only'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-library')));
    await tester.pump();
    expect(vk.edits, ['audio.delete 42_2']);
    expect(tester.widget<LeavingRow>(rowFinder(romance)).leaving, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(rowFinder(romance), findsNothing);
    expect(library.visible.map((t) => t.title), ['Группа крови']);
    expect(find.text('Removed "Романс" from Мой VK'), findsOneWidget);
    await noteIn(tester);
    await tester.tap(find.byKey(const ValueKey('note-undo')));
    await tester.pump();
    await tester.pump();
    expect(vk.edits, ['audio.delete 42_2', 'audio.restore 42_2']);
    expect(rowFinder(romance), findsOneWidget);
    expect(tester.widget<LeavingRow>(rowFinder(romance)).flashing, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<LeavingRow>(rowFinder(romance)).flashing, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('the Undo note closes by itself after 6 s', (tester) async {
    await pumpScreen(tester);
    await openMenu(tester, 'song-$romance');
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-library')));
    await tester.pump(const Duration(milliseconds: 300));
    await noteIn(tester);
    expect(find.byKey(const ValueKey('note-undo')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('note-undo')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-undo')), findsNothing);
    expect(library.visible.map((t) => t.title), ['Группа крови']);
  });

  testWidgets('VK refusing keeps the row and says why, with no Undo', (
    tester,
  ) async {
    vk.refuseDelete = true;
    await pumpScreen(tester);
    await openMenu(tester, 'song-$romance');
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(rowFinder(romance), findsOneWidget);
    expect(tester.widget<LeavingRow>(rowFinder(romance)).leaving, isFalse);
    expect(
      find.text('"Романс" not removed: Мой VK: VK did not remove it'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('note-undo')), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('a found song you have removes your copy; the found row '
      'offers + again', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(EditableText), 'кино');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    final blood = catalog.songs.first;
    final row = find.byKey(ValueKey('found-${blood.track.id}'));
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('song-added')),
      ),
      findsOneWidget,
    );
    await openMenu(tester, 'found-${blood.track.id}');
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(vk.edits, ['audio.delete 42_1']);
    expect(find.text('Removed "Группа крови" from Мой VK'), findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('add-song')),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 7));
  });

  testWidgets('a song in two accounts offers both or one', (tester) async {
    final other = store.ensureSource(
      TrackSource.vk,
      account: '43',
      name: 'Рабочий',
    );
    store.upsertAll(other, [
      vkItemToTrack(vkAudio(43, 2, artist: 'Сплин', title: 'Романс')),
    ]);
    mergeSameFiles(store);
    reload();
    final merged = library.all.firstWhere((t) => t.title == 'Романс');
    expect(merged.copies, hasLength(1));
    await pumpScreen(tester);
    await openMenu(tester, 'song-${merged.id}');
    expect(find.text('Remove from library'), findsOneWidget);
    expect(find.text('Remove from Мой VK only'), findsOneWidget);
    expect(find.text('Remove from Рабочий only'), findsOneWidget);
    // Рабочий is not logged in here: removing from it alone fails, and the
    // song stays as it was.
    await tester.tap(find.byKey(ValueKey('menu-remove-from-$other')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('"Романс" not removed: Рабочий: not logged in'),
      findsOneWidget,
    );
    expect(
      library.all.firstWhere((t) => t.id == merged.id).copies,
      hasLength(1),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  // Plan 06, E2: a song only another account has is added to your own.
  testWidgets('a song only another account has offers Add to your account '
      'on VK; after it the row has both accounts', (tester) async {
    final other = store.ensureSource(
      TrackSource.vk,
      account: '43',
      name: 'Рабочий',
    );
    final theirs = store.upsertAll(other, [
      vkItemToTrack(vkAudio(43, 7, artist: 'Сплин', title: 'Выхода нет')),
    ]).single;
    reload();
    await pumpScreen(tester);
    await openMenu(tester, 'song-$theirs');
    expect(find.text('Add to Мой VK on VK'), findsOneWidget);
    // Рабочий is not logged in here, so its own songs offer no add to it.
    expect(find.textContaining('Add to Рабочий'), findsNothing);
    await tester.tap(find.byKey(ValueKey('menu-add-to-$source')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(vk.adds, ['43_7 key7']);
    expect(find.text('Added "Выхода нет" to Мой VK'), findsOneWidget);
    final row = library.all.firstWhere((t) => t.title == 'Выхода нет');
    expect(row.id, theirs);
    expect([for (final c in row.allCopies) c.sourceId], [other, source]);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await openMenu(tester, 'song-$theirs');
    expect(find.byKey(ValueKey('menu-add-to-$source')), findsNothing);
    expect(find.text('Remove from Мой VK only'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    // Your own songs offer no add: the logged-in account has them.
    await openMenu(tester, 'song-$romance');
    expect(find.byKey(ValueKey('menu-add-to-$source')), findsNothing);
    expect(find.byKey(ValueKey('menu-add-to-$other')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}

/// The row of the listed song [id].
Finder rowFinder(int id) => find.byKey(ValueKey('song-$id'));
