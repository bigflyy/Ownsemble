// Widget tests for the For you place (plan 07, C3): the page from VK's
// recorded replies, a list opened as an ordinary song list with the
// library's own song in its place and + on the others, songs VK gives no
// file for greyed with VK's reason, VK Mix with the thumb-down, and
// "Similar songs" from a row's menu (C5), and the own "Similar to" shelves
// picked from the library's History and Favorites (Stage E).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/similar_seeds.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';

import 'card_support.dart';
import 'catalog_support.dart';
import 'recs_support.dart';

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late RecsVk recs;
  late LibraryController library;
  late CatalogSearch catalog;
  late ForYou forYou;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;
  late ShowingPlayer player;
  late ForYou Function({
    List<SimilarSeed> Function({required Set<String> skipTitles})? seedsOf,
  })
  makeForYou;

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    // The library has the first song of the recorded "For you" list, as
    // its own upload with another key: the row is the library's song.
    store.upsertAll(source, [
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Кино',
        title: 'Закрой за мной дверь',
        durationSec: 205,
        addedAt: 2,
      ),
    ]);
    vk = FakeVk(42);
    recs = RecsVk(
      overrides: {
        // Two of the list's songs VK gives no file for (codes 2 and 3).
        'audio.get': (params) {
          final reply = Map<String, dynamic>.of(
            recFixture('audio_get_generated_playlist') as Map<String, dynamic>,
          );
          reply['items'] = [
            ...(reply['items'] as List),
            recSong(-7, 70, title: 'Не в регионе', restricted: 2),
            recSong(-7, 71, title: 'По подписке', restricted: 3),
          ];
          return reply;
        },
        'audio.getStreamMixAudios': (_) => [
          recSong(-8, 80 + recsMixRound, title: 'Микс $recsMixRound'),
          recSong(-8, 90 + recsMixRound++, title: 'Микс б'),
        ],
      },
    );
    Future<Object?> call(String method, Map<String, String> params) =>
        method == 'audio.search' ||
            method.startsWith('audio.add') && method != 'audio.addDislike'
        ? vk.call(method, params)
        : recs.call(method, params);
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
    makeForYou = ({seedsOf}) => ForYou(
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? call : null,
      libraryCopyOfSong: catalog.libraryCopyOfSong,
      seedsOf: seedsOf,
    );
    forYou = makeForYou();
    library.vkLists = forYou;
    recsMixRound = 1;
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  Future<void> openForYou(
    WidgetTester tester, {
    double width = 1400,
    double height = 900,
    LyricsController? lyrics,
    PlayerDock dock = PlayerDock.side,
    CollectionsController? collections,
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
            forYou: forYou,
            lyrics: lyrics,
            collections: collections,
            // The side panel: Similar songs shows there, not in the bar.
            settings: ShellSettings.inMemory()..dockTo(dock),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-forYou')));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('the page shows VK Mix, the seven lists and Similar to', (
    tester,
  ) async {
    await openForYou(tester);
    expect(find.byKey(const ValueKey('vk-mix-card')), findsOneWidget);
    for (final name in [
      'For you',
      'Discoveries',
      'New releases',
      'Daily playlist 1',
      'Daily playlist 4',
    ]) {
      expect(find.byKey(ValueKey('list-card-$name')), findsOneWidget);
    }
    expect(find.text('SIMILAR TO ПОЙ ЖЕ, ПОЙ (LEMIUM)'), findsOneWidget);
    expect(find.textContaining('updated today'), findsOneWidget);
    expect(find.text('14 songs'), findsWidgets);
  });

  testWidgets('a card opens its list: own song, + on the others, greyed '
      'restricted songs', (tester) async {
    await openForYou(tester);
    await tester.tap(find.byKey(const ValueKey('list-card-For you')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(library.visible, hasLength(14));
    // The first song is the library's own copy (found by name and length).
    expect(library.visible.first.inLibrary, isTrue);
    expect(library.visible.skip(1).every((t) => !t.inLibrary), isTrue);
    expect(find.byKey(ValueKey('add-${library.visible[1].id}')), findsOne);
    expect(
      find.byKey(ValueKey('add-${library.visible.first.id}')),
      findsNothing,
    );
    expect(find.text('Made by VK for you.'), findsNothing);
    expect(find.textContaining('1 in your library'), findsOneWidget);
    // Scroll to the end: the two songs VK gives no file for.
    library.scroll.jumpTo(library.scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('restricted-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('restricted-3')), findsOneWidget);
    expect(find.text('Not in your region'), findsOneWidget);
    expect(find.text('Subscription only'), findsOneWidget);
    final restricted = library.visible.last;
    expect(find.byKey(ValueKey('add-${restricted.id}')), findsNothing);
  });

  testWidgets('a card\'s Play plays the list without the restricted songs', (
    tester,
  ) async {
    await openForYou(tester);
    await tapCardPlay(tester, find.byKey(const ValueKey('list-play-For you')));
    // The playing card's mark moves: nothing settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.current?.title, 'Закрой за мной дверь');
    expect(playback.queue.context, hasLength(12));
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('VK Mix plays, grows, and the thumb-down skips and tells VK', (
    tester,
  ) async {
    await openForYou(tester);
    await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
    await tester.pumpAndSettle();
    expect(player.current?.title, 'Микс 1');
    expect(forYou.isMixList(playback.queue.context), isTrue);
    // The app asks for more near the end (main.dart does it on every new
    // song); here by hand.
    playback.extendList(forYou.isMixList, await forYou.moreMix());
    expect(playback.queue.context, hasLength(4));
    await tester.tap(find.byKey(const ValueKey('player-dislike')));
    await tester.pumpAndSettle();
    expect(
      recs.calls.where((c) => c.startsWith('audio.addDislike')),
      hasLength(1),
    );
    expect(player.current?.title, 'Микс б');
    expect(find.textContaining('Skipped.'), findsOneWidget);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the smallest window keeps a VK Mix song\'s title whole: the '
      'thumb-down, + and the mic go into one More menu (B24, B25)', (
    tester,
  ) async {
    await openForYou(
      tester,
      width: 480,
      height: 440,
      dock: PlayerDock.bottom,
      lyrics: LyricsController(
        load: (source, ref) => null,
        save: (source, ref, lyrics, {md5, meta}) {},
        routeOf: lyricsRouteBySource((sourceId) => null),
      ),
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'the page while VK answers fits too',
    );
    await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
    await tester.pumpAndSettle();
    expect(player.current?.title, 'Микс 1');
    playback.extendList(forYou.isMixList, await forYou.moreMix());
    final title = find.descendant(
      of: find.byType(DockBar),
      matching: find.text('Микс 1'),
    );
    expect(title, findsWidgets);
    expect(
      tester.renderObject<RenderParagraph>(title.first).didExceedMaxLines,
      isFalse,
      reason: 'B25: the title was squeezed to 16 px',
    );
    expect(find.byKey(const ValueKey('player-dislike')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics')), findsNothing);
    expect(find.byKey(const ValueKey('player-more')), findsOneWidget);
    expect(tester.takeException(), isNull);

    expect(
      find.byKey(const ValueKey('up-next-open')),
      findsNothing,
      reason: 'B26: Up next is in More too',
    );

    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    expect(find.text('Up next'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    await tester.tap(find.text("Don't like it"));
    await tester.pumpAndSettle();
    expect(
      recs.calls.where((c) => c.startsWith('audio.addDislike')),
      hasLength(1),
    );
    expect(player.current?.title, isNot('Микс 1'));

    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.lyrics);
    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    expect(find.text('Close lyrics'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the smallest window gives a library song\'s title room: Up '
      'next and the mic go into More, the heart stays; 700 px keeps them '
      '(B26)', (tester) async {
    LyricsController lyricsController() => LyricsController(
      load: (source, ref) => null,
      save: (source, ref, lyrics, {md5, meta}) {},
      routeOf: lyricsRouteBySource((sourceId) => null),
    );
    final own = store.loadAll().firstWhere((t) => t.sourceKey == '42_1');
    for (final (width, foldedWanted) in [(480.0, true), (700.0, false)]) {
      await openForYou(
        tester,
        width: width,
        height: 440,
        dock: PlayerDock.bottom,
        lyrics: lyricsController(),
        collections: CollectionsController(store),
      );
      await playback.playFrom([own], 0);
      await playback.addToQueue(own);
      await tester.pumpAndSettle();
      final title = find.descendant(
        of: find.byType(DockBar),
        matching: find.text('Закрой за мной дверь'),
      );
      expect(title, findsWidgets);
      expect(find.byKey(const ValueKey('player-heart')), findsOneWidget);
      expect(
        tester.getSize(title.first).width,
        greaterThanOrEqualTo(100),
        reason: 'at $width px the title kept about 60 px (B26)',
      );
      expect(
        find.byKey(const ValueKey('player-more')),
        foldedWanted ? findsOneWidget : findsNothing,
        reason: '$width px',
      );
      expect(
        find.byKey(const ValueKey('up-next-open')),
        foldedWanted ? findsNothing : findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lyrics')),
        foldedWanted ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    await openForYou(
      tester,
      width: 480,
      height: 440,
      dock: PlayerDock.bottom,
      lyrics: lyricsController(),
      collections: CollectionsController(store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    final upNext = 'Up next (${playback.queue.queued.length})';
    expect(playback.queue.queued, isNotEmpty);
    expect(find.text(upNext), findsOneWidget, reason: 'the queued count');
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text("Don't like it"), findsNothing);
    await tester.tap(find.text(upNext));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queued-0')), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.lyrics);
    expect(tester.takeException(), isNull);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a 760 px window folds a VK Mix song\'s thumb-down and + '
      'into More beside the sidebar; a wide one keeps them (B25)', (
    tester,
  ) async {
    await openForYou(tester, width: 760, height: 640, dock: PlayerDock.bottom);
    await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
    await tester.pumpAndSettle();
    final title = find.descendant(
      of: find.byType(DockBar),
      matching: find.text('Микс 1'),
    );
    expect(
      tester.renderObject<RenderParagraph>(title.first).didExceedMaxLines,
      isFalse,
      reason: 'the 760 px bar left the title one letter',
    );
    expect(find.byKey(const ValueKey('player-dislike')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-more')));
    await tester.pumpAndSettle();
    expect(find.text("Don't like it"), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
    expect(
      find.text('Lyrics'),
      findsNothing,
      reason: 'the mic is on the right',
    );
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));

    await openForYou(tester, width: 1400, height: 900, dock: PlayerDock.bottom);
    await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-dislike')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-more')), findsNothing);
    expect(tester.takeException(), isNull);
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Similar songs from a library song\'s menu opens a list', (
    tester,
  ) async {
    await openForYou(tester);
    await tester.tap(find.byKey(const ValueKey('nav-songs')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Закрой за мной дверь').first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-similar')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(library.view.album?.title, 'Similar to Закрой за мной дверь');
    expect(library.visible, hasLength(12));
    expect(recs.calls.last, contains('target_audio=42_1'));
    expect(find.byKey(const ValueKey('list-more')), findsOneWidget);
  });

  testWidgets('the player offers Similar songs for the song playing', (
    tester,
  ) async {
    await openForYou(tester);
    await tapCardPlay(tester, find.byKey(const ValueKey('list-play-For you')));
    // The playing card's mark moves: nothing settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // The first song is the library's own: Similar, no thumb-down.
    expect(find.byKey(const ValueKey('player-dislike')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-similar')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(library.view.album?.title, 'Similar to Закрой за мной дверь');
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the owned check of a shelf row stands in the + column', (
    tester,
  ) async {
    // The library gets the shelf's first song (same name and length).
    await openForYou(tester, height: 3000);
    final first = forYou.similar.first.songs.first.song;
    store.upsertAll(source, [
      NewTrack(
        sourceKey: '42_9',
        artist: first.artist,
        title: first.title,
        durationSec: first.durationSec,
        addedAt: 4,
      ),
    ]);
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    await tester.tap(find.byKey(const ValueKey('nav-songs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-forYou')));
    await tester.pumpAndSettle();
    final check = find.byKey(const ValueKey('shelf-owned'));
    final plus = find.byKey(const ValueKey('add-song'));
    expect(check, findsOneWidget);
    expect(
      tester.getCenter(check).dx,
      closeTo(tester.getCenter(plus.last).dx, 0.5),
    );
  });

  testWidgets('narrow: the cards wrap and nothing overflows', (tester) async {
    await openForYou(tester, width: 760);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('list-card-Daily playlist 4')), findsOne);
  });

  group('own "Similar to" shelves (Stage E)', () {
    /// Gives the library a second song and the page two own shelves: the
    /// library's Kino song as the most heard one and the second song as a
    /// favorite not heard in a while.
    void withOwnShelves({String second = 'Романс'}) {
      store.upsertAll(source, [
        NewTrack(
          sourceKey: '42_2',
          artist: 'Сплин',
          title: second,
          durationSec: 230,
          addedAt: 3,
        ),
      ]);
      final tracks = store.loadAll();
      library.replaceTracks(tracks, SearchIndex(tracks));
      Track byKey(String key) => tracks.firstWhere((t) => t.sourceKey == key);
      forYou = makeForYou(
        seedsOf: ({required skipTitles}) => [
          (kind: SimilarSeedKind.mostHeard, track: byKey('42_1')),
          (kind: SimilarSeedKind.rediscover, track: byKey('42_2')),
        ],
      );
      library.vkLists = forYou;
    }

    double topOf(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    Finder shelfRows() => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('shelf-row-'),
    );

    testWidgets('they come after VK\'s own shelf, each with why it is there', (
      tester,
    ) async {
      withOwnShelves();
      // Tall enough to build the whole page at once.
      await openForYou(tester, height: 3000);
      const vkShelf = 'SIMILAR TO ПОЙ ЖЕ, ПОЙ (LEMIUM)';
      const kino = 'SIMILAR TO ЗАКРОЙ ЗА МНОЙ ДВЕРЬ';
      const splin = 'SIMILAR TO РОМАНС';
      expect(find.text(vkShelf), findsOneWidget);
      expect(find.text(kino), findsOneWidget);
      expect(find.text(splin), findsOneWidget);
      expect(find.text('Picked by VK'), findsOneWidget);
      expect(find.text('You play it a lot lately'), findsOneWidget);
      expect(
        find.text('One of your favorites, not heard in a while'),
        findsOneWidget,
      );
      expect(topOf(tester, vkShelf), lessThan(topOf(tester, kino)));
      expect(topOf(tester, kino), lessThan(topOf(tester, splin)));
      // Three rows a shelf (VK's and two own), Show all for the rest.
      expect(shelfRows(), findsNWidgets(9));
      expect(
        find.byKey(const ValueKey('show-all-Similar to Романс')),
        findsOne,
      );
      // VK was asked once per seed, by the seed's own key.
      final asked = [
        for (final c in recs.calls)
          if (c.startsWith('audio.getRecommendations')) c,
      ];
      expect(asked, hasLength(2));
      expect(asked.any((c) => c.contains('target_audio=42_1')), isTrue);
      expect(asked.any((c) => c.contains('target_audio=42_2')), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no seeds: no own shelves, VK\'s shelf as before', (
      tester,
    ) async {
      forYou = makeForYou(seedsOf: ({required skipTitles}) => []);
      library.vkLists = forYou;
      await openForYou(tester, height: 3000);
      expect(find.text('SIMILAR TO ПОЙ ЖЕ, ПОЙ (LEMIUM)'), findsOneWidget);
      expect(find.text('You play it a lot lately'), findsNothing);
      expect(shelfRows(), findsNWidgets(3));
    });

    testWidgets('Show all opens the shelf as a list; a row plays the shelf', (
      tester,
    ) async {
      withOwnShelves();
      await openForYou(tester, height: 3000);
      await tester.tap(
        find.byKey(const ValueKey('show-all-Similar to Романс')),
      );
      await tester.pumpAndSettle();
      expect(library.view.kind, ViewKind.vkList);
      expect(library.view.album?.title, 'Similar to Романс');
      expect(library.visible, hasLength(12));

      await tester.tap(find.byKey(const ValueKey('nav-forYou')));
      await tester.pumpAndSettle();
      // The last shelf's first row (rows 7 to 9 are the Romance shelf's).
      final row = shelfRows().at(6);
      final key = tester.widget(row).key! as ValueKey<String>;
      final id = int.parse(key.value.substring('shelf-row-'.length));
      await tester.tap(row);
      // The playing row's bars move: pump, not settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(player.current?.id, id);
      expect(playback.queue.context, hasLength(12));
      player.playing.value = false;
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('narrow, a long title: the note and Show all still fit', (
      tester,
    ) async {
      withOwnShelves(
        second: 'Очень длинное название песни, которое не помещается в строку',
      );
      await openForYou(tester, width: 760, height: 3000);
      expect(tester.takeException(), isNull);
      expect(
        find.text('One of your favorites, not heard in a while'),
        findsOneWidget,
      );
    });
  });
}

/// Which VK Mix call the fake answers.
var recsMixRound = 1;
