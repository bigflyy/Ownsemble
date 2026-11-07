import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/listening_stats.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/play_stats.dart';
import 'package:ownsemble/library/track.dart';

/// Sunday 8 November 2026, mid-day.
final now = DateTime(2026, 11, 8, 14);

Track track(int id, String artist, String title, {String? album}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: title,
  album: album,
  durationSec: 200,
);

SongPlays plays(int n, {int listenedSec = 0}) =>
    SongPlays(plays: n, listenedMs: listenedSec * 1000, starts: n == 0 ? 1 : n);

void main() {
  final songs = {
    for (final t in [
      track(1, 'Кино', 'Группа крови', album: 'Группа крови'),
      track(2, 'Кино', 'Кукушка', album: 'Чёрный альбом'),
      track(3, 'Кино', 'Закрой за мной дверь', album: 'Группа крови'),
      track(4, 'Zemfira', 'Искала', album: 'Вендетта'),
      track(5, 'Zemfira', 'Хочешь?'),
      track(6, 'Сплин', 'Выхода нет', album: 'Гранатовый альбом'),
    ])
      t.id: t,
  };

  group('totals', () {
    test('add up counted plays, time heard, and the songs and artists '
        'with a counted play', () {
      final stats = ListeningStats(songs, {
        1: plays(5, listenedSec: 1000),
        2: plays(2, listenedSec: 400),
        4: plays(1, listenedSec: 200),
        // Heard only in skips: time counts, the song and artist do not.
        6: plays(0, listenedSec: 15),
      });
      expect(stats.totals.plays, 8);
      expect(stats.totals.listenedMs, 1615000);
      expect(stats.totals.songs, 3);
      expect(stats.totals.artists, 2);
    });

    test('count plays of songs the library no longer lists', () {
      final stats = ListeningStats(songs, {
        1: plays(1, listenedSec: 200),
        99: plays(3, listenedSec: 600),
      });
      expect(stats.totals.plays, 4);
      expect(stats.totals.songs, 2);
      expect(stats.totals.artists, 1);
      expect(stats.top(RankBy.songs).map((r) => r.name), ['Группа крови']);
    });
  });

  group('top', () {
    final stats = ListeningStats(songs, {
      1: plays(5, listenedSec: 1000),
      2: plays(2, listenedSec: 400),
      3: plays(2, listenedSec: 500),
      4: plays(4, listenedSec: 800),
      5: plays(1, listenedSec: 100),
      6: plays(0, listenedSec: 15),
    });

    test('songs: most counted plays first, then most time heard', () {
      final rows = stats.top(RankBy.songs);
      expect(rows.map((r) => r.name), [
        'Группа крови',
        'Искала',
        'Закрой за мной дверь',
        'Кукушка',
        'Хочешь?',
      ]);
      expect(rows.first.detail, 'Кино');
      expect(rows.first.songs.single.id, 1);
      expect(rows.first.plays, 5);
      expect(rows.first.listenedMs, 1000000);
    });

    test('artists add up their songs, which are listed most played first', () {
      final rows = stats.top(RankBy.artists);
      expect(rows.map((r) => r.name), ['Кино', 'Zemfira']);
      expect(rows.first.plays, 9);
      expect(rows.first.listenedMs, 1900000);
      expect(rows.first.detail, '3 songs played');
      expect(rows.first.songs.map((t) => t.id), [1, 3, 2]);
      expect(rows[1].detail, '2 songs played');
    });

    test('albums group by title and artist and leave out songs without '
        'one', () {
      final rows = stats.top(RankBy.albums);
      expect(rows.map((r) => r.name), [
        'Группа крови',
        'Вендетта',
        'Чёрный альбом',
      ]);
      expect(rows.first.plays, 7);
      expect(rows.first.detail, 'Кино');
      expect(rows.first.songs.map((t) => t.id), [1, 3]);
    });

    test('the same album title by two artists is two albums', () {
      final mixed = ListeningStats(
        {
          1: track(1, 'A', 'One', album: 'Best'),
          2: track(2, 'B', 'Two', album: 'Best'),
        },
        {1: plays(2), 2: plays(1)},
      );
      expect(mixed.top(RankBy.albums).map((r) => r.detail), ['A', 'B']);
    });

    test('a limit keeps the first rows', () {
      expect(stats.top(RankBy.songs, limit: 2), hasLength(2));
    });

    test('one song played once says "1 song played"', () {
      final one = ListeningStats(songs, {4: plays(1)});
      expect(one.top(RankBy.artists).single.detail, '1 song played');
    });
  });

  group('compared range', () {
    test('a period that holds today is compared with the same days of '
        'the one before', () {
      expect(
        comparedRange(const PlayPeriod.month(), now),
        DayRange(DateTime(2026, 10, 1), DateTime(2026, 10, 8)),
      );
      expect(
        comparedRange(const PlayPeriod.year(), now),
        DayRange(DateTime(2025, 1, 1), DateTime(2025, 11, 8)),
      );
      // Monday 2 to Sunday 8 November: today ends the week, all 7 days.
      expect(
        comparedRange(const PlayPeriod.week(), now),
        DayRange(DateTime(2026, 10, 26), DateTime(2026, 11, 1)),
      );
    });

    test('a past period is compared with the whole one before', () {
      expect(
        comparedRange(const PlayPeriod.month(offset: -1), now),
        DayRange.month(2026, 9),
      );
      expect(
        comparedRange(
          PlayPeriod.custom(
            DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30)),
          ),
          now,
        ),
        DayRange(DateTime(2025, 8, 1), DateTime(2025, 9, 30)),
      );
    });

    test('the same days of a shorter month stop at its end', () {
      final march31 = DateTime(2026, 3, 31, 9);
      expect(
        comparedRange(const PlayPeriod.month(), march31),
        DayRange.month(2026, 2),
      );
    });

    test('all time has nothing to compare with', () {
      expect(comparedRange(const PlayPeriod.all(), now), isNull);
    });
  });

  group('change', () {
    final october = DayRange(DateTime(2026, 10, 1), DateTime(2026, 10, 8));
    final firstPlay = DateTime(2026, 9, 20).millisecondsSinceEpoch;

    test('says the change in percent against the compared days', () {
      expect(changeAgainst(12, 10, october, firstPlayMs: firstPlay), (
        text: '+20% vs 1 - 8 Oct 2026',
        up: true,
      ));
      expect(changeAgainst(7, 10, october, firstPlayMs: firstPlay), (
        text: '-30% vs 1 - 8 Oct 2026',
        up: false,
      ));
      expect(changeAgainst(10, 10, october, firstPlayMs: firstPlay), (
        text: 'Same as 1 - 8 Oct 2026',
        up: null,
      ));
    });

    test('nothing before: says so instead of a percent', () {
      expect(changeAgainst(5, 0, october, firstPlayMs: firstPlay), (
        text: 'Nothing in 1 - 8 Oct 2026',
        up: null,
      ));
    });

    test('days before the first recorded play are not compared', () {
      final later = DateTime(2026, 11, 2, 18).millisecondsSinceEpoch;
      expect(changeAgainst(5, 0, october, firstPlayMs: later), (
        text: 'Counting since 2 Nov 2026',
        up: null,
      ));
    });

    test('all time says when counting began', () {
      expect(changeAgainst(5, null, null, firstPlayMs: firstPlay), (
        text: 'Counting since 20 Sep 2026',
        up: null,
      ));
      expect(changeAgainst(0, null, null, firstPlayMs: null), isNull);
    });
  });
}
