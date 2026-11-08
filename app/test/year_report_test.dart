import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/listening_stats.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/library/year_report.dart';

/// Saturday 7 November 2026.
final now = DateTime(2026, 11, 7, 14);

void main() {
  late LibraryStore store;
  late List<int> ids;
  late Map<int, Track> songs;

  void play(int id, DateTime at, {required double heardSec}) {
    final play = store.beginPlay(
      id,
      start: PlayStart.chosen,
      shuffle: false,
      atMs: at.millisecondsSinceEpoch,
    );
    store.updatePlay(
      play,
      listenedMs: (heardSec * 1000).round(),
      ended: PlayEnd.skipped,
    );
  }

  /// The report of [year] as the app reads it.
  YearReport reportOf(int year) => YearReport.build(
    year: year,
    now: now,
    firstPlayMs: store.firstPlayMs(),
    plays: store.playsIn(DayRange.year(year)),
    songs: songs,
    allTime: store.songPlays(),
    before: store.songPlays(
      range: DayRange(DateTime(1970), DateTime(year - 1, 12, 31)),
    ),
    compared: switch (comparedRange(
      PlayPeriod.year(offset: year - now.year),
      now,
    )) {
      final range? => (range: range, plays: store.songPlays(range: range)),
      null => null,
    },
  );

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    ids = store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Кино',
        title: 'Кукушка',
        album: 'Чёрный альбом',
        durationSec: 400,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 200,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_3',
        artist: 'Земфира',
        title: 'Хочешь?',
        durationSec: 200,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_4',
        artist: 'Кино',
        title: 'Группа крови',
        durationSec: 300,
        addedAt: 0,
      ),
    ]);
    songs = {for (final t in store.loadAll()) t.id: t};
    final [a, b, c, d] = ids;
    // The first recorded play.
    play(a, DateTime(2024, 12, 20, 20), heardSec: 300);
    // 2025: Кукушка three evenings in a row, then a 145-day break.
    for (var day = 5; day <= 7; day++) {
      play(a, DateTime(2025, 1, day, 20), heardSec: 300);
    }
    play(b, DateTime(2025, 3, 10, 8), heardSec: 150);
    play(b, DateTime(2025, 3, 10, 9), heardSec: 10); // skipped, not counted
    play(a, DateTime(2025, 6, 1, 21), heardSec: 300);
    play(c, DateTime(2025, 6, 2, 23, 30), heardSec: 200);
    play(c, DateTime(2025, 6, 2, 23, 45), heardSec: 200);
    play(d, DateTime(2025, 6, 3, 13), heardSec: 300);
    // 2026: Выхода нет again after more than a year and a half.
    play(b, DateTime(2026, 11, 2, 9), heardSec: 150);
  });
  tearDown(() => store.close());

  test('totals, compared with the year before', () {
    final report = reportOf(2025);
    expect(report.totals.plays, 8);
    expect(report.totals.listenedMs, 2060000);
    expect(report.totals.songs, 4);
    expect(report.totals.artists, 3);
    expect(report.compared!.totals.plays, 1);
    expect(report.compared!.range, DayRange.year(2024));
    expect(report.recordedDays, 365);
    expect(report.daysWithMusic, 7);
  });

  test('longest run of days with a counted play, and the busiest day', () {
    final report = reportOf(2025);
    // 5-7 Jan and 1-3 Jun are 3 days each: the first one stays.
    expect(report.longestRun.days, 3);
    expect(report.longestRun.end, DateTime(2025, 1, 7));
    expect(report.busiestDay!.day, DateTime(2025, 6, 2));
    expect(report.busiestDay!.heardMs, 400000);
    expect(report.dayHeard, hasLength(365));
    expect(report.dayHeard[4], 300000); // 5 Jan
  });

  test('song of the year and the top lists', () {
    final report = reportOf(2025);
    final best = report.songOfYear!;
    expect(best.track.title, 'Кукушка');
    expect(best.plays, 4);
    expect(best.listenedMs, 1200000);
    expect(best.topMonth, 1);
    expect(best.firstMs, DateTime(2025, 1, 5, 20).millisecondsSinceEpoch);
    expect(
      [for (final r in report.stats.top(RankBy.songs, limit: 5)) r.name],
      ['Кукушка', 'Хочешь?', 'Группа крови', 'Выхода нет'],
    );
    expect(
      [for (final r in report.stats.top(RankBy.artists, limit: 5)) r.name],
      ['Кино', 'Земфира', 'Сплин'],
    );
  });

  test('months, hours and parts of the day', () {
    final report = reportOf(2025);
    expect(report.monthHeard[0], 900000);
    expect(report.monthHeard[2], 160000);
    expect(report.monthHeard[5], 1000000);
    expect(report.monthHeard[11], 0);
    expect(report.peakHour, 20);
    // Morning 160 s, afternoon 300 s, evening 1200 s, night 400 s.
    expect(report.dayParts, [8, 15, 58, 19]);

    final june = report.month(6);
    expect(june.heardMs, 1000000);
    expect(june.plays, 4);
    expect(june.topSong!.name, 'Хочешь?');
    // Кино and Земфира have 2 plays each; Кино was heard longer.
    expect(june.topArtist!.name, 'Кино');
    expect(june.busiestDay!.day, DateTime(2025, 6, 2));
    expect(report.month(12).topSong, isNull);
  });

  test('new to you: first counted play ever in the year', () {
    final report = reportOf(2025);
    expect(report.newKnown, isTrue);
    expect(
      [for (final n in report.newToYou) n.track.title],
      ['Хочешь?', 'Выхода нет', 'Группа крови'],
    );
    expect(report.newToYou.first.plays, 2);
    // The year recording began: everything would look new.
    expect(reportOf(2024).newKnown, isFalse);
    expect(reportOf(2024).newToYou, isEmpty);
  });

  test('back after a break of 2 months or more, across years too', () {
    final y2025 = reportOf(2025);
    expect([for (final b in y2025.backAfterBreak) b.track.title], ['Кукушка']);
    expect(
      y2025.backAfterBreak.single.backMs,
      DateTime(2025, 6, 1, 21).millisecondsSinceEpoch,
    );
    expect(y2025.backAfterBreak.single.gapDays, 145);

    final y2026 = reportOf(2026);
    expect(
      [for (final b in y2026.backAfterBreak) b.track.title],
      ['Выхода нет'],
    );
    expect(y2026.backAfterBreak.single.gapDays, 602);
  });

  test('a year that holds today counts its days so far, compared with the '
      'same days of the year before', () {
    final report = reportOf(2026);
    expect(report.recordedDays, 311);
    expect(report.partial, isTrue);
    expect(
      report.compared!.range,
      DayRange(DateTime(2025, 1, 1), DateTime(2025, 11, 7)),
    );
    expect(report.compared!.totals.plays, 8);
    expect(reportOf(2025).partial, isFalse);
  });
}
