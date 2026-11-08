// Tests for the On VK part of search place A (plan 06, C3): VK is asked only
// after a pause in typing, answers are kept per query, found songs the
// library has show a check, + adds to the ticked accounts (VK and the
// library), and a refused add changes nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/vk/vk_sync.dart';

import 'catalog_support.dart';

void main() {
  late LibraryStore store;
  late int first;
  late int second;
  late FakeVk vk1;
  late FakeVk vk2;
  late LibraryController library;
  late ValueNotifier<List<SourceInfo>> sources;
  late Map<String, String?> settings;
  late int reloads;
  late List<bool> reloadsForSeveral;
  late CatalogSearch catalog;
  late bool secondLoggedIn;

  /// A pause short enough for tests, still longer than a keystroke here.
  const pause = Duration(milliseconds: 40);

  CatalogSearch makeCatalog() => CatalogSearch(
    library: library,
    store: store,
    sources: sources,
    apiOfSource: (id) => id == first
        ? vk1.call
        : id == second && secondLoggedIn
        ? vk2.call
        : null,
    onLibraryChanged: ({required severalAccounts}) {
      reloads++;
      reloadsForSeveral.add(severalAccounts);
      final tracks = store.loadAll();
      library.replaceTracks(tracks, SearchIndex(tracks));
    },
    readSetting: (key) => settings[key],
    writeSetting: (key, value) => settings[key] = value,
    pause: pause,
    reloadAfter: const Duration(milliseconds: 10),
  );

  setUp(() {
    store = LibraryStore.open(':memory:');
    first = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    vk1 = FakeVk(42);
    vk2 = FakeVk(43);
    secondLoggedIn = false;
    second = store.ensureSource(TrackSource.vk, account: '43', name: 'Рабочий');
    final tracks = store.loadAll();
    library = LibraryController(tracks);
    sources = ValueNotifier(store.sources());
    settings = {};
    reloads = 0;
    reloadsForSeveral = [];
    catalog = makeCatalog();
  });

  tearDown(() {
    catalog.dispose();
    library.dispose();
    store.close();
  });

  /// Types [text] one letter at a time, faster than the pause.
  Future<void> type(String text) async {
    for (var length = 1; length <= text.length; length++) {
      library.searchText.text = text.substring(0, length);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// Waits out the pause and VK's (instant) answer.
  Future<void> settle() =>
      Future<void>.delayed(pause + const Duration(milliseconds: 60));

  group('asking VK', () {
    test('only after a pause in typing, once, for the words typed', () async {
      vk1.catalog.addAll([
        vkAudio(-1, 1),
        vkAudio(-1, 2, title: 'Группа крови'),
      ]);
      await type('кино');
      expect(vk1.searches, isEmpty, reason: 'no search while typing');
      expect(catalog.active, isTrue);
      expect(catalog.searching, isTrue);
      await settle();
      expect(vk1.searches, ['кино@0']);
      expect(catalog.searching, isFalse);
      expect(catalog.total, 2);
      expect(
        [for (final f in catalog.songs) f.track.title],
        ['Звезда по имени Солнце', 'Группа крови'],
      );
      // Outside the library, streamed through the searching account.
      for (final found in catalog.songs) {
        expect(found.track.inLibrary, isFalse);
        expect(found.track.sourceId, first);
        expect(catalog.foundById(found.track.id), same(found));
      }
    });

    test('one letter, or a view other than Songs, asks nothing', () async {
      await type('к');
      await settle();
      expect(catalog.active, isFalse);
      library.searchText.text = 'кино';
      library.showView(const LibraryView(ViewKind.favorites));
      await settle();
      expect(catalog.active, isFalse);
      expect(vk1.searches, isEmpty);
    });

    test('no logged-in account: no part', () async {
      catalog.dispose();
      catalog = CatalogSearch(
        library: library,
        store: store,
        sources: sources,
        apiOfSource: (_) => null,
        onLibraryChanged: ({required severalAccounts}) {},
        pause: pause,
      );
      await type('кино');
      await settle();
      expect(catalog.active, isFalse);
    });

    test('Backspace back to an earlier query asks VK nothing again', () async {
      vk1.catalog.add(vkAudio(-1, 1));
      await type('кино');
      await settle();
      library.searchText.text = 'кинол';
      await settle();
      library.searchText.text = 'кино';
      await settle();
      expect(vk1.searches, ['кино@0', 'кинол@0']);
      expect(catalog.songs, hasLength(1));
    });

    test('Show more appends the next page; a page with nothing new ends '
        'the list', () async {
      for (var i = 1; i <= 60; i++) {
        vk1.catalog.add(vkAudio(-1, i, title: 'Песня $i'));
      }
      await type('песня');
      await settle();
      expect(catalog.songs, hasLength(50));
      expect(catalog.hasMore, isTrue);
      expect(catalog.moreCount, 10);
      catalog.showMore();
      expect(catalog.loadingMore, isTrue);
      await settle();
      expect(catalog.songs, hasLength(60));
      expect(catalog.hasMore, isFalse);
      expect(vk1.searches, ['песня@0', 'песня@50']);
    });

    test('a failed search says why, and Try again asks again', () async {
      vk1.catalog.add(vkAudio(-1, 1));
      vk1.searchFails = Exception('boom');
      await type('кино');
      await settle();
      expect(catalog.error, isNotNull);
      expect(catalog.total, isNull);
      catalog.retry();
      await settle();
      expect(catalog.error, isNull);
      expect(catalog.songs, hasLength(1));
    });
  });

  group('songs the library has', () {
    test('show a check, in the account that has them; others show +', () async {
      // The account's own copy, and another upload of a song it has.
      store.upsertAll(first, [
        vkItemToTrack(vkAudio(42, 5, title: 'Кукушка', duration: 400)),
        vkItemToTrack(vkAudio(42, 6, title: 'Пачка сигарет', duration: 268)),
      ]);
      final tracks = store.loadAll();
      library.replaceTracks(tracks, SearchIndex(tracks));
      vk1.catalog.addAll([
        vkAudio(42, 5, title: 'Кукушка', duration: 400),
        vkAudio(-7, 1, title: 'Пачка сигарет', duration: 269),
        vkAudio(-7, 2, title: 'Пачка сигарет', duration: 300),
        vkAudio(-7, 3, title: 'Кончится лето'),
      ]);
      await type('кино');
      await settle();
      final states = [for (final f in catalog.songs) catalog.stateOf(f)];
      expect(states, [
        FoundState.inLibrary,
        FoundState.inLibrary,
        // Same name, 32 s longer: another cut, addable.
        FoundState.addable,
        FoundState.addable,
      ]);
      expect(catalog.haveSources(catalog.songs[0]), [first]);
      expect(catalog.haveSources(catalog.songs[3]), isEmpty);
    });
  });

  group('adding', () {
    test('+ adds to VK and puts the row in under the new key; the lists '
        'reload after the animation', () async {
      vk1.catalog.add(vkAudio(-7, 3, title: 'Кончится лето', trackId: 77));
      await type('кино');
      await settle();
      final found = catalog.songs.single;
      final adding = catalog.add(found);
      expect(catalog.stateOf(found), FoundState.adding);
      final note = await adding;
      expect(note, 'Added "Кончится лето" to Мой VK');
      expect(vk1.adds, ['-7_3 key3']);
      expect(catalog.stateOf(found), FoundState.inLibrary);
      expect(catalog.haveSources(found), [first]);
      expect(reloads, 0, reason: 'not inside the animation');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reloads, 1);
      expect(reloadsForSeveral, [false]);
      final row = library.all.single;
      expect(row.title, 'Кончится лето');
      expect(row.sourceKey, '42_900');
      expect(row.sourceId, first);
      // Still a check after the reload, now through the library.
      expect(catalog.stateOf(found), FoundState.inLibrary);
      // A second click adds nothing.
      expect(await catalog.add(found), 'Already in your library');
      expect(vk1.adds, hasLength(1));
    });

    test('a refused add stores nothing and says why', () async {
      vk1.catalog.add(vkAudio(-7, 3));
      vk1.refuseWith = '15;Access denied';
      await type('кино');
      await settle();
      final found = catalog.songs.single;
      final note = await catalog.add(found);
      expect(note, contains('not added'));
      expect(note, contains('no access'));
      expect(catalog.stateOf(found), FoundState.addable);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reloads, 0);
      expect(store.loadAll(), isEmpty);
    });

    test('with two accounts ticked, + adds to each, and asks for the sync '
        'that merges the copies', () async {
      secondLoggedIn = true;
      sources.value = store.sources();
      expect(catalog.accounts.map((s) => s.id), [first, second]);
      catalog.toggleTarget(second);
      expect(catalog.allTicked, isTrue, reason: 'both = All');
      vk1.catalog.add(vkAudio(-7, 3, title: 'Кончится лето', trackId: 77));
      await type('кино');
      await settle();
      final found = catalog.songs.single;
      expect(
        await catalog.add(found),
        'Added "Кончится лето" to Мой VK and Рабочий',
      );
      expect(vk1.adds, ['-7_3 key3']);
      expect(vk2.adds, ['-7_3 key3']);
      expect(catalog.haveSources(found), [first, second]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reloadsForSeveral, [true]);
      // Until that sync reads both files, each account lists its copy.
      expect(
        {for (final track in library.all) track.sourceId},
        {first, second},
      );
      expect(
        {for (final track in library.all) track.sourceKey},
        {'42_900', '43_900'},
      );
    });
  });

  group('the account toggle', () {
    test('defaults to the first account; the last ticked one stays; All '
        'and back; kept in the settings', () {
      secondLoggedIn = true;
      sources.value = store.sources();
      expect(catalog.targets.map((s) => s.id), [first]);
      catalog.toggleTarget(first);
      expect(catalog.targets.map((s) => s.id), [first], reason: 'last stays');
      catalog.onlyTarget(second);
      expect(catalog.targets.map((s) => s.id), [second]);
      expect(settings[catalogTargetsSetting], '$second');
      catalog.toggleAll();
      expect(catalog.allTicked, isTrue);
      expect(settings[catalogTargetsSetting], 'all');
      catalog.toggleAll();
      expect(catalog.targets.map((s) => s.id), [first]);
      catalog.onlyTarget(second);
      final again = makeCatalog();
      expect(again.targets.map((s) => s.id), [second]);
      again.dispose();
    });

    test('a ticked account that logged out drops out', () {
      secondLoggedIn = true;
      sources.value = store.sources();
      catalog.onlyTarget(second);
      secondLoggedIn = false;
      sources.value = store.sources();
      expect(catalog.targets.map((s) => s.id), [first]);
    });

    test('folding is kept', () {
      expect(catalog.folded, isFalse);
      catalog.toggleFolded();
      expect(settings[catalogFoldedSetting], 'folded');
      final again = makeCatalog();
      expect(again.folded, isTrue);
      again.dispose();
    });
  });
}
