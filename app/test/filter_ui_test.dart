import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/cover_store.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/cover_tile.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/period_picker.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/song_filters.dart';
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
        addedAt: DateTime(2020).millisecondsSinceEpoch ~/ 1000,
      ),
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 232,
        addedAt: DateTime(2026, 11, 3).millisecondsSinceEpoch ~/ 1000,
      ),
      NewTrack(
        sourceKey: '1_3',
        artist: 'Земфира',
        title: 'Хочешь?',
        durationSec: 226,
        addedAt: DateTime(2026, 2, 1).millisecondsSinceEpoch ~/ 1000,
      ),
      NewTrack(
        sourceKey: '1_4',
        artist: 'Кино',
        title: 'Группа крови',
        durationSec: 286,
        addedAt: DateTime(2019).millisecondsSinceEpoch ~/ 1000,
      ),
    ]);
    for (var d = 1; d <= 6; d++) {
      play(ids[0], DateTime(2025, 10, d, 20), heardSec: 300);
    }
    play(ids[0], DateTime(2026, 11, 2, 9), heardSec: 300);
    for (var d = 3; d <= 5; d++) {
      play(ids[1], DateTime(2026, 11, d, 9));
    }
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
    );
    settings = ShellSettings(
      read: (key) => saved[key],
      write: (key, value) => saved[key] = value,
    );
  });
  tearDown(() => store.close());

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1800, 900),
  }) async {
    final playback = PlaybackController(
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
    // The play numbers are read just after the first frame.
    await tester.pump();
    await tester.pump();
  }

  List<String> titles() => [for (final t in library.visible) t.title];

  Finder chip(FilterField field) => find.byKey(ValueKey('chip-${field.name}'));

  testWidgets('the chip row, the period and the play columns', (tester) async {
    await pumpShell(tester);
    expect(filters.loaded, isTrue);
    for (final field in [
      FilterField.artist,
      FilterField.added,
      FilterField.plays,
      FilterField.lastPlayed,
    ]) {
      expect(chip(field), findsOneWidget);
    }
    expect(chip(FilterField.offline), findsNothing);
    expect(find.byKey(const ValueKey('add-filter')), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    final header = find.byKey(const ValueKey('list-header'));
    for (final title in ['Plays', 'Listened', 'Last played', 'Added']) {
      expect(
        find.descendant(of: header, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
    }
    // Выхода нет: 3 plays this month; Кукушка 1.
    expect(find.text('3'), findsOneWidget);
    // Выхода нет was last played on the 5th.
    expect(find.text('2 days ago'), findsOneWidget);
    expect(find.text('3 Nov 2026'), findsOneWidget);
  });

  testWidgets('Artist: two artists mean either; is not turns it round', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(chip(FilterField.artist));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-Кино')));
    await tester.pumpAndSettle();
    expect(titles(), unorderedEquals(['Кукушка', 'Группа крови']));
    await tester.tap(find.byKey(const ValueKey('option-Сплин')));
    await tester.pumpAndSettle();
    expect(titles(), hasLength(3));
    await tester.tap(find.text('is not'));
    await tester.pumpAndSettle();
    expect(titles(), ['Хочешь?']);
    // The menu closes with Escape; the chip says what it does.
    await tester.tapAt(const Offset(5, 890));
    await tester.pumpAndSettle();
    expect(find.text('Artist is not: Кино, Сплин'), findsOneWidget);
  });

  testWidgets('chips combine with each other and with the search', (
    tester,
  ) async {
    await pumpShell(tester);
    filters.setRule(
      const FilterRule(FilterField.artist, values: {'Кино', 'Сплин'}),
    );
    filters.setRule(const FilterRule(FilterField.plays, values: {'1'}));
    await tester.pump();
    expect(titles(), unorderedEquals(['Кукушка', 'Выхода нет']));
    await tester.enterText(find.byType(TextField).first, 'кук');
    await tester.pump();
    expect(titles(), ['Кукушка']);
  });

  testWidgets('+ Filter adds a chip and opens it; a toggle is on at once', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('add-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('more-length')));
    await tester.pumpAndSettle();
    expect(chip(FilterField.length), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('option-long')));
    await tester.pumpAndSettle();
    expect(titles(), unorderedEquals(['Кукушка', 'Группа крови']));
    await tester.tapAt(const Offset(5, 890));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('more-never')));
    await tester.pumpAndSettle();
    expect(titles(), ['Группа крови']);
    expect(find.text('Never played'), findsWidgets);
  });

  testWidgets('a column title sorts, twice turns the order round', (
    tester,
  ) async {
    await pumpShell(tester);
    filters.setPeriod(const PlayPeriod.all());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sort-plays')));
    await tester.pump();
    expect(titles().first, 'Кукушка');
    await tester.tap(find.byKey(const ValueKey('sort-plays')));
    await tester.pump();
    expect(titles().last, 'Кукушка');
  });

  testWidgets('the period buttons and arrows', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('period-year')));
    await tester.pump();
    expect(find.text('2026'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('period-back')));
    await tester.pump();
    expect(filters.period, const PlayPeriod.year(offset: -1));
    expect(find.byKey(const ValueKey('period-label')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('period-label'))).data,
      '2025',
    );
    // Кукушка: 6 plays in 2025.
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('Custom: click the first month, then the last, Apply', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('period-custom')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('picker-title'))).data,
      '2026',
    );
    await tester.tap(find.byKey(const ValueKey('picker-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('month-2025-10')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('month-2025-12')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('picker-range'))).data,
      '1 Oct - 31 Dec 2025',
    );
    // October 2025 shows its 30 minutes of listening.
    expect(find.text('30 min'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-apply')));
    await tester.pumpAndSettle();
    expect(
      filters.period,
      PlayPeriod.custom(
        DayRange(DateTime(2025, 10, 1), DateTime(2025, 12, 31)),
      ),
    );
    // The arrows step by three months.
    await tester.tap(find.byKey(const ValueKey('period-next')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('period-label'))).data,
      '1 Jan - 31 Mar 2026',
    );
  });

  testWidgets('Custom exact days, and the listening setting', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('period-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-exact')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('picker-title'))).data,
      'November 2026',
    );
    await tester.tap(find.byKey(const ValueKey('day-2026-11-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('day-2026-11-5')));
    await tester.pump();
    await tester.tap(find.text('Color'));
    await tester.pump();
    expect(settings.calendarListening, CalendarListening.color);
    expect(saved['ui.calendar_listening'], 'color');
    // Color mode: the ends keep their listening tint and get a violet ring,
    // and one outline goes around the chosen days (3 to 5 November share a
    // week row, so it is one box).
    final accent = OwnColors.of(
      tester.element(find.byKey(const ValueKey('day-2026-11-3'))),
    ).accent;
    Material cellMaterial(String key) => tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Material),
          )
          .first,
    );
    RangeOutline? outline(String key) {
      for (final paint in tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(CustomPaint),
        ),
      )) {
        final painter = paint.foregroundPainter;
        if (painter is RangeOutline) return painter;
      }
      return null;
    }

    final end = cellMaterial('day-2026-11-3');
    expect(end.color, isNot(accent), reason: 'an end is not filled');
    expect((end.shape! as RoundedRectangleBorder).side.color, accent);
    expect(outline('day-2026-11-2'), isNull);
    expect(
      [
        for (final day in [3, 4, 5])
          (
            outline('day-2026-11-$day')!.opensLeft,
            outline('day-2026-11-$day')!.opensRight,
          ),
      ],
      [(false, true), (true, true), (true, false)],
    );
    // A range that goes on into the next month closes its box at the
    // month's last day.
    await tester.tap(find.byKey(const ValueKey('picker-back')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('day-2026-10-29')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('picker-next')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('day-2026-11-5')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('picker-back')));
    await tester.pump();
    expect(outline('day-2026-10-31')!.opensRight, isFalse);
    expect(outline('day-2026-10-30')!.opensRight, isTrue);
    await tester.tap(find.byKey(const ValueKey('picker-next')));
    await tester.pump();
    expect(outline('day-2026-11-1')!.opensLeft, isFalse);
    await tester.tap(find.byKey(const ValueKey('day-2026-11-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('day-2026-11-5')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('picker-apply')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('period-label'))).data,
      '3 - 5 Nov 2026',
    );
    expect(titles().where((t) => t == 'Выхода нет'), hasLength(1));
  });

  testWidgets('a Plays chip with its own dates is dashed and names them', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(chip(FilterField.plays));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-5')));
    await tester.pumpAndSettle();
    expect(titles(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('plays-own-period')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('month-2025-10')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('picker-apply')));
    await tester.pumpAndSettle();
    expect(titles(), ['Кукушка']);
    await tester.tapAt(const Offset(5, 890));
    await tester.pumpAndSettle();
    expect(find.text('Plays in October 2025: 5 or more'), findsOneWidget);
    // The page's period still drives the Plays column.
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('period-label'))).data,
      'November 2026',
    );
  });

  testWidgets('Save as view: automatic name, sidebar, rename, back to Songs', (
    tester,
  ) async {
    await pumpShell(tester);
    filters.setRule(const FilterRule(FilterField.artist, values: {'Кино'}));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-view')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('view-name')),
    );
    expect(field.controller!.text, 'This month - Кино');
    await tester.tap(find.byKey(const ValueKey('view-name-ok')));
    await tester.pumpAndSettle();
    final id = filters.views.single.id;
    expect(find.byKey(ValueKey('nav-view-$id')), findsOneWidget);
    expect(find.text('This month - Кино'), findsWidgets);
    expect(find.byKey(const ValueKey('save-view')), findsNothing);

    // Rename from the sidebar's right-click menu.
    await tester.tap(
      find.byKey(ValueKey('nav-view-$id')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('view-name')), 'Кино');
    await tester.tap(find.byKey(const ValueKey('view-name-ok')));
    await tester.pumpAndSettle();
    expect(filters.views.single.name, 'Кино');

    // Songs shows every song again; the view brings its chips back.
    await tester.tap(find.byKey(const ValueKey('nav-songs')));
    await tester.pump();
    expect(titles(), hasLength(4));
    await tester.tap(find.byKey(ValueKey('nav-view-$id')));
    await tester.pump();
    expect(titles(), hasLength(2));
  });

  testWidgets('a narrow window folds the chips into Filters', (tester) async {
    await pumpShell(tester, size: const Size(860, 700));
    expect(chip(FilterField.artist), findsNothing);
    expect(find.byKey(const ValueKey('filters-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('period-menu')), findsOneWidget);
    final header = find.byKey(const ValueKey('list-header'));
    expect(
      find.descendant(of: header, matching: find.text('Listened')),
      findsNothing,
    );
    expect(
      find.descendant(of: header, matching: find.text('Plays')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('filters-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-length')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-mid')));
    await tester.pumpAndSettle();
    expect(titles(), hasLength(2));
    expect(filters.filter.ruleFor(FilterField.length)?.values, {'mid'});
  });

  testWidgets('the smallest window keeps three song rows, chips or not', (
    tester,
  ) async {
    filters.setRule(const FilterRule(FilterField.plays, values: {'1'}));
    filters.setRule(const FilterRule(FilterField.artist, values: {'Кино'}));
    await pumpShell(tester, size: const Size(480, 440));
    expect(find.byKey(const ValueKey('period-compact')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-view')), findsNothing);
    expect(
      library.scroll.position.viewportDimension,
      greaterThanOrEqualTo(3 * rowHeight),
    );
    // The compact period menu steps back and forth.
    await tester.tap(find.byKey(const ValueKey('period-compact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('period-back')));
    await tester.pumpAndSettle();
    expect(filters.period, const PlayPeriod.month(offset: -1));
  });

  testWidgets('a new play updates the Plays column', (tester) async {
    await pumpShell(tester);
    final play = collections.beginPlay(
      ids[2],
      start: PlayStart.chosen,
      shuffle: false,
    );
    collections.updatePlay(play, listenedMs: 200000, ended: PlayEnd.finished);
    await tester.pump();
    // Played at the real time, so all time is the number to look at.
    expect(filters.allTimePlays(ids[2])?.plays, 1);
  });
}
