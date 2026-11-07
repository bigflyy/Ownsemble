/// A run of whole local days, the first and the last included.
///
/// Plays belong to the local day they started on, so a range is measured
/// from the start of [first] to the start of the day after [last], in the
/// computer's time zone (a day with a clock change is 23 or 25 hours).
class DayRange {
  /// The days from [a] to [b], in either order; the time of day is dropped.
  factory DayRange(DateTime a, DateTime b) {
    final x = _dateOf(a), y = _dateOf(b);
    return x.isAfter(y) ? DayRange._(y, x) : DayRange._(x, y);
  }

  const DayRange._(this.first, this.last);

  /// The one day [day] is on.
  factory DayRange.day(DateTime day) => DayRange(day, day);

  /// The whole month [month] (1-12) of [year].
  factory DayRange.month(int year, int month) =>
      DayRange(DateTime(year, month), DateTime(year, month + 1, 0));

  /// The whole [year].
  factory DayRange.year(int year) =>
      DayRange(DateTime(year), DateTime(year, 12, 31));

  /// First day, at local midnight.
  final DateTime first;

  /// Last day, at local midnight.
  final DateTime last;

  /// Start of [first], Unix milliseconds.
  int get startMs => first.millisecondsSinceEpoch;

  /// Start of the day after [last], Unix milliseconds: the range ends just
  /// before it.
  int get endMs =>
      DateTime(last.year, last.month, last.day + 1).millisecondsSinceEpoch;

  /// How many days the range holds.
  int get dayCount =>
      DateTime.utc(
        last.year,
        last.month,
        last.day,
      ).difference(DateTime.utc(first.year, first.month, first.day)).inDays +
      1;

  /// Whether a moment ([ms], Unix milliseconds) falls on one of the days.
  bool contains(int ms) => ms >= startMs && ms < endMs;

  static DateTime _dateOf(DateTime time) =>
      DateTime(time.year, time.month, time.day);

  @override
  bool operator ==(Object other) =>
      other is DayRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'DayRange(${_iso(first)} - ${_iso(last)})';

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
