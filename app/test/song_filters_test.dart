import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/song_filters.dart';

/// Saturday 7 November 2026.
final now = DateTime(2026, 11, 7, 14);

void main() {
  late LibraryStore store;
  late List<int> ids;
  late List<Track> songs;
  late Map<String, String> settings;

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

  SongFilters filters() => SongFilters(
    store,
    readSetting: (key) => settings[key],
    writeSetting: (key, value) =>
        value == null ? settings.remove(key) : settings[key] = value,
    clock: () => now,
  )..load();

  List<String> titles(SongFilters f) => [
    for (final track in f.apply(songs)) track.title,
  ];

  setUp(() {
    settings = {};
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    ids = store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Кино',
        title: 'Кукушка',
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
    ]);
    // Кукушка: loved in 2025, once this month. Выхода нет: 3 times this
    // month. Хочешь?: never.
    for (var d = 1; d <= 6; d++) {
      play(ids[0], DateTime(2025, 3, d, 20), heardSec: 300);
    }
    play(ids[0], DateTime(2026, 11, 2, 9), heardSec: 300);
    for (var d = 3; d <= 5; d++) {
      play(ids[1], DateTime(2026, 11, d, 9));
    }
    songs = store.loadAll();
  });
  tearDown(() => store.close());

  test('the period drives the plays numbers and the Plays chip', () {
    final f = filters();
    expect(f.period, const PlayPeriod.month());
    expect(f.periodPlays(ids[0])?.plays, 1);
    expect(f.periodPlays(ids[1])?.plays, 3);
    f.setRule(const FilterRule(FilterField.plays, values: {'2'}));
    expect(titles(f), ['Выхода нет']);
    f.setPeriod(const PlayPeriod.all());
    expect(titles(f), ['Выхода нет', 'Кукушка']);
    expect(f.periodPlays(ids[0])?.plays, 7);
    f.setPeriod(const PlayPeriod.month(offset: -1));
    expect(titles(f), isEmpty);
  });

  test('a Plays chip with its own dates, beside the page period', () {
    final f = filters();
    f
      ..setRule(const FilterRule(FilterField.plays, values: {'0'}))
      ..setRule(
        FilterRule(
          FilterField.plays,
          values: const {'5'},
          period: PlayPeriod.custom(DayRange.year(2025)),
        ),
      );
    // One chip per field: the second replaced the first.
    expect(titles(f), ['Кукушка']);
  });

  test('sorting by plays, by title, and back to the library order', () {
    final f = filters()..setPeriod(const PlayPeriod.all());
    f.sortBy(SongSort.plays);
    expect(f.descending, isTrue);
    expect(titles(f), ['Кукушка', 'Выхода нет', 'Хочешь?']);
    f.sortBy(SongSort.plays);
    expect(titles(f), ['Хочешь?', 'Выхода нет', 'Кукушка']);
    f.sortBy(SongSort.title);
    expect(f.descending, isFalse);
    expect(titles(f), ['Выхода нет', 'Кукушка', 'Хочешь?']);
    f.resetSort();
    expect(f.active, isFalse);
    expect(titles(f), [for (final t in songs) t.title]);
  });

  test('a new play updates the numbers of that song', () {
    final f = filters();
    expect(f.periodPlays(ids[2]), isNull);
    play(ids[2], DateTime(2026, 11, 7, 10));
    f.playsChanged(ids[2]);
    expect(f.periodPlays(ids[2])?.plays, 1);
    expect(f.allTimePlays(ids[2])?.plays, 1);
  });

  test("Stats: the period's plays, the days compared, the first play", () {
    final f = filters();
    expect(f.inPeriod.keys, unorderedEquals([ids[0], ids[1]]));
    final october = f.compared()!;
    expect(
      october.range,
      DayRange(DateTime(2026, 10, 1), DateTime(2026, 10, 7)),
    );
    expect(october.plays, isEmpty);
    f.setPeriod(
      PlayPeriod.custom(DayRange(DateTime(2025, 3, 7), DateTime(2025, 3, 12))),
    );
    final before = f.compared()!;
    expect(before.range, DayRange(DateTime(2025, 3, 1), DateTime(2025, 3, 6)));
    expect(before.plays[ids[0]]!.plays, 6);
    f.setPeriod(const PlayPeriod.all());
    expect(f.compared(), isNull);
    expect(f.firstPlayMs, DateTime(2025, 3, 1, 20).millisecondsSinceEpoch);
  });

  test('saved views: automatic name, rename, delete, kept in settings', () {
    final f = filters()
      ..setRule(const FilterRule(FilterField.artist, values: {'Сплин'}))
      ..setRule(const FilterRule(FilterField.plays, values: {'1'}));
    expect(f.suggestedName(), 'This month - Сплин, played');
    final id = f.saveView(f.suggestedName());
    expect(f.view?.name, 'This month - Сплин, played');
    // The current month stays relative.
    expect(f.view?.period, const PlayPeriod.month());
    f.renameView(id, 'Ноябрь');
    expect(f.views.single.name, 'Ноябрь');

    // Another run reads the views and what was shown.
    final again = filters();
    expect(again.views.single.name, 'Ноябрь');
    expect(again.view?.id, id);
    expect(titles(again), ['Выхода нет']);

    // Changing a chip leaves the view; opening it brings its chips back.
    again.clear();
    expect(again.view, isNull);
    expect(titles(again), hasLength(3));
    again.openView(id);
    expect(titles(again), ['Выхода нет']);
    again.deleteView(id);
    expect(again.views, isEmpty);
    expect(jsonDecode(settings[SongFilters.viewsSetting]!), isEmpty);
  });

  test('a period stepped back is saved as fixed dates', () {
    final f = filters()
      ..setPeriod(const PlayPeriod.month(offset: -1))
      ..setRule(const FilterRule(FilterField.never, values: {'yes'}));
    expect(f.suggestedName(), 'October 2026 - never played');
    f.saveView('Октябрь');
    expect(f.view?.period, PlayPeriod.custom(DayRange.month(2026, 10)));
    expect(f.period, PlayPeriod.custom(DayRange.month(2026, 10)));
  });

  test('no step past today', () {
    final f = filters();
    f.stepPeriod(1);
    expect(f.period, const PlayPeriod.month());
    f.stepPeriod(-1);
    expect(f.period, const PlayPeriod.month(offset: -1));
  });

  test('unreadable settings start empty', () {
    settings[SongFilters.stateSetting] = '{not json';
    settings[SongFilters.viewsSetting] = '[{"id": "x"}]';
    final f = filters();
    expect(f.filter.isEmpty, isTrue);
    expect(f.views, isEmpty);
  });
}
