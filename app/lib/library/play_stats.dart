import 'day_range.dart';
import 'library_records.dart';
import 'listening_calendar.dart';

export 'listening_calendar.dart' show PlayMoment, weekHour;

/// Where play numbers come from: the library database, a stand-in in
/// tests.
abstract interface class PlayStatsSource {
  Map<int, SongPlays> songPlays({DayRange? range, int? trackId});
  List<int> listenedIn(List<DayRange> ranges);

  /// Start of the earliest recorded play, Unix milliseconds; null when
  /// nothing was played yet.
  int? firstPlayMs();

  /// Every play in [range] (null: all time), oldest first.
  List<PlayMoment> playsIn(DayRange? range);

  /// Time heard on each day of [range], in order, milliseconds.
  List<int> heardByDay(DayRange range);

  /// Time heard by the local weekday and hour plays started in [range]
  /// (null: all time): 7 x 24 values, indexed by [weekHour].
  List<int> heardByWeekHour(DayRange? range);
}

/// What one song's plays add up to over some days (or all time).
///
/// History keeps every play as it happened; counting is decided here, at
/// query time, so the rule can change without touching stored plays (plan
/// 04, B1). The rule is [isCountedPlay].
class SongPlays {
  const SongPlays({
    required this.plays,
    required this.listenedMs,
    this.firstMs,
    this.lastMs,
    this.starts = 0,
    this.earlySkips = 0,
  });

  /// Counted plays.
  final int plays;

  /// Time heard over all plays, counted or not (skips too). Plays recorded
  /// before heard time was (schema 9) add nothing.
  final int listenedMs;

  /// Start of the first and of the last counted play, Unix milliseconds;
  /// null when no play counted.
  final int? firstMs;
  final int? lastMs;

  /// Every recorded start of the song, counted or not.
  final int starts;

  /// Plays skipped early: another song started within [earlySkipMs].
  final int earlySkips;

  /// Whether the song is skipped early most times it starts (at least 3).
  bool get oftenSkipped => starts >= 3 && earlySkips * 2 > starts;
}

/// A play skipped before this much was heard is an early skip (plan 04, B1).
const earlySkipMs = 20 * 1000;

/// Heard time at which a play counts: half the song, but never more than
/// 4 minutes (Last.fm's rule).
const countedPlayCapMs = 4 * 60 * 1000;

/// Songs this short (seconds) count only when played to their end.
const shortSongSec = 30;

/// Whether a play counts as a play of the song.
///
/// It counts once heard for half the song or 4 minutes, whichever is less;
/// how it ended does not matter then. A song of 30 s or less counts only when
/// it finished. A play recorded before heard time was ([listenedMs] null)
/// counts, as History showed it.
bool isCountedPlay({
  required int? listenedMs,
  required PlayEnd? ended,
  required int durationSec,
}) {
  if (listenedMs == null) return true;
  if (durationSec <= shortSongSec) return ended == PlayEnd.finished;
  final line = durationSec * 500;
  return listenedMs >= (line < countedPlayCapMs ? line : countedPlayCapMs);
}

/// [isCountedPlay] as an SQL expression over `history h` joined with the
/// song's `tracks t`; 1 when the play counts, else 0.
const countedPlaySql =
    '(CASE WHEN h.listened_ms IS NULL THEN 1 '
    "WHEN t.duration_sec <= $shortSongSec THEN h.ended IS 'finished' "
    'ELSE h.listened_ms >= min(t.duration_sec * 500, $countedPlayCapMs) END)';

/// 1 when a play in `history h` was skipped early, else 0.
const earlySkipSql = "(h.ended IS 'skipped' AND h.listened_ms < $earlySkipMs)";
