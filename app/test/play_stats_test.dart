import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_stats.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/library/year_report.dart';

NewTrack song(String key, {int seconds = 200}) => NewTrack(
  sourceKey: key,
  artist: 'Кино',
  title: 'Песня $key',
  durationSec: seconds,
  addedAt: 0,
);

/// Unix milliseconds of a local time.
int at(int year, int month, int day, [int hour = 12, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

void main() {
  late LibraryStore store;
  late int vk;
  setUp(() {
    store = LibraryStore.open(':memory:');
    vk = store.ensureSource(TrackSource.vk, account: '42', name: 'VK');
  });
  tearDown(() => store.close());

  /// Records a finished-or-not play of [trackId] heard for [heardSec].
  void play(
    int trackId,
    int atMs, {
    required double heardSec,
    PlayEnd? ended = PlayEnd.skipped,
  }) {
    final id = store.beginPlay(
      trackId,
      start: PlayStart.chosen,
      shuffle: false,
      atMs: atMs,
    );
    store.updatePlay(id, listenedMs: (heardSec * 1000).round(), ended: ended);
  }

  group('DayRange', () {
    test('holds whole local days, both ends included', () {
      final range = DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30));
      expect(range.startMs, DateTime(2025, 10, 1).millisecondsSinceEpoch);
      expect(range.endMs, DateTime(2025, 12, 1).millisecondsSinceEpoch);
      expect(range.dayCount, 61);
      expect(range.contains(at(2025, 10, 1, 0)), isTrue);
      expect(range.contains(at(2025, 11, 30, 23, 59)), isTrue);
      expect(range.contains(at(2025, 12, 1, 0)), isFalse);
      expect(range.contains(at(2025, 9, 30, 23, 59)), isFalse);
    });

    test('drops the time of day and puts the ends in order', () {
      final range = DayRange(
        DateTime(2025, 11, 30, 18, 5),
        DateTime(2025, 10, 1, 7),
      );
      expect(range.first, DateTime(2025, 10, 1));
      expect(range.last, DateTime(2025, 11, 30));
      expect(range, DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30)));
    });

    test('one day and a whole month', () {
      expect(DayRange.day(DateTime(2026, 2, 3, 15)).dayCount, 1);
      final feb = DayRange.month(2024, 2);
      expect(feb.first, DateTime(2024, 2, 1));
      expect(feb.last, DateTime(2024, 2, 29));
    });
  });

  group('counted plays', () {
    test('half the song or 4 minutes counts; less does not', () {
      // Old plays (before heard time was recorded) count, as History
      // showed them.
      expect(
        isCountedPlay(listenedMs: null, ended: null, durationSec: 200),
        isTrue,
      );
      expect(
        isCountedPlay(listenedMs: 100000, ended: null, durationSec: 200),
        isTrue,
      );
      expect(
        isCountedPlay(
          listenedMs: 99999,
          ended: PlayEnd.finished,
          durationSec: 200,
        ),
        isFalse,
      );
      expect(
        isCountedPlay(
          listenedMs: 240000,
          ended: PlayEnd.skipped,
          durationSec: 900,
        ),
        isTrue,
      );
      expect(
        isCountedPlay(
          listenedMs: 239999,
          ended: PlayEnd.closed,
          durationSec: 900,
        ),
        isFalse,
      );
      // A song of 30 s or less must play to its end.
      expect(
        isCountedPlay(
          listenedMs: 30000,
          ended: PlayEnd.skipped,
          durationSec: 30,
        ),
        isFalse,
      );
      expect(
        isCountedPlay(
          listenedMs: 2000,
          ended: PlayEnd.finished,
          durationSec: 30,
        ),
        isTrue,
      );
    });

    test('the store counts with the same rule', () {
      final ids = store.upsertAll(vk, [
        song('1_1', seconds: 200),
        song('1_2', seconds: 900),
        song('1_3', seconds: 25),
      ]);
      final t = at(2026, 11, 1);
      play(ids[0], t, heardSec: 100); // counted
      play(ids[0], t + 1, heardSec: 99.9); // not
      store.addPlay(ids[0], atMs: t + 2); // before schema 9: counted
      play(ids[1], t + 3, heardSec: 240); // counted (4 min)
      play(ids[1], t + 4, heardSec: 230, ended: PlayEnd.finished); // not
      play(ids[2], t + 5, heardSec: 25, ended: PlayEnd.skipped); // not
      play(ids[2], t + 6, heardSec: 3, ended: PlayEnd.finished); // counted
      final stats = store.songPlays();
      expect(stats[ids[0]]!.plays, 2);
      expect(stats[ids[1]]!.plays, 1);
      expect(stats[ids[2]]!.plays, 1);
    });
  });

  group('songPlays', () {
    test('counts plays, heard time and first and last play in a day range', () {
      final ids = store.upsertAll(vk, [song('1_1'), song('1_2'), song('1_3')]);
      play(ids[0], at(2025, 9, 30, 23, 59), heardSec: 200); // day before
      play(ids[0], at(2025, 10, 1, 0, 0), heardSec: 150); // first day
      play(ids[0], at(2025, 10, 15), heardSec: 20); // heard, not counted
      play(ids[0], at(2025, 11, 30, 23, 59), heardSec: 120); // last day
      play(ids[0], at(2025, 12, 1, 0, 0), heardSec: 200); // day after
      play(ids[1], at(2025, 10, 20), heardSec: 5); // only skipped
      play(ids[2], at(2026, 1, 1), heardSec: 200); // outside

      final range = DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30));
      final stats = store.songPlays(range: range);
      expect(stats.keys, unorderedEquals([ids[0], ids[1]]));
      final first = stats[ids[0]]!;
      expect(first.plays, 2);
      expect(first.listenedMs, (150 + 20 + 120) * 1000);
      expect(first.firstMs, at(2025, 10, 1, 0, 0));
      expect(first.lastMs, at(2025, 11, 30, 23, 59));
      // Heard but never counted: listening time, no play, no dates.
      final skipped = stats[ids[1]]!;
      expect(skipped.plays, 0);
      expect(skipped.listenedMs, 5000);
      expect(skipped.firstMs, isNull);
      expect(skipped.lastMs, isNull);
    });

    test('all time covers every play, old ones without heard time too', () {
      final ids = store.upsertAll(vk, [song('1_1'), song('1_2')]);
      store.addPlay(ids[0], atMs: at(2024, 3, 1));
      play(ids[0], at(2026, 11, 7), heardSec: 180);
      final stats = store.songPlays();
      expect(stats.keys, [ids[0]]);
      expect(stats[ids[0]]!.plays, 2);
      expect(stats[ids[0]]!.listenedMs, 180000);
      expect(stats[ids[0]]!.firstMs, at(2024, 3, 1));
      expect(stats[ids[0]]!.lastMs, at(2026, 11, 7));
      // A song never played is not in the map.
      expect(stats[ids[1]], isNull);
    });

    test('starts and early skips: a song skipped early most times', () {
      final ids = store.upsertAll(vk, [song('1_1'), song('1_2')]);
      final t = at(2026, 11, 1);
      play(ids[0], t, heardSec: 5); // early skip
      play(ids[0], t + 1, heardSec: 19.9); // early skip
      play(ids[0], t + 2, heardSec: 150, ended: PlayEnd.finished);
      play(ids[1], t + 3, heardSec: 5); // early skip
      play(ids[1], t + 4, heardSec: 25); // skipped, not early
      play(ids[1], t + 5, heardSec: 3, ended: PlayEnd.closed); // not a skip
      final stats = store.songPlays();
      expect(stats[ids[0]]!.starts, 3);
      expect(stats[ids[0]]!.earlySkips, 2);
      expect(stats[ids[0]]!.oftenSkipped, isTrue);
      expect(stats[ids[1]]!.starts, 3);
      expect(stats[ids[1]]!.earlySkips, 1);
      expect(stats[ids[1]]!.oftenSkipped, isFalse);
    });

    test('one song alone, all time or in a range', () {
      final ids = store.upsertAll(vk, [song('1_1'), song('1_2')]);
      play(ids[0], at(2025, 5, 1), heardSec: 150);
      play(ids[0], at(2026, 5, 1), heardSec: 150);
      play(ids[1], at(2026, 5, 1), heardSec: 150);
      expect(store.songPlays(trackId: ids[0]).keys, [ids[0]]);
      expect(store.songPlays(trackId: ids[0])[ids[0]]!.plays, 2);
      final y2026 = store.songPlays(
        range: DayRange.year(2026),
        trackId: ids[0],
      );
      expect(y2026[ids[0]]!.plays, 1);
      expect(
        store.songPlays(range: DayRange.year(2024), trackId: ids[0]),
        isEmpty,
      );
    });

    test('a play still going on counts once it is over the line', () {
      final ids = store.upsertAll(vk, [song('1_1')]);
      final id = store.beginPlay(
        ids[0],
        start: PlayStart.auto,
        shuffle: true,
        atMs: at(2026, 11, 7),
      );
      expect(store.songPlays()[ids[0]]!.plays, 0);
      store.updatePlay(id, listenedMs: 101000);
      expect(store.songPlays()[ids[0]]!.plays, 1);
    });
  });

  group('firstPlayMs', () {
    test('is the start of the earliest play, counted or not', () {
      expect(store.firstPlayMs(), isNull);
      final ids = store.upsertAll(vk, [song('1_1')]);
      play(ids[0], at(2026, 11, 5), heardSec: 200);
      play(ids[0], at(2026, 11, 2, 9), heardSec: 1);
      expect(store.firstPlayMs(), at(2026, 11, 2, 9));
    });
  });

  group('listenedIn', () {
    test('sums heard time per range, each range on its own', () {
      final ids = store.upsertAll(vk, [song('1_1'), song('1_2')]);
      play(ids[0], at(2025, 1, 31, 23, 59), heardSec: 60);
      play(ids[1], at(2025, 2, 1, 0, 0), heardSec: 30);
      play(ids[1], at(2025, 2, 28), heardSec: 10);
      store.addPlay(ids[0], atMs: at(2025, 2, 10)); // no heard time
      final months = [
        DayRange.month(2025, 1),
        DayRange.month(2025, 2),
        DayRange.month(2025, 3),
      ];
      expect(store.listenedIn(months), [60000, 40000, 0]);
      expect(store.listenedIn(const []), isEmpty);
    });
  });

  group('speed', () {
    test('10,000 songs with three years of plays stay fast', () {
      final ids = store.upsertAll(vk, [
        for (var i = 0; i < 10000; i++) song('1_$i', seconds: 120 + i % 240),
      ]);
      fillHistory(store, ids, days: 3 * 365, playsPerDay: 100);
      final lastDay = DateTime.fromMillisecondsSinceEpoch(_historyEnd);
      final month = DayRange(
        lastDay.subtract(const Duration(days: 30)),
        lastDay,
      );
      // Warm up once, as the app does at start.
      store.songPlays();
      final all = _timeMs(() => store.songPlays());
      final inMonth = _timeMs(() => store.songPlays(range: month));
      final inYear = _timeMs(
        () => store.songPlays(
          range: DayRange(lastDay.subtract(const Duration(days: 364)), lastDay),
        ),
      );
      final year = DateTime.fromMillisecondsSinceEpoch(_historyEnd).year;
      final tiles = _timeMs(
        () => store.listenedIn([
          for (var m = 1; m <= 12; m++) DayRange.month(year, m),
        ]),
      );
      final days = _timeMs(
        () => store.listenedIn([
          for (var d = 0; d < 31; d++)
            DayRange.day(lastDay.subtract(Duration(days: d))),
        ]),
      );
      // ignore: avoid_print
      print(
        'songPlays all ${all.toStringAsFixed(1)} ms, month '
        '${inMonth.toStringAsFixed(1)} ms, year ${inYear.toStringAsFixed(1)} '
        'ms; listenedIn 12 months '
        '${tiles.toStringAsFixed(1)} ms, 31 days ${days.toStringAsFixed(1)} ms',
      );
      // The Calendar tab (plan 04, D2): a year of days, the weekday x hour
      // grid for a year and for all time, one day's and a year's plays.
      final calendarYear = DayRange.year(year);
      final yearDays = _timeMs(() => store.heardByDay(calendarYear));
      final gridYear = _timeMs(() => store.heardByWeekHour(calendarYear));
      final gridAll = _timeMs(() => store.heardByWeekHour(null));
      final oneDay = _timeMs(() => store.playsIn(DayRange.day(lastDay)));
      final yearPlays = _timeMs(() => store.playsIn(calendarYear));
      // ignore: avoid_print
      print(
        'heardByDay a year ${yearDays.toStringAsFixed(1)} ms; heardByWeekHour '
        'year ${gridYear.toStringAsFixed(1)} ms, all '
        '${gridAll.toStringAsFixed(1)} ms; playsIn a day '
        '${oneDay.toStringAsFixed(1)} ms, a year '
        '${yearPlays.toStringAsFixed(1)} ms',
      );
      // The year report: its reads and its one pass over the year's plays.
      final songs = {for (final t in store.loadAll()) t.id: t};
      final allTime = store.songPlays();
      late YearReport report;
      final reportMs = _timeMs(() {
        report = YearReport.build(
          year: year,
          now: DateTime.now(),
          firstPlayMs: store.firstPlayMs(),
          plays: store.playsIn(calendarYear),
          songs: songs,
          allTime: allTime,
          before: store.songPlays(
            range: DayRange(DateTime(1970), DateTime(year - 1, 12, 31)),
          ),
          compared: (
            range: DayRange.year(year - 1),
            plays: store.songPlays(range: DayRange.year(year - 1)),
          ),
        );
      });
      final monthMs = _timeMs(() => report.month(1));
      final beforeMs = _timeMs(
        () => store.songPlays(
          range: DayRange(DateTime(1970), DateTime(year - 1, 12, 31)),
        ),
      );
      final yearPlays2 = store.playsIn(calendarYear);
      final passMs = _timeMs(
        () => YearReport.build(
          year: year,
          now: DateTime.now(),
          firstPlayMs: store.firstPlayMs(),
          plays: yearPlays2,
          songs: songs,
          allTime: allTime,
          before: const {},
          compared: null,
        ),
      );
      // ignore: avoid_print
      print(
        'before-year read ${beforeMs.toStringAsFixed(1)} ms, the pass alone '
        '${passMs.toStringAsFixed(1)} ms',
      );
      // ignore: avoid_print
      print(
        'year report ${reportMs.toStringAsFixed(1)} ms, a month '
        '${monthMs.toStringAsFixed(1)} ms',
      );
      expect(report.totals.plays, greaterThan(0));
      expect(reportMs, lessThan(400));
      expect(monthMs, lessThan(100));
      expect(store.playsIn(DayRange.day(lastDay)), hasLength(100));
      expect(yearDays, lessThan(60));
      expect(gridYear, lessThan(150));
      expect(gridAll, lessThan(400));
      expect(oneDay, lessThan(10));
      expect(yearPlays, lessThan(150));
      expect(store.songPlays(range: month), isNotEmpty);
      expect(all, lessThan(150));
      expect(inMonth, lessThan(40));
      expect(inYear, lessThan(60));
      expect(tiles, lessThan(40));
      expect(days, lessThan(40));
    });

    test('plays are read from an index alone', () {
      final range = store.explainSongPlays(
        range: DayRange(DateTime(2025, 1, 1), DateTime(2025, 1, 31)),
      );
      expect(range, contains('COVERING INDEX history_by_time'));
      // Two months still read by time; anything longer reads every song's
      // plays in order (no sorting), measured faster from about 62 days on
      // a 3-year history.
      expect(
        store.explainSongPlays(
          range: DayRange(DateTime(2025, 1, 1), DateTime(2025, 3, 3)),
        ),
        contains('COVERING INDEX history_by_time'),
      );
      expect(
        store.explainSongPlays(range: DayRange.year(2025)),
        contains('COVERING INDEX history_by_track'),
      );
      expect(
        store.explainSongPlays(),
        contains('COVERING INDEX history_by_track'),
      );
    });
  });
}

/// Last play time [fillHistory] wrote.
var _historyEnd = 0;

/// Writes [playsPerDay] plays a day for [days] days, ending today, spread
/// over [ids] unevenly (some songs much more than others), with a mix of
/// finished and skipped plays.
void fillHistory(
  LibraryStore store,
  List<int> ids, {
  required int days,
  required int playsPerDay,
}) {
  final rows = <(int, int, int, String)>[];
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day - days + 1, 8);
  var seed = 7;
  int next(int bound) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed % bound;
  }

  for (var d = 0; d < days; d++) {
    final dayStart = DateTime(start.year, start.month, start.day + d, 8);
    for (var n = 0; n < playsPerDay; n++) {
      // Favorites: a quarter of plays go to the first 200 songs.
      final index = next(4) == 0 ? next(200) : next(ids.length);
      final atMs =
          dayStart.millisecondsSinceEpoch + n * 4 * 60 * 1000 + next(60000);
      final skipped = next(3) == 0;
      rows.add((
        ids[index],
        atMs,
        skipped ? next(20000) : 150000 + next(90000),
        skipped ? 'skipped' : 'finished',
      ));
      if (atMs > _historyEnd) _historyEnd = atMs;
    }
  }
  store.addPlays(rows);
}

double _timeMs(void Function() body) {
  final watch = Stopwatch()..start();
  body();
  return watch.elapsedMicroseconds / 1000;
}
