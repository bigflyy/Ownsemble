import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/day_range.dart';
import '../library/library_records.dart';
import '../library/play_period.dart';
import '../library/play_stats.dart';
import '../library/track.dart';
import 'cover_tile.dart';
import 'song_filters.dart';
import 'stat_text.dart';
import 'theme.dart';

/// Day and month names for the Calendar tab and the year report.
const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// A day as "Fri 6 Nov 2026", or "Fri 6 Nov" without [year].
String calendarDayText(DateTime day, {bool year = true}) =>
    '${weekdayShort[day.weekday - 1]} ${day.day} '
    '${monthShort[day.month - 1]}${year ? ' ${day.year}' : ''}';

/// "2026-11-06", for widget keys.
String isoDay(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Heard time of one play as "2:31"; "-" for none (plays recorded before
/// heard time was).
String _clock(int ms) {
  if (ms <= 0) return '-';
  final seconds = (ms / 1000).round();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// "09:05", local time of a play's start.
String _timeOfDay(int ms) {
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

/// The green of a heatmap shade (1-4); [OwnColors.hover] for 0.
Color heatColor(OwnColors colors, int level) => level == 0
    ? colors.hover
    : colors.source3.withValues(
        alpha: const [0.28, 0.48, 0.70, 0.95][level - 1],
      );

/// The Calendar tab of the Stats place (plan 04, D2; board 2 of the D2
/// canvas, picked by the user on 2026-11-08).
///
/// Twelve small months of the page period's year, each day shaded by the
/// time heard that day. A click picks a day, Shift+click another day picks
/// the days between; the panel beside the months lists their plays in time
/// order. Below, "When you listen" adds up the page period by weekday and
/// hour. Days before the first recorded play are hatched: nothing could be
/// recorded then.
class StatsCalendar extends StatefulWidget {
  const StatsCalendar({
    super.key,
    required this.filters,
    required this.byId,
    required this.onPlay,
  });

  final SongFilters filters;

  /// The library's songs by id, to name the plays.
  final Map<int, Track> byId;

  /// Plays [list] from [index].
  final void Function(List<Track> list, int index) onPlay;

  @override
  State<StatsCalendar> createState() => _StatsCalendarState();
}

class _StatsCalendarState extends State<StatsCalendar> {
  /// Days the user picked, and the page period they were picked in: when
  /// the period changes, the latest day played in the new one is shown.
  DayRange? _picked;
  PlayPeriod? _pickedIn;

  /// The day a Shift+click reaches from.
  DateTime? _anchor;

  // What was read, and for which days and plays version.
  ({int year, int version, List<int> heard})? _yearDays;
  ({DayRange? range, int version, List<int> grid})? _hours;
  ({int version, _PickedDays days})? _picks;

  static const _cell = 18.0;
  static const _gap = 3.0;
  static const _monthWidth = 7 * _cell + 6 * _gap;
  static const _monthTitle = 26.0;
  static const _monthHeight = _monthTitle + 6 * _cell + 5 * _gap;
  static const _monthSpacing = 18.0;
  static const _monthRunSpacing = 16.0;

  /// The panel stands beside the months while 3 or 4 of them fit in a row
  /// next to a panel this wide (3 x 4 or 4 x 3 months, the panel as tall);
  /// with less room it goes below them, its list at most this tall.
  static const _panelMinWidth = 320.0;
  static const _narrowListHeight = 340.0;

  List<int> _heardInYear(int year, int version) {
    final kept = _yearDays;
    if (kept != null && kept.year == year && kept.version == version) {
      return kept.heard;
    }
    final heard = widget.filters.heardByDay(DayRange.year(year));
    _yearDays = (year: year, version: version, heard: heard);
    return heard;
  }

  List<int> _grid(DayRange? range, int version) {
    final kept = _hours;
    if (kept != null && kept.range == range && kept.version == version) {
      return kept.grid;
    }
    final grid = widget.filters.heardByWeekHour(range);
    _hours = (range: range, version: version, grid: grid);
    return grid;
  }

  _PickedDays _daysOf(DayRange range, int version) {
    final kept = _picks;
    if (kept != null && kept.days.range == range && kept.version == version) {
      return kept.days;
    }
    final days = _PickedDays(range, widget.filters.playsIn(range), widget.byId);
    _picks = (version: version, days: days);
    return days;
  }

  void _pick(DateTime day, DayRange? shown) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      final from = _anchor ?? shown?.first;
      if (shift && from != null && shown != null) {
        _picked = DayRange(from, day);
        _anchor = from;
      } else {
        _picked = DayRange.day(day);
        _anchor = day;
      }
      _pickedIn = widget.filters.period;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final filters = widget.filters;
    final now = filters.now;
    final today = DateTime(now.year, now.month, now.day);
    final period = filters.period;
    final periodRange = period.rangeAt(now);
    final year = (periodRange?.last ?? today).year;
    final version = filters.playsVersion;
    final heard = _heardInYear(year, version);
    final yearStart = DateTime(year);
    final firstMs = filters.firstPlayMs;
    final firstDay = firstMs == null
        ? null
        : DayRange.day(DateTime.fromMillisecondsSinceEpoch(firstMs)).first;

    int dayIndex(DateTime day) => DayRange(yearStart, day).dayCount - 1;

    // The days shown in the panel: the picked ones, or the latest day
    // played in the page period.
    if (_pickedIn != period) {
      _picked = null;
      _anchor = null;
    }
    var shown = _picked;
    if (shown == null) {
      final from = periodRange == null || periodRange.first.isBefore(yearStart)
          ? yearStart
          : periodRange.first;
      var day = periodRange == null || periodRange.last.isAfter(today)
          ? today
          : periodRange.last;
      if (day.year > year) day = DateTime(year, 12, 31);
      while (!day.isBefore(from)) {
        if (heard[dayIndex(day)] > 0) {
          shown = DayRange.day(day);
          break;
        }
        day = DateTime(day.year, day.month, day.day - 1);
      }
    }

    final levels = heatLevels(heard);
    Widget month(int m) {
      final first = DateTime(year, m);
      final lead = first.weekday - 1;
      final count = DateTime(year, m + 1, 0).day;
      var monthMs = 0;
      final cells = <Widget>[
        for (var i = 0; i < lead; i++)
          const SizedBox(width: _cell, height: _cell),
      ];
      for (var d = 1; d <= count; d++) {
        final day = DateTime(year, m, d);
        final index = dayIndex(day);
        final future = day.isAfter(today);
        final before = firstDay != null && day.isBefore(firstDay);
        if (!future && !before) monthMs += heard[index];
        final name = calendarDayText(day);
        final tip = future
            ? name
            : before
            ? '$name: before the app recorded plays'
            : heard[index] > 0
            ? '$name: ${listenedText(heard[index])}'
            : '$name: nothing played';
        cells.add(
          Tooltip(
            key: ValueKey('cal-day-${isoDay(day)}'),
            message: tip,
            waitDuration: const Duration(milliseconds: 400),
            child: _DayCell(
              colors: colors,
              level: levels[index],
              future: future,
              before: before,
              chosen:
                  shown != null && shown.contains(day.millisecondsSinceEpoch),
              onTap: future ? null : () => _pick(day, shown),
            ),
          ),
        );
      }
      return SizedBox(
        key: ValueKey('cal-month-$m'),
        width: _monthWidth,
        height: _monthHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: _monthTitle,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      monthFull[m - 1],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (monthMs > 0)
                    Text(
                      shortListenedText(monthMs),
                      style: TextStyle(fontSize: 12, color: colors.dim2),
                    ),
                ],
              ),
            ),
            Wrap(spacing: _gap, runSpacing: _gap, children: cells),
          ],
        ),
      );
    }

    final months = [for (var m = 1; m <= 12; m++) month(m)];
    Widget panel({required bool fill}) => _DaysPanel(
      key: const ValueKey('cal-panel'),
      fill: fill,
      picked: shown == null ? null : _daysOf(shown, version),
      nothingIn: period.label(now),
      countingSince:
          firstMs != null && periodRange != null && periodRange.endMs <= firstMs
          ? PlayPeriod.rangeLabel(DayRange.day(firstDay!))
          : null,
      onPlay: widget.onPlay,
    );
    final hint = Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'Click a day for its plays. Shift+click another day for the days '
        'between.',
        style: TextStyle(fontSize: 12, color: colors.dim2),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final perRow =
            ((width - 20 - _panelMinWidth + _monthSpacing) /
                    (_monthWidth + _monthSpacing))
                .floor()
                .clamp(0, 4);
        final Widget days;
        if (perRow >= 3) {
          final rows = (12 / perRow).ceil();
          final height = rows * _monthHeight + (rows - 1) * _monthRunSpacing;
          days = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: perRow * _monthWidth + (perRow - 1) * _monthSpacing,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: _monthSpacing,
                      runSpacing: _monthRunSpacing,
                      children: months,
                    ),
                    hint,
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: SizedBox(height: height, child: panel(fill: true)),
              ),
            ],
          );
        } else {
          days = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: _monthSpacing,
                runSpacing: _monthRunSpacing,
                children: months,
              ),
              hint,
              const SizedBox(height: 16),
              panel(fill: false),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              days,
              const SizedBox(height: 20),
              _HoursCard(
                key: const ValueKey('cal-hours'),
                grid: _grid(periodRange, version),
                what: period.kind == PeriodKind.all
                    ? 'All time listened by weekday and hour'
                    : 'Time listened in ${period.label(now)} by weekday '
                          'and hour',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One day of a small month: shaded by time heard, outlined when it has
/// not come yet, hatched before the first recorded play, ringed when
/// chosen.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.colors,
    required this.level,
    required this.future,
    required this.before,
    required this.chosen,
    required this.onTap,
  });

  final OwnColors colors;
  final int level;
  final bool future;
  final bool before;
  final bool chosen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const size = _StatsCalendarState._cell;
    final radius = BorderRadius.circular(4);
    Widget cell = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: future || before ? null : heatColor(colors, level),
        border: future ? Border.all(color: colors.line) : null,
        borderRadius: radius,
      ),
      foregroundDecoration: chosen
          ? BoxDecoration(
              border: Border.all(color: colors.accent, width: 2),
              borderRadius: radius,
            )
          : null,
      child: before
          ? CustomPaint(painter: _Hatch(colors.text.withValues(alpha: 0.12)))
          : null,
    );
    if (onTap != null) {
      cell = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: cell),
      );
    }
    return cell;
  }
}

/// Thin diagonal lines: days nothing could be recorded on.
class _Hatch extends CustomPainter {
  const _Hatch(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
    );
    for (var x = -size.height; x < size.width; x += 5) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Hatch old) => old.color != color;
}

/// What the panel shows for the chosen days, worked out once per read: a
/// year of days can hold tens of thousands of plays.
class _PickedDays {
  _PickedDays(this.range, this.plays, Map<int, Track> byId) {
    final oneDay = range.dayCount == 1;
    DateTime? lastDay;
    final seen = <int>{};
    for (final (i, p) in plays.indexed) {
      heardMs += p.listenedMs;
      if (p.counted) counted++;
      final track = byId[p.trackId];
      // A song no longer in the library adds to the numbers but has no row.
      if (track == null) continue;
      if (seen.add(track.id)) songs.add(track);
      if (!oneDay) {
        final at = DateTime.fromMillisecondsSinceEpoch(p.atMs);
        final day = DateTime(at.year, at.month, at.day);
        if (day != lastDay) {
          entries.add((day: day, play: null, track: null));
          lastDay = day;
        }
      }
      entries.add((day: null, play: i, track: track));
    }
  }

  final DayRange range;
  final List<PlayMoment> plays;

  /// Day headings (a range only) and plays, in time order.
  final entries = <({DateTime? day, int? play, Track? track})>[];

  /// Each song once, in the order it was first played.
  final songs = <Track>[];
  var heardMs = 0;
  var counted = 0;

  static const dayHeight = 34.0;
  static const rowHeight = 46.0;

  double get listHeight => entries.fold(
    0.0,
    (sum, e) => sum + (e.day != null ? dayHeight : rowHeight),
  );
}

/// The chosen days: what they add up to, a button that plays their songs,
/// and every play in time order (a range names each day above its plays).
///
/// With [fill] the list takes the panel's height; without, it is as tall as
/// its rows, up to [_StatsCalendarState._narrowListHeight].
class _DaysPanel extends StatelessWidget {
  const _DaysPanel({
    super.key,
    required this.fill,
    required this.picked,
    required this.nothingIn,
    required this.countingSince,
    required this.onPlay,
  });

  final bool fill;

  /// The chosen days; null when nothing was played in the period.
  final _PickedDays? picked;

  /// The page period's name, for "Nothing played in ...".
  final String nothingIn;

  /// The first recorded day, when the whole period lies before it.
  final String? countingSince;
  final void Function(List<Track> list, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final picked = this.picked;
    final songs = picked?.songs ?? const <Track>[];

    final String title;
    final String sub;
    if (picked == null) {
      title = 'Nothing played in $nothingIn';
      sub = countingSince == null ? '' : 'Counting since $countingSince';
    } else {
      final range = picked.range, count = picked.plays.length;
      final oneDay = range.dayCount == 1;
      title = oneDay
          ? calendarDayText(range.first)
          : PlayPeriod.rangeLabel(range);
      final days = oneDay ? '' : '${range.dayCount} days: ';
      sub = count == 0
          ? '${days}nothing played'
          : '$days${listenedText(picked.heardMs)}, '
                '${count == 1 ? '1 play' : '$count plays'}, '
                '${picked.counted} counted';
    }

    final entries = picked?.entries ?? const [];
    final list = ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.day case final day?) {
          return SizedBox(
            height: _PickedDays.dayHeight,
            child: Align(
              alignment: const Alignment(-1, 0.5),
              child: Text(
                calendarDayText(day, year: false),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.dim,
                ),
              ),
            ),
          );
        }
        final track = entry.track!;
        return _PlayRow(
          key: ValueKey('cal-play-${entry.play}'),
          play: picked!.plays[entry.play!],
          track: track,
          onTap: () => onPlay(songs, songs.indexOf(track)),
        );
      },
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: colors.dim2),
                        ),
                      ),
                  ],
                ),
              ),
              if (songs.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('cal-play-all'),
                  onPressed: () => onPlay(songs, 0),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Play these songs'),
                ),
            ],
          ),
          if (entries.isNotEmpty) ...[
            const SizedBox(height: 6),
            if (fill)
              Expanded(child: list)
            else
              SizedBox(
                height: picked!.listHeight.clamp(
                  0.0,
                  _StatsCalendarState._narrowListHeight,
                ),
                child: list,
              ),
          ] else if (fill)
            const Spacer(),
        ],
      ),
    );
  }
}

/// One play in the panel: start time, cover, song, time heard, and a mark
/// when it did not count.
class _PlayRow extends StatelessWidget {
  const _PlayRow({
    super.key,
    required this.play,
    required this.track,
    required this.onTap,
  });

  final PlayMoment play;
  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final mark = play.counted
        ? null
        : play.ended == PlayEnd.skipped
        ? 'skipped'
        : play.ended == null
        ? null
        : 'not counted';
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      hoverColor: colors.hover,
      onTap: onTap,
      child: SizedBox(
        height: _PickedDays.rowHeight,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                _timeOfDay(play.atMs),
                style: TextStyle(
                  fontSize: 12,
                  color: colors.dim2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            TrackTile(track: track, size: 32, radius: 6),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.dim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _clock(play.listenedMs),
              style: TextStyle(
                fontSize: 12,
                color: colors.dim,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (mark != null)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  mark,
                  style: TextStyle(fontSize: 11, color: colors.dim2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "When you listen": time heard by weekday (rows) and hour (columns).
class _HoursCard extends StatelessWidget {
  const _HoursCard({super.key, required this.grid, required this.what});

  final List<int> grid;
  final String what;

  /// Hour cells are this wide at most and narrow down to [_cellMinW] to
  /// fit the card; below that the grid scrolls sideways.
  static const _cellW = 22.0;
  static const _cellMinW = 12.0;
  static const _cellH = 16.0;
  static const _gap = 3.0;
  static const _nameW = 36.0;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final levels = heatLevels(grid);
    final small = TextStyle(fontSize: 10, color: colors.dim2);
    Widget swatch(int level) => Container(
      width: 14,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: heatColor(colors, level),
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'When you listen',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(what, style: TextStyle(fontSize: 13, color: colors.dim2)),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final cellW = ((constraints.maxWidth - _nameW) / 24 - _gap).clamp(
                _cellMinW,
                _cellW,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: _nameW),
                        for (var h = 0; h < 24; h++)
                          Container(
                            width: cellW,
                            margin: const EdgeInsets.only(right: _gap),
                            child: Text(
                              h % 3 == 0 ? '$h' : '',
                              softWrap: false,
                              overflow: TextOverflow.visible,
                              style: small,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (var w = 1; w <= 7; w++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: _gap),
                        child: Row(
                          children: [
                            SizedBox(
                              width: _nameW,
                              child: Text(weekdayShort[w - 1], style: small),
                            ),
                            for (var h = 0; h < 24; h++)
                              Tooltip(
                                key: ValueKey('cal-hour-$w-$h'),
                                message:
                                    '${weekdayShort[w - 1]} $h:00: '
                                    '${grid[weekHour(w, h)] > 0 ? listenedText(grid[weekHour(w, h)]) : 'nothing'}',
                                waitDuration: const Duration(milliseconds: 400),
                                child: Container(
                                  width: cellW,
                                  height: _cellH,
                                  margin: const EdgeInsets.only(right: _gap),
                                  decoration: BoxDecoration(
                                    color: heatColor(
                                      colors,
                                      levels[weekHour(w, h)],
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Less', style: TextStyle(fontSize: 12, color: colors.dim2)),
              const SizedBox(width: 4),
              for (var level = 0; level <= 4; level++) swatch(level),
              const SizedBox(width: 4),
              Text('More', style: TextStyle(fontSize: 12, color: colors.dim2)),
            ],
          ),
        ],
      ),
    );
  }
}
