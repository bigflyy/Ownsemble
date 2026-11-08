import 'package:flutter/material.dart';

import '../library/day_range.dart';
import '../library/listening_stats.dart';
import '../library/play_period.dart';
import '../library/play_stats.dart';
import '../library/track.dart';
import '../library/year_report.dart';
import 'cover_tile.dart';
import 'song_filters.dart';
import 'stat_text.dart';
import 'stats_calendar.dart';
import 'theme.dart';

/// The report of one year (plan 04, D2; board 3 of the D2 canvas, opened
/// from a button on Stats, user 2026-11-08): six tiles, song of the year,
/// top songs and artists, month by month (a month's own facts on click),
/// every day of the year, time of day, songs new to you and songs back
/// after a break.
///
/// Its year arrows are in the place's heading ([YearArrows]); Back returns
/// to Stats.
class YearReportPage extends StatefulWidget {
  const YearReportPage({
    super.key,
    required this.filters,
    required this.songs,
    required this.year,
    required this.onPlay,
    required this.onOpenArtist,
  });

  final SongFilters filters;
  final List<Track> songs;
  final int year;
  final void Function(List<Track> list, int index) onPlay;
  final void Function(String artist) onOpenArtist;

  @override
  State<YearReportPage> createState() => _YearReportPageState();
}

class _YearReportPageState extends State<YearReportPage> {
  /// The month whose facts show under the bars (1-12), if one was clicked.
  int? _month;

  ({int year, int version, YearReport report})? _kept;
  Map<int, Track> _byId = const {};
  List<Track>? _byIdOf;

  Map<int, Track> get byId {
    if (!identical(_byIdOf, widget.songs)) {
      _byId = {for (final track in widget.songs) track.id: track};
      _byIdOf = widget.songs;
    }
    return _byId;
  }

  @override
  void didUpdateWidget(YearReportPage old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year) _month = null;
  }

  YearReport _report() {
    final filters = widget.filters;
    final year = widget.year, version = filters.playsVersion;
    final kept = _kept;
    if (kept != null && kept.year == year && kept.version == version) {
      return kept.report;
    }
    final now = filters.now;
    final compared = comparedRange(
      PlayPeriod.year(offset: year - now.year),
      now,
    );
    final report = YearReport.build(
      year: year,
      now: now,
      firstPlayMs: filters.firstPlayMs,
      plays: filters.playsIn(DayRange.year(year)),
      songs: byId,
      allTime: filters.allTime,
      before: filters.songPlaysIn(
        DayRange(DateTime(1970), DateTime(year - 1, 12, 31)),
      ),
      compared: compared == null
          ? null
          : (range: compared, plays: filters.songPlaysIn(compared)),
    );
    _kept = (year: year, version: version, report: report);
    return report;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final filters = widget.filters;
    if (!filters.loaded) return const SizedBox.shrink();
    final report = _report();
    final year = widget.year;
    final firstMs = filters.firstPlayMs;
    final firstDay = firstMs == null
        ? null
        : DayRange.day(DateTime.fromMillisecondsSinceEpoch(firstMs)).first;
    final since = firstDay == null
        ? null
        : PlayPeriod.rangeLabel(DayRange.day(firstDay));

    final sections = <Widget>[];
    if (report.recordedDays == 0) {
      sections.add(
        _Note(
          key: const ValueKey('year-note'),
          text: since == null
              ? 'Nothing was played yet. Songs you play are counted from now on.'
              : 'Nothing was recorded in $year: plays are counted since '
                    '$since.',
        ),
      );
    } else {
      if (firstDay != null && firstDay.year == year) {
        sections.add(
          _Note(
            key: const ValueKey('year-note'),
            text:
                'Counting since $since, when the app started recording '
                'plays: this report covers ${report.recordedDays} days'
                '${report.partial && year == filters.now.year ? ' so far' : ''}. '
                'VK keeps no listening history, so nothing earlier can be '
                'added.',
          ),
        );
      }
      sections
        ..add(_tiles(report, firstMs))
        ..addAll(_songOfYear(colors, report))
        ..add(_tops(colors, report))
        ..add(_months(colors, report))
        ..add(_everyDay(colors, report, firstDay))
        ..add(_timeOfDay(colors, report))
        ..add(_newAndBack(colors, report));
    }

    return ListView(
      key: const ValueKey('year-report'),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, section) in sections.indexed) ...[
                  if (i > 0) const SizedBox(height: 28),
                  section,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tiles(YearReport report, int? firstMs) {
    final totals = report.totals;
    final before = report.compared?.totals;
    ({String text, bool? up})? change(int value, int? earlier) => changeAgainst(
      value,
      earlier,
      report.compared?.range,
      firstPlayMs: firstMs,
    );
    final run = report.longestRun;
    final tiles = [
      _BigTile(
        key: const ValueKey('year-tile-listened'),
        label: 'Listened',
        value: listenedText(totals.listenedMs),
        note: change(totals.listenedMs, before?.listenedMs),
      ),
      _BigTile(
        key: const ValueKey('year-tile-plays'),
        label: 'Counted plays',
        value: '${totals.plays}',
        note: change(totals.plays, before?.plays),
      ),
      _BigTile(
        key: const ValueKey('year-tile-songs'),
        label: 'Songs',
        value: '${totals.songs}',
        note: change(totals.songs, before?.songs),
      ),
      _BigTile(
        key: const ValueKey('year-tile-artists'),
        label: 'Artists',
        value: '${totals.artists}',
        note: change(totals.artists, before?.artists),
      ),
      _BigTile(
        key: const ValueKey('year-tile-days'),
        label: 'Days with music',
        value: '${report.daysWithMusic}',
        note: (text: 'of ${report.recordedDays} recorded days', up: null),
      ),
      _BigTile(
        key: const ValueKey('year-tile-run'),
        label: 'Longest run',
        value: run.days == 1 ? '1 day' : '${run.days} days',
        note: run.end == null
            ? null
            : (text: 'ending ${_dayMonth(run.end!)}', up: null),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final perRow = width >= 900 ? 6 : (width >= 560 ? 3 : 2);
        const gap = 12.0;
        final tileWidth = (width - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }

  List<Widget> _songOfYear(OwnColors colors, YearReport report) {
    final best = report.songOfYear;
    if (best == null) return const [];
    final topSongs = [
      for (final row in report.stats.top(RankBy.songs)) row.songs.single,
    ];
    final facts = [
      ('${best.plays}', ' counted plays'),
      (listenedText(best.listenedMs), ' listened'),
      ('most in ', monthFull[best.topMonth - 1]),
      (
        'first this year ',
        _dayMonth(DateTime.fromMillisecondsSinceEpoch(best.firstMs)),
      ),
    ];
    return [
      Container(
        key: const ValueKey('year-song'),
        padding: const EdgeInsets.all(20),
        decoration: _box(colors, radius: 16),
        child: Row(
          children: [
            TrackTile(track: best.track, size: 120, radius: 14, biggest: true),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SONG OF THE YEAR',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    best.track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    best.track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: colors.dim),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 18,
                    runSpacing: 4,
                    children: [
                      for (final (a, b) in facts)
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: a,
                                style: a.startsWith(RegExp('[0-9<]'))
                                    ? TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: colors.text,
                                      )
                                    : null,
                              ),
                              TextSpan(
                                text: b,
                                style: a.startsWith(RegExp('[0-9<]'))
                                    ? null
                                    : TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: colors.text,
                                      ),
                              ),
                            ],
                          ),
                          style: TextStyle(fontSize: 13, color: colors.dim),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('year-play-song'),
              onPressed: () => widget.onPlay(topSongs, 0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play'),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _tops(OwnColors colors, YearReport report) {
    final songs = report.stats.top(RankBy.songs, limit: 5);
    final artists = report.stats.top(RankBy.artists, limit: 5);
    final playList = [for (final row in songs) row.songs.single];
    return _TwoColumns(
      left: _Section(
        title: 'Top songs',
        sub: 'By counted plays',
        child: _ListBox(
          rows: [
            for (final (i, row) in songs.indexed)
              _ListRow(
                key: ValueKey('year-song-$i'),
                rank: '${i + 1}',
                track: row.songs.first,
                title: row.name,
                sub: row.detail ?? '',
                right: row.plays == 1 ? '1 play' : '${row.plays} plays',
                onTap: () => widget.onPlay(playList, i),
              ),
          ],
          empty: 'No song counted yet.',
        ),
      ),
      right: _Section(
        title: 'Top artists',
        sub: 'By counted plays, with the time heard',
        child: _ListBox(
          rows: [
            for (final (i, row) in artists.indexed)
              _ListRow(
                key: ValueKey('year-artist-$i'),
                rank: '${i + 1}',
                track: row.songs.first,
                title: row.name,
                sub:
                    '${row.songs.length == 1 ? '1 song' : '${row.songs.length} songs'}'
                    ', ${listenedText(row.listenedMs)}',
                right: row.plays == 1 ? '1 play' : '${row.plays} plays',
                onTap: () => widget.onOpenArtist(row.name),
              ),
          ],
          empty: 'No artist counted yet.',
        ),
      ),
    );
  }

  Widget _months(OwnColors colors, YearReport report) {
    final most = report.monthHeard.fold(1, (a, b) => b > a ? b : a);
    final month = _month;
    final facts = month == null ? null : report.month(month);
    return _Section(
      title: 'Month by month',
      sub: 'Time listened. Click a month for its own top song and busiest day.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 200,
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
            decoration: _box(colors),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var m = 1; m <= 12; m++)
                  Expanded(
                    child: _MonthBar(
                      key: ValueKey('year-month-$m'),
                      name: monthShort[m - 1],
                      heardMs: report.monthHeard[m - 1],
                      share: report.monthHeard[m - 1] / most,
                      chosen: month == m,
                      tooltip:
                          '${monthFull[m - 1]} ${widget.year}: '
                          '${listenedText(report.monthHeard[m - 1])}',
                      onTap: () =>
                          setState(() => _month = month == m ? null : m),
                    ),
                  ),
              ],
            ),
          ),
          if (month != null && facts != null) ...[
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final perRow = width >= 760 ? 4 : 2;
                const gap = 12.0;
                final tileWidth = (width - gap * (perRow - 1)) / perRow;
                final tiles = [
                  _BigTile(
                    label: monthFull[month - 1],
                    value: listenedText(facts.heardMs),
                    small: true,
                    note: (
                      text: facts.plays == 1
                          ? '1 counted play'
                          : '${facts.plays} counted plays',
                      up: null,
                    ),
                  ),
                  _BigTile(
                    label: 'Top song',
                    value: facts.topSong?.name ?? '-',
                    small: true,
                    note: facts.topSong == null
                        ? null
                        : (
                            text:
                                '${facts.topSong!.detail}, '
                                '${facts.topSong!.plays} plays',
                            up: null,
                          ),
                  ),
                  _BigTile(
                    label: 'Top artist',
                    value: facts.topArtist?.name ?? '-',
                    small: true,
                    note: facts.topArtist == null
                        ? null
                        : (text: '${facts.topArtist!.plays} plays', up: null),
                  ),
                  _BigTile(
                    label: 'Busiest day',
                    value: facts.busiestDay == null
                        ? '-'
                        : _dayMonth(facts.busiestDay!.day),
                    small: true,
                    note: facts.busiestDay == null
                        ? null
                        : (
                            text: listenedText(facts.busiestDay!.heardMs),
                            up: null,
                          ),
                  ),
                ];
                return Wrap(
                  key: const ValueKey('year-month-facts'),
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final tile in tiles)
                      SizedBox(width: tileWidth, child: tile),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _everyDay(OwnColors colors, YearReport report, DateTime? firstDay) {
    final now = widget.filters.now;
    final today = DateTime(now.year, now.month, now.day);
    final days = DayRange.year(widget.year).days;
    final levels = heatLevels(report.dayHeard);
    final busiest = report.busiestDay;
    final lead = days.first.weekday - 1;
    const cell = 11.0, gap = 3.0;
    final weeks = ((lead + days.length) / 7).ceil();
    final run = report.longestRun;
    final facts = [
      (
        'Busiest day ',
        busiest == null
            ? '-'
            : '${calendarDayText(busiest.day, year: false)}, '
                  '${listenedText(busiest.heardMs)}',
      ),
      (
        'Longest run ',
        run.days == 0
            ? '-'
            : '${run.days == 1 ? '1 day' : '${run.days} days'}'
                  '${run.end == null ? '' : ', to ${_dayMonth(run.end!)}'}',
      ),
      ('Days with music ', '${report.daysWithMusic} of ${report.recordedDays}'),
    ];
    return _Section(
      title: 'Every day',
      sub: 'One square per day; the outlined one is your busiest day',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(colors),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: weeks * (cell + gap),
                height: 7 * (cell + gap),
                child: Stack(
                  children: [
                    for (final (i, day) in days.indexed)
                      Positioned(
                        left: ((lead + i) ~/ 7) * (cell + gap),
                        top: ((lead + i) % 7) * (cell + gap),
                        child: Tooltip(
                          message:
                              '${calendarDayText(day)}: '
                              '${report.dayHeard[i] > 0 ? listenedText(report.dayHeard[i]) : 'nothing'}',
                          waitDuration: const Duration(milliseconds: 400),
                          child: _StripCell(
                            size: cell,
                            color: heatColor(colors, levels[i]),
                            future: day.isAfter(today),
                            before: firstDay == null || day.isBefore(firstDay),
                            ring: busiest != null && busiest.day == day
                                ? colors.accent
                                : null,
                            hatch: colors.text.withValues(alpha: 0.12),
                            line: colors.line,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 6,
            children: [
              for (final (label, value) in facts)
                Text.rich(
                  TextSpan(
                    text: label,
                    children: [
                      TextSpan(
                        text: value,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: colors.text,
                        ),
                      ),
                    ],
                  ),
                  style: TextStyle(fontSize: 13, color: colors.dim),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeOfDay(OwnColors colors, YearReport report) {
    final parts = report.dayParts;
    const names = [
      'Morning, 5-12',
      'Afternoon, 12-17',
      'Evening, 17-22',
      'Night, 22-5',
    ];
    return _Section(
      title: 'Time of day',
      sub:
          'When your listening happened; most of all around '
          '${report.peakHour}:00',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final perRow = width >= 700 ? 4 : 2;
          const gap = 12.0;
          final tileWidth = (width - gap * (perRow - 1)) / perRow;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final (i, name) in names.indexed)
                Container(
                  key: ValueKey('year-part-$i'),
                  width: tileWidth,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: _box(colors),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(fontSize: 13, color: colors.dim),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${parts[i]}%',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: parts[i] / 100,
                          minHeight: 6,
                          color: colors.accent,
                          backgroundColor: colors.hover,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _newAndBack(OwnColors colors, YearReport report) {
    final fresh = report.newToYou.take(5).toList();
    final back = report.backAfterBreak.take(5).toList();
    return _TwoColumns(
      left: _Section(
        title: 'New to you',
        sub: 'First played this year',
        child: _ListBox(
          rows: [
            for (final (i, song) in fresh.indexed)
              _ListRow(
                key: ValueKey('year-new-$i'),
                track: song.track,
                title: song.track.title,
                sub:
                    '${song.track.artist}, first on '
                    '${_dayMonth(DateTime.fromMillisecondsSinceEpoch(song.firstMs))}',
                right: song.plays == 1 ? '1 play' : '${song.plays} plays',
                onTap: () => widget.onPlay([for (final s in fresh) s.track], i),
              ),
          ],
          empty: report.newKnown
              ? 'Every song you played this year was played before.'
              : 'Plays were first recorded this year, so every song would '
                    'look new.',
        ),
      ),
      right: _Section(
        title: 'Back after a break',
        sub: 'Songs that went quiet for 2 months or more, then came back',
        child: _ListBox(
          rows: [
            for (final (i, song) in back.indexed)
              _ListRow(
                key: ValueKey('year-back-$i'),
                track: song.track,
                title: song.track.title,
                sub:
                    '${song.track.artist}, back on '
                    '${_dayMonth(DateTime.fromMillisecondsSinceEpoch(song.backMs))}',
                right: 'after ${_breakText(song.gapDays)}',
                onTap: () => widget.onPlay([for (final s in back) s.track], i),
              ),
          ],
          empty: 'No song took a break this long.',
        ),
      ),
    );
  }
}

/// "5 Jan".
String _dayMonth(DateTime day) => '${day.day} ${monthShort[day.month - 1]}';

/// A break's length: "2 months", "1 year 3 months".
String _breakText(int days) {
  final months = (days / 30.44).round();
  if (months < 12) return '$months months';
  final years = months ~/ 12, rest = months % 12;
  final y = years == 1 ? '1 year' : '$years years';
  return rest == 0 ? y : '$y ${rest == 1 ? '1 month' : '$rest months'}';
}

BoxDecoration _box(OwnColors colors, {double radius = 12}) => BoxDecoration(
  color: colors.surface,
  border: Border.all(color: colors.line),
  borderRadius: BorderRadius.circular(radius),
);

/// The year arrows of the report's heading: earlier and later year, the
/// later one off at this year, the earlier one off before the first play.
class YearArrows extends StatelessWidget {
  const YearArrows({
    super.key,
    required this.year,
    required this.firstYear,
    required this.thisYear,
    required this.onYear,
  });

  final int year;
  final int? firstYear;
  final int thisYear;
  final void Function(int year) onYear;

  @override
  Widget build(BuildContext context) {
    final earlier = firstYear != null && year > firstYear!;
    final later = year < thisYear;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('year-earlier'),
          tooltip: 'Earlier year',
          onPressed: earlier ? () => onYear(year - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '$year',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          key: const ValueKey('year-later'),
          tooltip: 'Later year',
          onPressed: later ? () => onYear(year + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// A box of text that explains what the report covers.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: colors.accentBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: const TextStyle(fontSize: 14)),
    );
  }
}

/// A section: its heading, a line under it, then its content.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.sub, required this.child});

  final String title;
  final String sub;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(sub, style: TextStyle(fontSize: 13, color: colors.dim2)),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

/// Two sections side by side, or one above the other in a narrow window.
class _TwoColumns extends StatelessWidget {
  const _TwoColumns({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 700
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 20),
              Expanded(child: right),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left, const SizedBox(height: 28), right],
          ),
  );
}

/// A tile: what it counts, the number, a line under it.
class _BigTile extends StatelessWidget {
  const _BigTile({
    super.key,
    required this.label,
    required this.value,
    required this.note,
    this.small = false,
  });

  final String label;
  final String value;
  final ({String text, bool? up})? note;

  /// A smaller number that may be a name (a month's facts).
  final bool small;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final note = this.note;
    final number = Text(
      value,
      maxLines: 1,
      overflow: small ? TextOverflow.ellipsis : TextOverflow.visible,
      softWrap: !small ? false : null,
      style: TextStyle(
        fontSize: small ? 17 : 24,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    // At least the height of a tile with a note of two lines, so a row of
    // tiles lines up; a larger font still grows it.
    return Container(
      constraints: BoxConstraints(minHeight: small ? 0 : 116),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: _box(colors),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.dim),
          ),
          const SizedBox(height: 4),
          // A name is cut; a number shrinks to fit ("16 h 52 min").
          if (small)
            number
          else
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: number,
            ),
          const SizedBox(height: 2),
          Text(
            note?.text ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: note?.up == true ? colors.source3 : colors.dim2,
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of up to five rows in a box, or a line when it is empty.
class _ListBox extends StatelessWidget {
  const _ListBox({required this.rows, required this.empty});

  final List<Widget> rows;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: _box(colors),
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Text(empty, style: TextStyle(color: colors.dim2)),
            )
          : Column(children: rows),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    super.key,
    this.rank,
    required this.track,
    required this.title,
    required this.sub,
    required this.right,
    required this.onTap,
  });

  final String? rank;
  final Track track;
  final String title;
  final String sub;
  final String right;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      hoverColor: colors.hover,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              if (rank != null)
                SizedBox(
                  width: 22,
                  child: Text(
                    rank!,
                    style: TextStyle(fontSize: 13, color: colors.dim2),
                  ),
                ),
              TrackTile(track: track, size: 36, radius: 7),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.dim),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(right, style: TextStyle(fontSize: 13, color: colors.dim)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One month's bar: its time heard above, the bar, its name below.
class _MonthBar extends StatelessWidget {
  const _MonthBar({
    super.key,
    required this.name,
    required this.heardMs,
    required this.share,
    required this.chosen,
    required this.tooltip,
    required this.onTap,
  });

  final String name;
  final int heardMs;
  final double share;
  final bool chosen;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: colors.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                heardMs > 0 ? shortListenedText(heardMs) : '',
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: TextStyle(fontSize: 11, color: colors.dim),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: heardMs > 0 ? share.clamp(0.03, 1.0) : 0,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 40),
                      decoration: BoxDecoration(
                        color: chosen
                            ? colors.accent
                            : colors.source3.withValues(alpha: 0.75),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6),
                          bottom: Radius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  color: chosen ? colors.text : colors.dim,
                  fontWeight: chosen ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One day of the every-day strip.
class _StripCell extends StatelessWidget {
  const _StripCell({
    required this.size,
    required this.color,
    required this.future,
    required this.before,
    required this.ring,
    required this.hatch,
    required this.line,
  });

  final double size;
  final Color color;
  final bool future;
  final bool before;
  final Color? ring;
  final Color hatch;
  final Color line;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: future || before ? null : color,
      border: future
          ? Border.all(color: line)
          : before
          ? Border.all(color: hatch)
          : null,
      borderRadius: BorderRadius.circular(2),
    ),
    foregroundDecoration: ring == null
        ? null
        : BoxDecoration(
            border: Border.all(color: ring!, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
  );
}
