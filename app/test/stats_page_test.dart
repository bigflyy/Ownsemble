import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  group('Calendar tab', () {
    String tip(WidgetTester tester, String key) =>
        tester.widget<Tooltip>(find.byKey(ValueKey(key))).message!;
    Finder panel() => find.byKey(const ValueKey('cal-panel'));

    Future<void> openCalendar(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('stats-tab-calendar')));
      await tester.pump();
    }

    testWidgets('shows the period year with each day heard, and the latest '
        'day played', (tester) async {
      await pumpStats(tester);
      await openCalendar(tester);
      for (var m = 1; m <= 12; m++) {
        expect(find.byKey(ValueKey('cal-month-$m')), findsOneWidget);
      }
      // November 2026: 300 + 450 + 400 s.
      expect(
        textIn(find.byKey(const ValueKey('cal-month-11'))),
        contains('19 min'),
      );
      expect(tip(tester, 'cal-day-2026-11-06'), 'Fri 6 Nov 2026: 7 min');
      expect(
        tip(tester, 'cal-day-2026-11-01'),
        'Sun 1 Nov 2026: nothing played',
      );
      expect(tip(tester, 'cal-day-2026-11-08'), 'Sun 8 Nov 2026');
      // The latest day with plays in the period is chosen at first.
      final shown = textIn(panel());
      expect(shown, contains('Fri 6 Nov 2026'));
      expect(shown, contains('7 min, 2 plays, 2 counted'));
      expect(shown, contains('09:00'));
      expect(shown, contains('10:00'));
      expect(shown, contains('Группа крови'));
      expect(shown, isNot(contains('Выхода нет')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a click picks a day, Shift+click a range', (tester) async {
      await pumpStats(tester);
      await openCalendar(tester);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-03')));
      await tester.pump();
      expect(textIn(panel()), contains('Tue 3 Nov 2026'));
      expect(textIn(panel()), contains('Выхода нет'));
      expect(textIn(panel()), isNot(contains('Группа крови')));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-06')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final shown = textIn(panel());
      expect(shown, contains('3 - 6 Nov 2026'));
      expect(shown, contains('4 days'));
      // 3 x 150 s + 2 x 200 s.
      expect(shown, contains('14 min, 5 plays, 5 counted'));
      // A range names each day above its plays.
      expect(shown, contains('Wed 4 Nov'));
      expect(shown, contains('Fri 6 Nov'));

      // Shift+click before the first end turns the range around.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-02')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(textIn(panel()), contains('2 - 3 Nov 2026'));

      // A future day cannot be picked.
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-20')));
      await tester.pump();
      expect(textIn(panel()), contains('2 - 3 Nov 2026'));
    });

    testWidgets('days before the first play are marked, and a year with no '
        'plays says so', (tester) async {
      await pumpStats(tester);
      filters.setPeriod(const PlayPeriod.year(offset: -1));
      await tester.pump();
      await openCalendar(tester);
      expect(
        tip(tester, 'cal-day-2025-09-30'),
        'Tue 30 Sep 2025: before the app recorded plays',
      );
      expect(tip(tester, 'cal-day-2025-10-06'), 'Mon 6 Oct 2025: 5 min');
      expect(textIn(panel()), contains('Mon 6 Oct 2025'));

      filters.setPeriod(const PlayPeriod.year(offset: -3));
      await tester.pump();
      expect(textIn(panel()), contains('Nothing played in 2023'));
    });

    testWidgets('Play these songs plays the days songs in time order, once '
        'each', (tester) async {
      final calls = <(List<int>, int)>[];
      filters.load();
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.light),
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
      await openCalendar(tester);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-02')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-11-06')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-play-all')));
      expect(calls, hasLength(1));
      expect(calls.single.$1, [ids[0], ids[1], ids[3]]);
      expect(calls.single.$2, 0);
      // A play row plays the same songs from its own.
      final row = find.byKey(const ValueKey('cal-play-3'), skipOffstage: false);
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      expect(calls.last.$1, [ids[0], ids[1], ids[3]]);
      expect(calls.last.$2, 1);
    });

    testWidgets('When you listen adds up the period by weekday and hour', (
      tester,
    ) async {
      await pumpStats(tester);
      await openCalendar(tester);
      expect(
        textIn(find.byKey(const ValueKey('cal-hours'))),
        contains('Time listened in November 2026 by weekday and hour'),
      );
      // Mon 2 Nov 9:00 300 s; Fri 6 Nov 9:00 and 10:00 200 s each.
      expect(tip(tester, 'cal-hour-1-9'), 'Mon 9:00: 5 min');
      expect(tip(tester, 'cal-hour-5-10'), 'Fri 10:00: 3 min');
      expect(tip(tester, 'cal-hour-7-20'), 'Sun 20:00: nothing');
    });

    testWidgets('a narrow window puts the days below the months', (
      tester,
    ) async {
      await pumpStats(tester, size: const Size(760, 900));
      await openCalendar(tester);
      final months = tester.getRect(find.byKey(const ValueKey('cal-month-1')));
      expect(tester.getRect(panel()).top, greaterThan(months.bottom));
      expect(tester.takeException(), isNull);
      await pumpStats(tester, size: const Size(1800, 900));
      await openCalendar(tester);
      expect(
        tester.getRect(panel()).left,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('cal-month-1'))).right,
        ),
      );
    });

    testWidgets('the panel keeps a readable width in a very wide window', (
      tester,
    ) async {
      // Beside the months (user, 2026-11-08: the heard time stood far from
      // the song).
      await pumpStats(tester, size: const Size(2560, 1400));
      await openCalendar(tester);
      final months = tester.getRect(find.byKey(const ValueKey('cal-month-1')));
      expect(tester.getRect(panel()).left, greaterThan(months.right));
      expect(tester.getSize(panel()).width, lessThanOrEqualTo(600));
      // Below the months, in a main area about 700 wide.
      settings.dockTo(PlayerDock.bottom);
      await pumpStats(tester, size: const Size(1000, 900));
      await openCalendar(tester);
      final below = tester.getRect(find.byKey(const ValueKey('cal-month-1')));
      expect(tester.getRect(panel()).top, greaterThan(below.bottom));
      expect(tester.getSize(panel()).width, 600);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the tabs scroll sideways when the page is very narrow', (
      tester,
    ) async {
      // The side player leaves about 300 for the page.
      await pumpStats(tester, size: const Size(1120, 900));
      await openCalendar(tester);
      expect(tester.takeException(), isNull);
      final tabs = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('stats-tabs')),
      );
      expect(tabs.scrollDirection, Axis.horizontal);
    });
  });

  group('Year report', () {
    Finder key(String k) => find.byKey(ValueKey(k));

    testWidgets('the banner names the year and opens its report; Back '
        'returns to Stats', (tester) async {
      await pumpStats(tester);
      final banner = textIn(key('stats-year-banner'));
      expect(banner, contains('Your 2026 so far'));
      // 300 + 450 + 400 s; Выхода нет has 3 plays.
      expect(
        banner,
        contains('19 min listened, song of the year: Выхода нет (Сплин)'),
      );

      await tester.tap(key('stats-open-year'));
      await tester.pump();
      expect(library.view, const LibraryView(ViewKind.yearReport, year: 2026));
      expect(find.text('Your 2026'), findsOneWidget);
      expect(textIn(key('year-tile-plays')), contains('6'));
      // 2025 had 6 plays by 7 Nov.
      expect(textIn(key('year-tile-plays')), contains('Same as'));
      expect(textIn(key('year-song')), contains('Выхода нет'));
      expect(key('year-note'), findsNothing);
      expect(
        tester.widget<IconButton>(key('year-later')).onPressed,
        isNull,
        reason: 'no later year than this one',
      );

      // The year before: Кукушка, and the note on when counting began.
      await tester.tap(key('year-earlier'));
      await tester.pump();
      expect(find.text('Your 2025'), findsOneWidget);
      expect(textIn(key('year-song')), contains('Кукушка'));
      expect(textIn(key('year-note')), contains('Counting since 1 Oct 2025'));
      expect(textIn(key('year-tile-run')), contains('6 days'));
      expect(
        tester.widget<IconButton>(key('year-earlier')).onPressed,
        isNull,
        reason: 'nothing was recorded before 2025',
      );

      // A month's own facts.
      await tester.ensureVisible(key('year-month-10'));
      await tester.pump();
      await tester.tap(key('year-month-10'));
      await tester.pump();
      final factsBox = find.byKey(
        const ValueKey('year-month-facts'),
        skipOffstage: false,
      );
      await tester.ensureVisible(factsBox);
      await tester.pump();
      final facts = textIn(factsBox);
      expect(facts, contains('October'));
      expect(facts, contains('Кукушка'));
      expect(facts, contains('6 counted plays'));

      await tester.tap(key('album-back'));
      await tester.pump();
      expect(library.view, const LibraryView(ViewKind.stats));
      expect(tester.takeException(), isNull);
    });

    testWidgets('songs new to you and a narrow window', (tester) async {
      await pumpStats(tester, size: const Size(760, 900));
      library.openYearReport(2026);
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Every 2026 song but Кукушка is new; Выхода нет has most plays.
      final fresh = find.byKey(
        const ValueKey('year-new-0'),
        skipOffstage: false,
      );
      await tester.ensureVisible(fresh);
      await tester.pump();
      expect(textIn(fresh), contains('Выхода нет'));
      expect(textIn(fresh), contains('first on 3 Nov'));
      expect(
        textIn(find.byKey(const ValueKey('year-new-1'), skipOffstage: false)),
        contains('Группа крови'),
      );
      expect(
        find.byKey(const ValueKey('year-new-2'), skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
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
