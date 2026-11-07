import 'package:flutter/material.dart';

import '../library/day_range.dart';
import '../library/play_period.dart';
import 'anchored_panel.dart';
import 'shell_settings.dart';
import 'theme.dart';

const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

/// A day's line is full at this much listening.
const _fullDayMs = 2 * 60 * 60 * 1000;

/// Opens the Custom period panel (plan 04, C2: variant 2) under [anchor]:
/// month tiles of one year, each with the hours heard; click the first
/// month, then the last. "Exact days" turns it into one month of days.
/// Resolves to the chosen days, or null when closed without Apply.
Future<DayRange?> pickDays(
  BuildContext anchor, {
  required DayRange? initial,
  required List<int> Function(List<DayRange> ranges) listenedIn,
  required ShellSettings settings,
  DateTime Function() clock = DateTime.now,
  bool alignRight = true,
}) => showAnchoredPanel<DayRange>(
  anchor,
  width: 480,
  alignRight: alignRight,
  builder: (context) => PeriodPicker(
    initial: initial,
    listenedIn: listenedIn,
    settings: settings,
    clock: clock,
    onApply: (range) => Navigator.of(context).pop(range),
    onCancel: () => Navigator.of(context).pop(),
  ),
);

/// The Custom period panel; see [pickDays].
class PeriodPicker extends StatefulWidget {
  const PeriodPicker({
    super.key,
    required this.initial,
    required this.listenedIn,
    required this.settings,
    required this.onApply,
    required this.onCancel,
    this.clock = DateTime.now,
  });

  final DayRange? initial;
  final List<int> Function(List<DayRange> ranges) listenedIn;
  final ShellSettings settings;
  final ValueChanged<DayRange> onApply;
  final VoidCallback onCancel;
  final DateTime Function() clock;

  @override
  State<PeriodPicker> createState() => _PeriodPickerState();
}

class _PeriodPickerState extends State<PeriodPicker> {
  late final DateTime _today;

  /// The chosen days; while [_pending], only its first end is chosen.
  late DayRange _range;
  bool _pending = false;

  /// Days instead of month tiles.
  bool _exact = false;

  /// The year of the tiles, and the month of the days, on screen.
  late int _year;
  late DateTime _month;

  /// Heard ms per tile or day on screen, by the first day.
  final _heard = <DateTime, int>{};

  @override
  void initState() {
    super.initState();
    final now = widget.clock();
    _today = DateTime(now.year, now.month, now.day);
    _range = widget.initial ?? DayRange.month(now.year, now.month);
    // A range that is not whole months opens on its days.
    final a = _range.first, b = _range.last;
    _exact = a.day != 1 || DateTime(b.year, b.month, b.day + 1).day != 1;
    _year = a.year;
    _month = DateTime(a.year, a.month);
    _readHeard();
  }

  void _readHeard() {
    final ranges = _exact
        ? [
            for (
              var d = 1;
              d <= DateTime(_month.year, _month.month + 1, 0).day;
              d++
            )
              DayRange.day(DateTime(_month.year, _month.month, d)),
          ]
        : [for (var m = 1; m <= 12; m++) DayRange.month(_year, m)];
    final ms = widget.listenedIn(ranges);
    _heard.clear();
    for (var i = 0; i < ranges.length; i++) {
      _heard[ranges[i].first] = ms[i];
    }
  }

  void _pick(DayRange unit) {
    setState(() {
      if (_pending) {
        _range = DayRange(
          _range.first.isBefore(unit.first) ? _range.first : unit.first,
          _range.last.isAfter(unit.last) ? _range.last : unit.last,
        );
        _pending = false;
      } else {
        _range = unit;
        _pending = true;
      }
    });
  }

  void _toggleExact() {
    setState(() {
      _pending = false;
      if (_exact) {
        // Back to months: the months the days touch.
        _range = DayRange(
          DateTime(_range.first.year, _range.first.month),
          DateTime(_range.last.year, _range.last.month + 1, 0),
        );
        _year = _range.first.year;
      } else {
        _month = DateTime(_range.first.year, _range.first.month);
      }
      _exact = !_exact;
      _readHeard();
    });
  }

  void _moveView(int by) {
    setState(() {
      if (_exact) {
        _month = DateTime(_month.year, _month.month + by);
      } else {
        _year += by;
      }
      _readHeard();
    });
  }

  bool get _canMoveForward => _exact
      ? !DateTime(_month.year, _month.month + 1).isAfter(_today)
      : _year < _today.year;

  /// The end of the range shown in the footer: the range, or its first end
  /// while the last is not chosen.
  String get _rangeText => _pending
      ? 'From ${_exact ? '${_range.first.day} ' : ''}'
            '${_monthFull[_range.first.month - 1]} ${_range.first.year}'
      : PlayPeriod.rangeLabel(_range);

  String get _hint {
    if (_pending) {
      return _exact ? 'now click the last day' : 'now click the last month';
    }
    if (_exact) {
      final n = _range.dayCount;
      return n == 1 ? '1 day' : '$n days';
    }
    final total = widget.listenedIn([_range]).first;
    return '${_hoursText(total, always: true)} listened';
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final mode = widget.settings.calendarListening;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('picker-back'),
                    tooltip: _exact ? 'Earlier month' : 'Earlier year',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _moveView(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      _exact
                          ? '${_monthFull[_month.month - 1]} ${_month.year}'
                          : '$_year',
                      key: const ValueKey('picker-title'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('picker-next'),
                    tooltip: _exact ? 'Later month' : 'Later year',
                    visualDensity: VisualDensity.compact,
                    onPressed: _canMoveForward ? () => _moveView(1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_exact) _days(colors, mode) else _months(colors, mode),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Listening in calendars',
                    style: TextStyle(fontSize: 12, color: colors.dim2),
                  ),
                  _ModeSwitch(settings: widget.settings),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _rangeText,
                            key: const ValueKey('picker-range'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: colors.dim2),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      key: const ValueKey('picker-exact'),
                      onPressed: _toggleExact,
                      child: Text(_exact ? 'Months' : 'Exact days'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('picker-apply'),
                      onPressed: () => widget.onApply(_range),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _months(OwnColors colors, CalendarListening mode) {
    final most = [for (var m = 1; m <= 12; m++) _heard[DateTime(_year, m)] ?? 0]
        .fold(0, (a, b) => a > b ? a : b);
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 98 / 50,
      clipBehavior: Clip.none,
      children: [
        for (var m = 1; m <= 12; m++)
          _Cell(
            key: ValueKey('month-$_year-$m'),
            label: '${_monthFull[m - 1]} $_year',
            unit: DayRange.month(_year, m),
            range: _range,
            pending: _pending,
            future: DateTime(_year, m).isAfter(_today),
            heardMs: _heard[DateTime(_year, m)] ?? 0,
            fraction: most == 0 ? 0 : (_heard[DateTime(_year, m)] ?? 0) / most,
            mode: mode,
            column: (m - 1) % 4,
            columns: 4,
            firstInGrid: m == 1,
            lastInGrid: m == 12,
            gap: 8,
            onTap: () => _pick(DayRange.month(_year, m)),
            child: (color) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _monthShort[m - 1],
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ),
                    if (mode != CalendarListening.off)
                      Text(
                        _hoursText(_heard[DateTime(_year, m)] ?? 0),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11,
                          color: color.withValues(alpha: 0.8),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _days(OwnColors colors, CalendarListening mode) {
    final first = _month;
    final lead = first.weekday - 1;
    final count = DateTime(first.year, first.month + 1, 0).day;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final name in _weekdays)
              Expanded(
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: colors.dim2),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.45,
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var d = 1; d <= count; d++)
              _Cell(
                key: ValueKey('day-${first.year}-${first.month}-$d'),
                label: '$d ${_monthFull[first.month - 1]} ${first.year}',
                unit: DayRange.day(DateTime(first.year, first.month, d)),
                range: _range,
                pending: _pending,
                future: DateTime(first.year, first.month, d).isAfter(_today),
                heardMs: _heard[DateTime(first.year, first.month, d)] ?? 0,
                fraction:
                    ((_heard[DateTime(first.year, first.month, d)] ?? 0) /
                            _fullDayMs)
                        .clamp(0, 1),
                mode: mode,
                column: (lead + d - 1) % 7,
                columns: 7,
                firstInGrid: d == 1,
                lastInGrid: d == count,
                gap: 4,
                onTap: () =>
                    _pick(DayRange.day(DateTime(first.year, first.month, d))),
                child: (color) => Center(
                  child: Text(
                    '$d',
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One month tile or day, and the listening as a line at the bottom or a
/// green tint. With Line or Off the chosen ends are filled violet and the
/// tiles between light violet. With Color the tint must stay visible, so the
/// ends get a violet ring and one violet outline goes around the range, one
/// box per grid row (user's pick, 2026-11-08).
class _Cell extends StatelessWidget {
  const _Cell({
    super.key,
    required this.label,
    required this.unit,
    required this.range,
    required this.pending,
    required this.future,
    required this.heardMs,
    required this.fraction,
    required this.mode,
    required this.column,
    required this.columns,
    required this.firstInGrid,
    required this.lastInGrid,
    required this.gap,
    required this.onTap,
    required this.child,
  });

  final String label;
  final DayRange unit;
  final DayRange range;
  final bool pending;
  final bool future;
  final int heardMs;

  /// How full the line or tint is, 0 to 1.
  final double fraction;
  final CalendarListening mode;

  /// The tile's column in its grid, the number of columns and the space
  /// between tiles: where the range outline breaks to the next row.
  final int column;
  final int columns;

  /// The first or last tile shown: a range that goes on into another month
  /// or year still closes its box here.
  final bool firstInGrid;
  final bool lastInGrid;
  final double gap;
  final VoidCallback onTap;
  final Widget Function(Color textColor) child;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final isEnd = pending
        ? unit.first == range.first
        : unit.first == range.first || unit.last == range.last;
    final inside =
        !pending &&
        !isEnd &&
        !unit.first.isBefore(range.first) &&
        !unit.last.isAfter(range.last);
    final color = mode == CalendarListening.color;
    final filled = isEnd && !color;
    final ring = isEnd && color;
    final tint = color && heardMs > 0;
    final Color background = filled
        ? colors.accent
        : inside && !color
        ? colors.accentBg
        : tint
        ? colors.source3.withValues(alpha: 0.06 + 0.34 * fraction)
        : Colors.transparent;
    final textColor = filled
        ? colors.onAccent
        : inside && !color
        ? colors.accent
        : colors.text;
    final outlined = color && !pending && (isEnd || inside);
    final BorderSide side = ring
        ? BorderSide(color: colors.accent, width: 2)
        : filled || (inside && !color) || tint
        ? BorderSide.none
        : BorderSide(color: colors.line);
    final heard = heardMs == 0
        ? 'nothing played'
        : '${_hoursText(heardMs, always: true)} listened';
    final tile = Tooltip(
      message: future ? label : '$label: $heard',
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        selected: isEnd || inside,
        label: label,
        child: Opacity(
          opacity: future ? 0.4 : 1,
          child: Material(
            color: background,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: side,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: future ? null : onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Stack(
                  children: [
                    Positioned.fill(child: child(textColor)),
                    if (mode == CalendarListening.line && heardMs > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: (0.08 + 0.92 * fraction).clamp(0, 1),
                            child: Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: textColor.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!outlined) return tile;
    return CustomPaint(
      foregroundPainter: RangeOutline(
        color: colors.accent,
        gap: gap,
        opensLeft: unit.first != range.first && column > 0 && !firstInGrid,
        opensRight:
            unit.last != range.last && column < columns - 1 && !lastInGrid,
      ),
      child: tile,
    );
  }
}

/// This tile's part of the outline around a chosen range. Tiles in a row
/// draw one box together: a side that [opensLeft] or [opensRight] runs on
/// to the middle of the gap, where the neighbour's part takes over; a
/// closed side gets the rounded end of the box, a little outside the tile.
class RangeOutline extends CustomPainter {
  RangeOutline({
    required this.color,
    required this.gap,
    required this.opensLeft,
    required this.opensRight,
  });

  final Color color;
  final double gap;
  final bool opensLeft;
  final bool opensRight;

  @override
  void paint(Canvas canvas, Size size) {
    // How far the box stands out from the tile: under half the gap, so the
    // boxes of two rows never touch.
    final out = gap / 2 - 1;
    final half = gap / 2;
    final left = opensLeft ? -half : -out;
    final right = opensRight ? size.width + half : size.width + out;
    canvas
      ..save()
      ..clipRect(
        Rect.fromLTRB(left - 1, -out - 2, right + 1, size.height + out + 2),
      )
      ..drawRRect(
        RRect.fromLTRBR(
          // An open side reaches past the clip, so only its top and bottom
          // lines show.
          opensLeft ? left - 20 : left,
          -out,
          opensRight ? right + 20 : right,
          size.height + out,
          const Radius.circular(10),
        ),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(RangeOutline old) =>
      old.color != color ||
      old.gap != gap ||
      old.opensLeft != opensLeft ||
      old.opensRight != opensRight;
}

/// Line, Color or Off, for every calendar.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.settings});

  final ShellSettings settings;

  @override
  Widget build(BuildContext context) => SegmentedButton<CalendarListening>(
    key: const ValueKey('calendar-listening'),
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 12, fontFamily: appFontFamily),
      ),
    ),
    segments: const [
      ButtonSegment(value: CalendarListening.line, label: Text('Line')),
      ButtonSegment(value: CalendarListening.color, label: Text('Color')),
      ButtonSegment(value: CalendarListening.off, label: Text('Off')),
    ],
    selected: {settings.calendarListening},
    onSelectionChanged: (value) => settings.setCalendarListening(value.single),
  );
}

/// "18 h", "45 min", or nothing for no listening ([always]: "0 min").
String _hoursText(int ms, {bool always = false}) {
  if (ms <= 0) return always ? '0 min' : '';
  final minutes = (ms / 60000).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes / 60;
  return hours >= 10 ? '${hours.round()} h' : '${hours.toStringAsFixed(1)} h';
}
