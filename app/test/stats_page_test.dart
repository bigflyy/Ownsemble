import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/cover_store.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/cover_tile.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/song_filters.dart';
import 'package:ownsemble/ui/stats_page.dart';
import 'package:ownsemble/ui/theme.dart';

/// Saturday 7 November 2026.
final now = DateTime(2026, 11, 7, 14);

class _SilentCovers extends CoverStore {
  _SilentCovers() : super(dataDir: '.');

  @override
  String? storedPath(String url) => null;

  @override
  CoverRequest? fetch(String url, void Function(String? path) onDone) => null;
}

void main() {
  late LibraryStore store;
  late CollectionsController collections;
  late SongFilters filters;
  late LibraryController library;
  late PlaybackController playback;
  late ShellSettings settings;
  late Map<String, String?> saved;
  late List<int> ids;

  void play(int id, DateTime at, {double heardSec = 150}) {
    final play = store.beginPlay(
      id,
      start: PlayStart.chosen,
      shuffle: false,
      atMs: at.millisecondsSinceEpoch,
    );
    store.updatePlay(
      play,
      listenedMs: (heardSec * 1000).round(),
      ended: PlayEnd.finished,
    );
  }

  setUp(() {
    saved = {};
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    ids = store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Кино',
        title: 'Кукушка',
        album: 'Чёрный альбом',
        durationSec: 398,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 232,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_3',
        artist: 'Земфира',
        title: 'Хочешь?',
        durationSec: 226,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_4',
        artist: 'Кино',
        title: 'Группа крови',
        durationSec: 286,
        addedAt: 0,
      ),
    ]);
    // October 2025: Кукушка six times. November 2026: Выхода нет 3 times
    // (450 s), Группа крови twice (400 s), Кукушка once (300 s).
    for (var d = 1; d <= 6; d++) {
      play(ids[0], DateTime(2025, 10, d, 20), heardSec: 300);
    }
    play(ids[0], DateTime(2026, 11, 2, 9), heardSec: 300);
    for (var d = 3; d <= 5; d++) {
      play(ids[1], DateTime(2026, 11, d, 9));
    }
    play(ids[3], DateTime(2026, 11, 6, 9), heardSec: 200);
    play(ids[3], DateTime(2026, 11, 6, 10), heardSec: 200);
    collections = CollectionsController(store);
    filters = SongFilters(
      store,
      readSetting: (key) => saved[key],
      writeSetting: (key, value) => saved[key] = value,
      clock: () => now,
    );
    collections.onPlaysChanged = filters.playsChanged;
    library = LibraryController(
      store.loadAll(),
      collections: collections,
      filters: filters,
      albums: LibraryAlbums(store: store, apiOfSource: (_) => null),
    );
    settings = ShellSettings(
      read: (key) => saved[key],
      write: (key, value) => saved[key] = value,
    );
  });
  tearDown(() => store.close());

  Future<void> pumpStats(
    WidgetTester tester, {
    Size size = const Size(1800, 900),
  }) async {
    playback = PlaybackController(
      player: PlayerService(muted: true, dataDir: '.'),
      plays: collections,
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CoverScope(
        store: _SilentCovers(),
        child: MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: LibraryScreen(
            library: library,
            playback: playback,
            collections: collections,
            settings: settings,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-stats')));
    await tester.pump();
    await tester.pump();
  }

  String textIn(Finder parent) =>
      [for (final widget in textsUnder(parent)) widget].join(' | ');

  Finder row(int n) => find.byKey(ValueKey('stats-row-$n'));

  testWidgets('tiles add up the period and compare it with the same days '
      'before', (tester) async {
    await pumpStats(tester);
    expect(find.text('Stats'), findsWidgets);
    expect(find.textContaining('Planned after the MVP'), findsNothing);
    expect(find.text('November 2026'), findsOneWidget);
    expect(
      textIn(find.byKey(const ValueKey('stats-tile-listened'))),
      contains('19 min'),
    );
    expect(
      textIn(find.byKey(const ValueKey('stats-tile-plays'))),
      contains('6'),
    );
    expect(
      textIn(find.byKey(const ValueKey('stats-tile-songs'))),
      contains('3'),
    );
    expect(
      textIn(find.byKey(const ValueKey('stats-tile-artists'))),
      contains('2'),
    );
    // 1 - 7 October 2026 had no plays.
    expect(find.text('Nothing in 1 - 7 Oct 2026'), findsNWidgets(4));

    // Back to 2025: Кукушка's six plays; 2024 is before the first play.
    filters.setPeriod(const PlayPeriod.year(offset: -1));
    await tester.pump();
    expect(
      textIn(find.byKey(const ValueKey('stats-tile-plays'))),
      contains('6'),
    );
    expect(find.text('Counting since 1 Oct 2025'), findsNWidgets(4));
    expect(textIn(row(0)), contains('Кукушка'));
    expect(row(1), findsNothing);

    filters.setPeriod(const PlayPeriod.month(offset: -2));
    await tester.pump();
    expect(find.text('Nothing played in September 2026.'), findsOneWidget);
  });

  testWidgets('top songs play from the clicked one; artists and albums '
      'open their songs', (tester) async {
    await pumpStats(tester);
    expect(textIn(row(0)), contains('Выхода нет'));
    expect(textIn(row(0)), contains('Сплин'));
    expect(textIn(row(1)), contains('Группа крови'));
    expect(textIn(row(2)), contains('Кукушка'));
    expect(row(3), findsNothing);

    await tester.tap(find.byKey(const ValueKey('stats-tab-artists')));
    await tester.pump();
    // Кино 3 plays, 700 s; Сплин 3 plays, 450 s.
    expect(textIn(row(0)), contains('Кино'));
    expect(textIn(row(0)), contains('2 songs played'));
    expect(textIn(row(1)), contains('Сплин'));
    await tester.tap(row(0));
    await tester.pump();
    expect(library.view, LibraryView.songs);
    expect(filters.filter.ruleFor(FilterField.artist)?.values, {'Кино'});
    expect(filters.sort, SongSort.plays);
    expect(
      [for (final t in library.visible) t.title],
      ['Группа крови', 'Кукушка'],
    );

    await tester.tap(find.byKey(const ValueKey('nav-stats')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('stats-tab-albums')));
    await tester.pump();
    expect(textIn(row(0)), contains('Чёрный альбом'));
    expect(row(1), findsNothing);
    await tester.tap(row(0));
    await tester.pump();
    expect(library.view.kind, ViewKind.album);
    expect(library.view.album?.title, 'Чёрный альбом');
  });

  testWidgets('a top song plays the top songs from that one', (tester) async {
    final calls = <(List<int>, int)>[];
    filters.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatsPage(
            filters: filters,
            songs: library.all,
            onPlay: (list, index) =>
                calls.add(([for (final t in list) t.id], index)),
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(row(1));
    expect(calls, hasLength(1));
    expect(calls.single.$1, [ids[1], ids[3], ids[0]]);
    expect(calls.single.$2, 1);
  });

  testWidgets('a narrow window keeps every tile and the rows', (tester) async {
    await pumpStats(tester, size: const Size(760, 800));
    for (final tile in ['listened', 'plays', 'songs', 'artists']) {
      expect(find.byKey(ValueKey('stats-tile-$tile')), findsOneWidget);
    }
    expect(textIn(row(0)), contains('Выхода нет'));
    expect(tester.takeException(), isNull);
  });
}

/// The texts under [parent], in order.
Iterable<String> textsUnder(Finder parent) => find
    .descendant(of: parent, matching: find.byType(Text))
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '');
