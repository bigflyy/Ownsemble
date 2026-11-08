import 'library_records.dart';

/// One play as the Calendar tab and the year report read it (plan 04, D2):
/// which song, when it started, how long it was heard and whether it
/// counted ([isCountedPlay]).
class PlayMoment {
  const PlayMoment({
    required this.trackId,
    required this.atMs,
    required this.listenedMs,
    required this.counted,
    this.ended,
    this.timed = true,
  });

  final int trackId;

  /// When the song started to sound, Unix milliseconds. The play belongs to
  /// the local day and hour of this moment.
  final int atMs;

  /// Time heard; 0 for plays recorded before heard time was (schema 9).
  final int listenedMs;

  final bool counted;

  /// False for a play recorded before heard time was kept (schema 9,
  /// 6 Nov 2026): its [listenedMs] is 0 because it is unknown.
  final bool timed;

  /// How the play ended; null while it goes on, after a crash, or before
  /// schema 9.
  final PlayEnd? ended;
}

/// Shades for a heatmap of [values] (time heard per day or per hour): 0 for
/// nothing, 4 for the busiest, and each quarter of the busiest below one
/// shade lighter (a quarter or less is 1).
List<int> heatLevels(List<int> values) {
  final most = values.fold(0, (top, v) => v > top ? v : top);
  return [
    for (final v in values)
      if (v <= 0)
        0
      else
        switch (v / most) {
          <= 0.25 => 1,
          <= 0.5 => 2,
          <= 0.75 => 3,
          _ => 4,
        },
  ];
}

/// Index of a weekday ([DateTime.monday] .. [DateTime.sunday]) and an hour
/// (0-23) in a heard-by-weekday-and-hour list: Monday's hours first.
int weekHour(int weekday, int hour) => (weekday - 1) * 24 + hour;
