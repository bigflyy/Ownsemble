import 'day_range.dart';
import 'listening_stats.dart';
import 'play_stats.dart';
import 'track.dart';

/// A song that came back after a long break: when, and after how long.
typedef BackSong = ({Track track, int backMs, int gapDays});

/// A song first played in the year: when, and how often that year.
typedef NewSong = ({Track track, int firstMs, int plays});

/// A day and the time heard on it.
typedef BusyDay = ({DateTime day, int heardMs});

/// The song heard most in a year, with its own facts.
typedef SongOfYear = ({
  Track track,
  int plays,
  int listenedMs,

  /// The month (1-12) with most of its counted plays.
  int topMonth,

  /// Its first counted play of the year, Unix milliseconds.
  int firstMs,
});

/// One month of the report, shown when its bar is clicked.
typedef MonthFacts = ({
  int heardMs,
  int plays,
  RankedRow? topSong,
  RankedRow? topArtist,
  BusyDay? busiestDay,
});

/// A gap at least this long between two counted plays of a song makes
/// its next play "back after a break" (2 months).
const breakDays = 60;

/// Everything the year report shows (plan 04, D2; board 3 of the D2
/// canvas): totals compared with the year before, days with music and the
/// longest run of them, the busiest day, song of the year, top lists,
/// months, hours, songs new to you and songs back after a break.
///
/// Built from the year's plays alone, in one pass, plus three reads: each
/// song's first counted play ever ([allTime], for "new to you"), its last
/// counted play before the year ([before], for a break that spans New
/// Year), and the days the year is compared with ([compared]).
class YearReport {
  YearReport._(this.year, this.stats, this._plays, this._songs);

  factory YearReport.build({
    required int year,
    required DateTime now,
    required int? firstPlayMs,
    required List<PlayMoment> plays,
    required Map<int, Track> songs,
    required Map<int, SongPlays> allTime,
    required Map<int, SongPlays> before,
    required ({DayRange range, Map<int, SongPlays> plays})? compared,
  }) {
    final report = YearReport._(
      year,
      ListeningStats(songs, _sumBySong(plays)),
      plays,
      songs,
    );
    report._fill(now, firstPlayMs, allTime, before, compared);
    return report;
  }

  final int year;

  /// Totals and top lists of the year.
  final ListeningStats stats;

  final List<PlayMoment> _plays;
  final Map<int, Track> _songs;

  PeriodTotals get totals => stats.totals;

  /// The days compared with and their totals: the year before, or its same
  /// first days while this year holds today. Null when there is no such
  /// year (never: kept for symmetry with the Stats tiles).
  ({DayRange range, PeriodTotals totals})? compared;

  /// Days the app could record plays on: from 1 January, or the first
  /// recorded play, to 31 December or today.
  int recordedDays = 0;

  /// Whether some days of the year could not be recorded (yet).
  bool get partial => recordedDays < DayRange.year(year).dayCount;

  /// Days with any time heard.
  int daysWithMusic = 0;

  /// The longest run of days in a row with a counted play, and its last
  /// day (the earliest such run when two are as long).
  ({int days, DateTime? end}) longestRun = (days: 0, end: null);

  BusyDay? busiestDay;

  /// Plays with no heard time: recorded before the app kept it (schema 9,
  /// 6 Nov 2026). They count as plays but add no time.
  int untimedPlays = 0;

  /// The year's first play with a heard time, Unix milliseconds; null when
  /// it has none.
  int? firstTimedMs;

  /// Time heard on each day of the year, from 1 January.
  late final List<int> dayHeard;

  /// Time heard and counted plays per month (index 0 = January).
  final monthHeard = List.filled(12, 0);
  final monthPlays = List.filled(12, 0);

  /// Time heard by the hour plays started (0-23).
  final hourHeard = List.filled(24, 0);

  /// The hour most time was heard in.
  int get peakHour {
    var best = 0;
    for (var h = 1; h < 24; h++) {
      if (hourHeard[h] > hourHeard[best]) best = h;
    }
    return best;
  }

  /// Share of time heard, in whole percent, in the morning (5-12),
  /// afternoon (12-17), evening (17-22) and night (22-5).
  List<int> get dayParts {
    final all = hourHeard.fold(0, (a, b) => a + b);
    if (all == 0) return const [0, 0, 0, 0];
    int part(int from, int to) {
      var sum = 0;
      for (var h = from; h < to; h++) {
        sum += hourHeard[h % 24];
      }
      return (sum * 100 / all).round();
    }

    return [part(5, 12), part(12, 17), part(17, 22), part(22, 29)];
  }

  SongOfYear? songOfYear;

  /// Whether "new to you" can be told: plays were recorded before the
  /// year, so a first play in it is a real first.
  bool newKnown = false;

  /// Songs first played (counted) in the year, most played first.
  final newToYou = <NewSong>[];

  /// Songs back after a break of [breakDays] or more, the longest break
  /// first; each song once, with its longest break.
  final backAfterBreak = <BackSong>[];

  void _fill(
    DateTime now,
    int? firstPlayMs,
    Map<int, SongPlays> allTime,
    Map<int, SongPlays> before,
    ({DayRange range, Map<int, SongPlays> plays})? compared,
  ) {
    final yearRange = DayRange.year(year);
    final days = yearRange.days;
    dayHeard = List.filled(days.length, 0);
    final dayCounted = List.filled(days.length, false);
    final starts = [
      for (final day in days) day.millisecondsSinceEpoch,
      yearRange.endMs,
    ];

    // Plays are in time order: walk the day starts alongside them. A local
    // date for every play would cost most of the time here (tens of
    // thousands of plays): the month comes from the day, the hour from the
    // time since the day began, except on a day the clock changes.
    var day = 0;
    final yearDay0 = _dayNumber(days.first);
    // Each song's last counted play, as a day number (days since 1970).
    final lastCounted = <int, int>{
      for (final MapEntry(key: id, value: p) in before.entries)
        if (p.lastMs case final ms?)
          id: _dayNumber(DateTime.fromMillisecondsSinceEpoch(ms)),
    };
    final longestGap = <int, ({int backMs, int gapDays})>{};
    for (final p in _plays) {
      while (day + 1 < days.length && p.atMs >= starts[day + 1]) {
        day++;
      }
      final month = days[day].month - 1;
      final hour = starts[day + 1] - starts[day] == Duration.millisecondsPerDay
          ? (p.atMs - starts[day]) ~/ Duration.millisecondsPerHour
          : DateTime.fromMillisecondsSinceEpoch(p.atMs).hour;
      if (!p.timed) {
        untimedPlays++;
      } else {
        firstTimedMs ??= p.atMs;
      }
      dayHeard[day] += p.listenedMs;
      monthHeard[month] += p.listenedMs;
      hourHeard[hour] += p.listenedMs;
      if (!p.counted) continue;
      dayCounted[day] = true;
      monthPlays[month]++;
      final number = yearDay0 + day;
      if (lastCounted[p.trackId] case final last?) {
        final gap = number - last;
        final kept = longestGap[p.trackId];
        if (gap >= breakDays && (kept == null || gap > kept.gapDays)) {
          longestGap[p.trackId] = (backMs: p.atMs, gapDays: gap);
        }
      }
      lastCounted[p.trackId] = number;
    }

    // Days that could be recorded, and runs over them.
    final today = DateTime(now.year, now.month, now.day);
    final firstDay = firstPlayMs == null
        ? null
        : DayRange.day(DateTime.fromMillisecondsSinceEpoch(firstPlayMs)).first;
    var run = 0;
    for (final (i, d) in days.indexed) {
      if (d.isAfter(today)) break;
      if (firstDay == null || d.isBefore(firstDay)) continue;
      recordedDays++;
      if (dayHeard[i] > 0) daysWithMusic++;
      run = dayCounted[i] ? run + 1 : 0;
      if (run > longestRun.days) longestRun = (days: run, end: d);
      if (dayHeard[i] > (busiestDay?.heardMs ?? 0)) {
        busiestDay = (day: d, heardMs: dayHeard[i]);
      }
    }

    if (compared != null) {
      this.compared = (
        range: compared.range,
        totals: ListeningStats(_songs, compared.plays).totals,
      );
    }

    // Song of the year.
    final top = stats.top(RankBy.songs, limit: 1).firstOrNull;
    if (top != null) {
      final id = top.songs.single.id;
      final byMonth = List.filled(12, 0);
      int? first;
      for (final p in _plays) {
        if (p.trackId != id || !p.counted) continue;
        first ??= p.atMs;
        byMonth[DateTime.fromMillisecondsSinceEpoch(p.atMs).month - 1]++;
      }
      var month = 0;
      for (var m = 1; m < 12; m++) {
        if (byMonth[m] > byMonth[month]) month = m;
      }
      songOfYear = (
        track: top.songs.single,
        plays: top.plays,
        listenedMs: top.listenedMs,
        topMonth: month + 1,
        firstMs: first!,
      );
    }

    // New to you: only when plays were recorded before the year.
    newKnown = firstPlayMs != null && firstPlayMs < yearRange.startMs;
    if (newKnown) {
      for (final MapEntry(key: id, value: p) in stats.plays.entries) {
        final firstEver = allTime[id]?.firstMs;
        final track = _songs[id];
        if (track == null || p.plays == 0 || firstEver == null) continue;
        if (!yearRange.contains(firstEver)) continue;
        newToYou.add((track: track, firstMs: firstEver, plays: p.plays));
      }
      newToYou.sort(
        (a, b) => a.plays != b.plays
            ? b.plays - a.plays
            : a.firstMs.compareTo(b.firstMs),
      );
    }

    for (final MapEntry(key: id, value: gap) in longestGap.entries) {
      if (_songs[id] case final track?) {
        backAfterBreak.add((
          track: track,
          backMs: gap.backMs,
          gapDays: gap.gapDays,
        ));
      }
    }
    backAfterBreak.sort((a, b) => b.gapDays - a.gapDays);
  }

  /// The facts of [month] (1-12): time heard, counted plays, its top song
  /// and artist, and its busiest day.
  MonthFacts month(int month) {
    final range = DayRange.month(year, month);
    final inMonth = <PlayMoment>[];
    // Plays are in time order.
    for (final p in _plays) {
      if (p.atMs >= range.endMs) break;
      if (p.atMs >= range.startMs) inMonth.add(p);
    }
    final stats = ListeningStats(_songs, _sumBySong(inMonth));
    final first = DayRange(DateTime(year), range.first).dayCount - 1;
    BusyDay? busiest;
    for (var d = 0; d < range.dayCount; d++) {
      final heard = dayHeard[first + d];
      if (heard > (busiest?.heardMs ?? 0)) {
        busiest = (day: DateTime(year, month, d + 1), heardMs: heard);
      }
    }
    return (
      heardMs: monthHeard[month - 1],
      plays: monthPlays[month - 1],
      topSong: stats.top(RankBy.songs, limit: 1).firstOrNull,
      topArtist: stats.top(RankBy.artists, limit: 1).firstOrNull,
      busiestDay: busiest,
    );
  }

  /// [plays] added up per song, as [ListeningStats] takes them.
  static Map<int, SongPlays> _sumBySong(List<PlayMoment> plays) {
    final counts = <int, ({int plays, int heard, int? first, int? last})>{};
    for (final p in plays) {
      final kept =
          counts[p.trackId] ?? (plays: 0, heard: 0, first: null, last: null);
      counts[p.trackId] = (
        plays: kept.plays + (p.counted ? 1 : 0),
        heard: kept.heard + p.listenedMs,
        first: kept.first ?? (p.counted ? p.atMs : null),
        last: p.counted ? p.atMs : kept.last,
      );
    }
    return {
      for (final MapEntry(key: id, value: c) in counts.entries)
        id: SongPlays(
          plays: c.plays,
          listenedMs: c.heard,
          firstMs: c.first,
          lastMs: c.last,
        ),
    };
  }

  /// The calendar day of [day] as days since 1 January 1970, so that two
  /// days' difference is the days between them.
  static int _dayNumber(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
}
