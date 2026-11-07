import 'day_range.dart';

/// Which kind of time a [PlayPeriod] is.
enum PeriodKind { week, month, year, all, custom }

const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The time a Plays number counts in (plan 04, B3 period option 2): the
/// page's period, or a Plays chip's own dates.
///
/// Week, Month and Year are the current one stepped back by [offset] (0 is
/// now, -1 the one before); with offset 0 they move with time, so a view
/// saved with "This month" shows the month it is opened in. A Custom period
/// is fixed dates (the user, 2026-11-07: "with custom dates - stay on those
/// dates. with week month or year - move with time"). Weeks start on Monday.
class PlayPeriod {
  const PlayPeriod.week({this.offset = 0})
    : kind = PeriodKind.week,
      custom = null;
  const PlayPeriod.month({this.offset = 0})
    : kind = PeriodKind.month,
      custom = null;
  const PlayPeriod.year({this.offset = 0})
    : kind = PeriodKind.year,
      custom = null;
  const PlayPeriod.all() : kind = PeriodKind.all, offset = 0, custom = null;
  const PlayPeriod.custom(DayRange this.custom)
    : kind = PeriodKind.custom,
      offset = 0;

  final PeriodKind kind;

  /// Steps back from the current week, month or year (0 or less).
  final int offset;

  /// The fixed days of a Custom period.
  final DayRange? custom;

  /// Whether the period follows today: the current week, month or year.
  bool get moves =>
      offset == 0 &&
      (kind == PeriodKind.week ||
          kind == PeriodKind.month ||
          kind == PeriodKind.year);

  /// The days the period covers when it is [now]; null for all time.
  DayRange? rangeAt(DateTime now) {
    switch (kind) {
      case PeriodKind.week:
        final monday = DateTime(
          now.year,
          now.month,
          now.day - (now.weekday - 1) + offset * 7,
        );
        return DayRange(
          monday,
          DateTime(monday.year, monday.month, monday.day + 6),
        );
      case PeriodKind.month:
        final first = DateTime(now.year, now.month + offset);
        return DayRange.month(first.year, first.month);
      case PeriodKind.year:
        return DayRange.year(now.year + offset);
      case PeriodKind.all:
        return null;
      case PeriodKind.custom:
        return custom;
    }
  }

  /// The period [by] steps later (negative: earlier). A Custom range moves
  /// by its own length: by whole months when it is whole months, else by
  /// its count of days.
  PlayPeriod step(int by) {
    switch (kind) {
      case PeriodKind.week:
        return PlayPeriod.week(offset: offset + by);
      case PeriodKind.month:
        return PlayPeriod.month(offset: offset + by);
      case PeriodKind.year:
        return PlayPeriod.year(offset: offset + by);
      case PeriodKind.all:
        return this;
      case PeriodKind.custom:
        final range = custom!;
        final months = _wholeMonths(range);
        if (months != null) {
          final first = DateTime(
            range.first.year,
            range.first.month + months * by,
          );
          return PlayPeriod.custom(
            DayRange(first, DateTime(first.year, first.month + months, 0)),
          );
        }
        final days = range.dayCount * by;
        return PlayPeriod.custom(
          DayRange(
            DateTime(
              range.first.year,
              range.first.month,
              range.first.day + days,
            ),
            DateTime(range.last.year, range.last.month, range.last.day + days),
          ),
        );
    }
  }

  /// Whether the next step still starts on or before today.
  bool canStepForward(DateTime now) {
    if (kind == PeriodKind.all) return false;
    if (kind != PeriodKind.custom) return offset < 0;
    final next = step(1).rangeAt(now)!;
    return !next.first.isAfter(DateTime(now.year, now.month, now.day));
  }

  /// This period as a saved view keeps it: the current week, month or year
  /// and all time as they are, anything else as fixed dates.
  PlayPeriod fixedAt(DateTime now) =>
      moves || kind == PeriodKind.all || kind == PeriodKind.custom
      ? this
      : PlayPeriod.custom(rangeAt(now)!);

  /// What the period bar shows: "2 - 8 Nov 2026", "November 2026", "2026",
  /// "All time", "1 Oct - 30 Nov 2025".
  String label(DateTime now) {
    if (kind == PeriodKind.all) return 'All time';
    return rangeLabel(rangeAt(now)!);
  }

  /// How a saved view's name starts: "This week", "This month", "This
  /// year", or the dates; null for all time.
  String? nameAt(DateTime now) => switch (kind) {
    PeriodKind.all => null,
    PeriodKind.week when offset == 0 => 'This week',
    PeriodKind.month when offset == 0 => 'This month',
    PeriodKind.year when offset == 0 => 'This year',
    _ => label(now),
  };

  /// Days as words: a whole year as "2025", a whole month as "October 2025",
  /// otherwise "1 Oct - 30 Nov 2025" (the year said once when both ends
  /// share it, and the month once when both ends share that too).
  static String rangeLabel(DayRange range) {
    final a = range.first, b = range.last;
    final months = _wholeMonths(range);
    if (months == 12 && a.month == 1) return '${a.year}';
    if (months == 1) return '${_monthFull[a.month - 1]} ${a.year}';
    if (a.year != b.year) {
      return '${a.day} ${_monthShort[a.month - 1]} ${a.year} - '
          '${b.day} ${_monthShort[b.month - 1]} ${b.year}';
    }
    if (a.month == b.month) {
      return a.day == b.day
          ? '${a.day} ${_monthShort[a.month - 1]} ${a.year}'
          : '${a.day} - ${b.day} ${_monthShort[a.month - 1]} ${a.year}';
    }
    return '${a.day} ${_monthShort[a.month - 1]} - '
        '${b.day} ${_monthShort[b.month - 1]} ${b.year}';
  }

  /// How many whole months [range] is, or null when it does not start on a
  /// month's first day and end on a month's last.
  static int? _wholeMonths(DayRange range) {
    final a = range.first, b = range.last;
    if (a.day != 1 || DateTime(b.year, b.month, b.day + 1).day != 1) {
      return null;
    }
    return (b.year - a.year) * 12 + b.month - a.month + 1;
  }

  /// Kept in settings and saved views: {"k": "month", "o": -1} or
  /// {"k": "custom", "a": "2025-10-01", "b": "2025-11-30"}.
  Object toJson() => {
    'k': kind.name,
    if (offset != 0) 'o': offset,
    if (custom case final range?) ...{
      'a': _isoDate(range.first),
      'b': _isoDate(range.last),
    },
  };

  /// Reads [toJson]'s form back; null when it is not one.
  static PlayPeriod? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = PeriodKind.values.asNameMap()[json['k']];
    final offset = json['o'] is int ? json['o'] as int : 0;
    switch (kind) {
      case PeriodKind.week:
        return PlayPeriod.week(offset: offset);
      case PeriodKind.month:
        return PlayPeriod.month(offset: offset);
      case PeriodKind.year:
        return PlayPeriod.year(offset: offset);
      case PeriodKind.all:
        return const PlayPeriod.all();
      case PeriodKind.custom:
        final a = DateTime.tryParse('${json['a']}');
        final b = DateTime.tryParse('${json['b']}');
        if (a == null || b == null) return null;
        return PlayPeriod.custom(DayRange(a, b));
      case null:
        return null;
    }
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is PlayPeriod &&
      other.kind == kind &&
      other.offset == offset &&
      other.custom == custom;

  @override
  int get hashCode => Object.hash(kind, offset, custom);

  @override
  String toString() => 'PlayPeriod(${toJson()})';
}
