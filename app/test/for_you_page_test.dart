// Widget tests for the For you place (plan 07, C3): the page from VK's
// recorded replies, a list opened as an ordinary song list with the
// library's own song in its place and + on the others, songs VK gives no
// file for greyed with VK's reason, VK Mix with the thumb-down, and
// "Similar songs" from a row's menu (C5).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';

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
    forYou = ForYou(
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? call : null,
      libraryCopyOfSong: catalog.libraryCopyOfSong,
    );
    library.vkLists = forYou;
    recsMixRound = 1;
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  Future<void> openForYou(WidgetTester tester, {double width = 1400}) async {
    tester.view.physicalSize = Size(width, 900);
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
            // The side panel: Similar songs shows there, not in the bar.
            settings: ShellSettings.inMemory()..dockTo(PlayerDock.side),
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
    await tester.tap(find.byKey(const ValueKey('list-play-For you')));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byKey(const ValueKey('list-play-For you')));
    await tester.pumpAndSettle();
    // The first song is the library's own: Similar, no thumb-down.
    expect(find.byKey(const ValueKey('player-dislike')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-similar')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.vkList);
    expect(library.view.album?.title, 'Similar to Закрой за мной дверь');
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('narrow: the cards wrap and nothing overflows', (tester) async {
    await openForYou(tester, width: 760);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('list-card-Daily playlist 4')), findsOne);
  });
}

/// Which VK Mix call the fake answers.
var recsMixRound = 1;
