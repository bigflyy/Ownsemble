import 'package:flutter/material.dart';

import '../library/day_range.dart';
import '../library/listening_stats.dart';
import '../library/track.dart';
import 'cover_tile.dart';
import 'song_filters.dart';
import 'stat_text.dart';
import 'stats_calendar.dart';
import 'theme.dart';

/// The Stats place (plan 04, D1, mockup A picked in B3): four tiles for the
/// page's period (time heard, counted plays, songs and artists played), each
/// compared with the same days of the period before, then a top list with
/// tabs Songs / Artists / Albums.
///
/// The period is the Songs page's own ([SongFilters.period]), so the arrows
/// and Week / Month / Year / All time / Custom above work the same on both.
/// A song row plays the top songs from that one; an artist row opens Songs
/// with that artist's chip, sorted by plays; an album row opens the album.
class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    required this.filters,
    required this.songs,
    required this.onPlay,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    this.onOpenYear,
  });

  final SongFilters filters;

  /// The library's songs, to name the played ones.
  final List<Track> songs;

  /// A top song was clicked: play [list] from [index].
  final void Function(List<Track> list, int index) onPlay;
  final void Function(String artist) onOpenArtist;

  /// An album row was clicked: open the album of its most played song.
  final void Function(Track track) onOpenAlbum;

  /// The banner's button was clicked: open the report of [year] (plan 04,
  /// D2). Without it there is no banner.
  final void Function(int year)? onOpenYear;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  RankBy _tab = RankBy.songs;

  /// Whether the Calendar tab is shown instead of a top list (plan 04, D2).
  bool _calendar = false;

  /// Songs by id, made again only when the library's list is another one.
  Map<int, Track> _byId = const {};
  List<Track>? _byIdOf;

  /// The banner's year and its plays, read again when plays change.
  ({int year, int version, ListeningStats stats})? _yearKept;

  /// Plays of [year] for the banner: the page's own when the period is
  /// that year, else read once per year and plays version.
  ListeningStats _yearStats(int year, ListeningStats page, DayRange? range) {
    if (range == DayRange.year(year)) return page;
    final filters = widget.filters, version = filters.playsVersion;
    final kept = _yearKept;
    if (kept != null && kept.year == year && kept.version == version) {
      return kept.stats;
    }
    final stats = ListeningStats(
      byId,
      filters.songPlaysIn(DayRange.year(year)),
    );
    _yearKept = (year: year, version: version, stats: stats);
    return stats;
  }

  /// Below this width the tiles go two by two and the bars are left out.
  static const _narrowWidth = 760.0;

  Map<int, Track> get byId {
    if (!identical(_byIdOf, widget.songs)) {
      _byId = {for (final track in widget.songs) track.id: track};
      _byIdOf = widget.songs;
    }
    return _byId;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final filters = widget.filters;
    if (!filters.loaded) return const SizedBox.shrink();
    final now = filters.now;
    final stats = ListeningStats(byId, filters.inPeriod);
    final compared = filters.compared();
    final before = compared == null
        ? null
        : ListeningStats(byId, compared.plays).totals;
    final first = filters.firstPlayMs;
    final totals = stats.totals;
    ({String text, bool? up})? change(int value, int? earlier) =>
        changeAgainst(value, earlier, compared?.range, firstPlayMs: first);

    final tiles = [
      _Tile(
        key: const ValueKey('stats-tile-listened'),
        label: 'Listened',
        value: listenedText(totals.listenedMs),
        change: change(totals.listenedMs, before?.listenedMs),
      ),
      _Tile(
        key: const ValueKey('stats-tile-plays'),
        label: 'Counted plays',
        value: '${totals.plays}',
        change: change(totals.plays, before?.plays),
      ),
      _Tile(
        key: const ValueKey('stats-tile-songs'),
        label: 'Songs played',
        value: '${totals.songs}',
        change: change(totals.songs, before?.songs),
      ),
      _Tile(
        key: const ValueKey('stats-tile-artists'),
        label: 'Artists played',
        value: '${totals.artists}',
        change: change(totals.artists, before?.artists),
      ),
    ];
    final rows = stats.top(_tab);
    final topPlays = rows.isEmpty ? 1 : rows.first.plays;

    // The year report's banner: the year of the period's last day.
    final periodRange = filters.period.rangeAt(now);
    final year = (periodRange?.last ?? now).year;
    final openYear = widget.onOpenYear;
    final yearStats = openYear == null
        ? null
        : _yearStats(year, stats, periodRange);
    final banner = yearStats == null || yearStats.totals.listenedMs == 0
        ? null
        : _YearBanner(
            key: const ValueKey('stats-year-banner'),
            title: year == now.year
                ? 'Your $year so far'
                : 'Your $year in review',
            line: [
              '${listenedText(yearStats.totals.listenedMs)} listened',
              if (yearStats.top(RankBy.songs, limit: 1).firstOrNull
                  case final best?)
                'song of the year: ${best.name} (${best.detail})',
            ].join(', '),
            onOpen: () => openYear!(year),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowWidth;
        final head = <Widget>[
          if (banner != null)
            Padding(padding: const EdgeInsets.only(bottom: 14), child: banner),
          if (narrow)
            Column(
              children: [
                Row(children: [tiles[0], const SizedBox(width: 12), tiles[1]]),
                const SizedBox(height: 12),
                Row(children: [tiles[2], const SizedBox(width: 12), tiles[3]]),
              ],
            )
          else
            Row(
              children: [
                for (final (i, tile) in tiles.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  tile,
                ],
              ],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
            child: Text(
              'A play counts once you have heard half the song or 4 minutes. '
              'Listened is all time heard, skips included.',
              style: TextStyle(fontSize: 12, color: colors.dim2),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.line)),
            ),
            child: Row(
              children: [
                for (final (by, label) in const [
                  (RankBy.songs, 'Songs'),
                  (RankBy.artists, 'Artists'),
                  (RankBy.albums, 'Albums'),
                ])
                  _TabButton(
                    key: ValueKey('stats-tab-${by.name}'),
                    label: label,
                    selected: !_calendar && _tab == by,
                    onTap: () => setState(() {
                      _tab = by;
                      _calendar = false;
                    }),
                  ),
                _TabButton(
                  key: const ValueKey('stats-tab-calendar'),
                  label: 'Calendar',
                  selected: _calendar,
                  onTap: () => setState(() => _calendar = true),
                ),
              ],
            ),
          ),
          if (_calendar)
            StatsCalendar(filters: filters, byId: byId, onPlay: widget.onPlay),
          if (!_calendar && rows.isNotEmpty)
            _RankRow.header(
              colors,
              first: switch (_tab) {
                RankBy.songs => 'Song',
                RankBy.artists => 'Artist',
                RankBy.albums => 'Album',
              },
              bars: !narrow,
            ),
        ];
        return ListView.builder(
          key: const ValueKey('stats-page'),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          itemCount:
              head.length +
              (_calendar
                  ? 0
                  : rows.isEmpty
                  ? 1
                  : rows.length),
          itemBuilder: (context, index) {
            if (index < head.length) return head[index];
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 32,
                  horizontal: 8,
                ),
                child: Text(
                  'Nothing played in ${filters.period.label(now)}.',
                  style: TextStyle(color: colors.dim),
                ),
              );
            }
            final n = index - head.length;
            final row = rows[n];
            return _RankRow(
              key: ValueKey('stats-row-$n'),
              rank: n + 1,
              row: row,
              share: row.plays / topPlays,
              bars: !narrow,
              onTap: () => switch (_tab) {
                RankBy.songs => widget.onPlay([
                  for (final r in rows) r.songs.single,
                ], n),
                RankBy.artists => widget.onOpenArtist(row.name),
                RankBy.albums => widget.onOpenAlbum(row.songs.first),
              },
              tooltip: switch (_tab) {
                RankBy.songs => 'Play the top songs from this one',
                RankBy.artists => 'Open the songs of ${row.name}',
                RankBy.albums => 'Open the album',
              },
            );
          },
        );
      },
    );
  }
}

/// "Your 2025 in review": the year's time heard and song of the year, and
/// the button that opens its report.
class _YearBanner extends StatelessWidget {
  const _YearBanner({
    super.key,
    required this.title,
    required this.line,
    required this.onOpen,
  });

  final String title;
  final String line;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.accentBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.dim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            key: const ValueKey('stats-open-year'),
            onPressed: onOpen,
            child: const Text('Open year report'),
          ),
        ],
      ),
    );
  }
}

/// One tile: what it counts, the number, and the change against the days
/// compared.
class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.label,
    required this.value,
    required this.change,
  });

  final String label;
  final String value;
  final ({String text, bool? up})? change;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final change = this.change;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: colors.dim)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              change?.text ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: change?.up == true ? colors.source3 : colors.dim2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 22),
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.text : colors.dim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the top list: rank, cover, name and detail, a bar for the
/// share of the top row's plays, plays and time heard.
class _RankRow extends StatelessWidget {
  const _RankRow({
    super.key,
    required this.rank,
    required this.row,
    required this.share,
    required this.bars,
    required this.onTap,
    required this.tooltip,
  });

  final int rank;
  final RankedRow row;
  final double share;
  final bool bars;
  final VoidCallback onTap;
  final String tooltip;

  static const _rankWidth = 32.0;
  static const _barWidth = 220.0;
  static const _playsWidth = 70.0;
  static const _listenedWidth = 100.0;

  /// The column titles above the rows.
  static Widget header(
    OwnColors colors, {
    required String first,
    required bool bars,
  }) {
    final style = TextStyle(fontSize: 12, color: colors.dim);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          SizedBox(
            width: _rankWidth,
            child: Text('#', style: style),
          ),
          Expanded(child: Text(first, style: style)),
          if (bars) const SizedBox(width: _barWidth),
          SizedBox(
            width: _playsWidth,
            child: Text('Plays', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: _listenedWidth,
            child: Text('Listened', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    const numbers = [FontFeature.tabularFigures()];
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: colors.hover,
        onTap: onTap,
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                SizedBox(
                  width: _rankWidth,
                  child: Text(
                    '$rank',
                    style: TextStyle(
                      color: colors.dim,
                      fontWeight: FontWeight.w600,
                      fontFeatures: numbers,
                    ),
                  ),
                ),
                TrackTile(track: row.songs.first, size: 40, radius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (row.detail case final detail?)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: colors.dim),
                        ),
                    ],
                  ),
                ),
                if (bars)
                  SizedBox(
                    width: _barWidth,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Container(
                        height: 6,
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: colors.line,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: FractionallySizedBox(
                          widthFactor: share.clamp(0.02, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: colors.accent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: _playsWidth,
                  child: Text(
                    '${row.plays}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFeatures: numbers,
                    ),
                  ),
                ),
                SizedBox(
                  width: _listenedWidth,
                  child: Text(
                    listenedText(row.listenedMs),
                    textAlign: TextAlign.right,
                    style: TextStyle(color: colors.dim, fontFeatures: numbers),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
