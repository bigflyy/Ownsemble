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
                    Flexible(
                      child: Text(
                        _rangeText,
                        key: const ValueKey('picker-range'),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _hint,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: colors.dim2),
                      ),
                    ),
                    const Spacer(),
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

/// One month tile or day: chosen ends filled, days between marked (filled,
/// or with violet lines above and below when listening shows as color),
/// and the listening as a line at the bottom or a green tint.
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
    final tint = mode == CalendarListening.color && heardMs > 0 && !isEnd;
    final Color background = isEnd
        ? colors.accent
        : inside && mode != CalendarListening.color
        ? colors.accentBg
        : tint
        ? colors.source3.withValues(alpha: 0.12 + 0.5 * fraction)
        : Colors.transparent;
    final textColor = isEnd
        ? colors.onAccent
        : inside
        ? colors.accent
        : colors.text;
    final lines = inside && mode == CalendarListening.color;
    final heard = heardMs == 0
        ? 'nothing played'
        : '${_hoursText(heardMs, always: true)} listened';
    return Tooltip(
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
              borderRadius: BorderRadius.circular(lines ? 0 : 8),
              side: isEnd || inside || tint
                  ? BorderSide.none
                  : BorderSide(color: colors.line),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: future ? null : onTap,
              child: Container(
                decoration: lines
                    ? BoxDecoration(
                        border: Border.symmetric(
                          horizontal: BorderSide(
                            color: colors.accent,
                            width: 2,
                          ),
                        ),
                      )
                    : null,
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
  }
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
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
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
