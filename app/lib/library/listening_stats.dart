import 'day_range.dart';
import 'play_period.dart';
import 'play_stats.dart';
import 'track.dart';

/// What the Stats place ranks (plan 04, D1): its Songs, Artists and Albums
/// tabs.
enum RankBy { songs, artists, albums }

/// The four tiles of the Stats place for one period.
typedef PeriodTotals = ({int listenedMs, int plays, int songs, int artists});

/// One row of a top list: a song, an artist or an album, with what its
/// plays add up to.
class RankedRow {
  const RankedRow({
    required this.name,
    required this.detail,
    required this.plays,
    required this.listenedMs,
    required this.songs,
  });

  /// The song's title, the artist, or the album's title.
  final String name;

  /// The line under the name: a song's or album's artist, or "3 songs
  /// played" for an artist.
  final String? detail;

  /// Counted plays.
  final int plays;

  /// Time heard, skips included.
  final int listenedMs;

  /// The row's songs that have plays, most played first (one for a song).
  final List<Track> songs;
}

/// Totals and top lists of one period's plays (plan 04, D1).
///
/// [plays] are the period's play numbers by library id (from
/// `songPlays(range:)`), [songs] the library's songs by id. A song the
/// library no longer lists still adds to the plays and time heard, but it
/// cannot be named, so it is in no top list and adds no artist.
class ListeningStats {
  ListeningStats(this.songs, this.plays);

  final Map<int, Track> songs;
  final Map<int, SongPlays> plays;

  late final PeriodTotals totals = _totals();

  PeriodTotals _totals() {
    var listened = 0, counted = 0, played = 0;
    final artists = <String>{};
    for (final MapEntry(key: id, value: p) in plays.entries) {
      listened += p.listenedMs;
      counted += p.plays;
      if (p.plays == 0) continue;
      played++;
      if (songs[id] case final track?) artists.add(track.artist);
    }
    return (
      listenedMs: listened,
      plays: counted,
      songs: played,
      artists: artists.length,
    );
  }

  /// Songs with a counted play, most counted plays first, then most time
  /// heard, then by title.
  late final List<(Track, SongPlays)> _played = () {
    final list = [
      for (final MapEntry(key: id, value: p) in plays.entries)
        if (p.plays > 0)
          if (songs[id] case final track?) (track, p),
    ];
    list.sort(
      (a, b) => _order(
        a.$2.plays,
        b.$2.plays,
        a.$2.listenedMs,
        b.$2.listenedMs,
        a.$1.title,
        b.$1.title,
      ),
    );
    return list;
  }();

  /// The first [limit] rows ranked by [by]. Artists and albums add up
  /// their songs' counted plays and time heard; time from plays that did
  /// not count is left out of a row, as its song is not in the list.
  List<RankedRow> top(RankBy by, {int limit = 100}) {
    final rows = switch (by) {
      RankBy.songs => [
        for (final (track, p) in _played)
          RankedRow(
            name: track.title,
            detail: track.artist,
            plays: p.plays,
            listenedMs: p.listenedMs,
            songs: [track],
          ),
      ],
      RankBy.artists => _grouped(
        (track) => track.artist,
        name: (track) => track.artist,
        detail: (songs) => songs.length == 1
            ? '1 song played'
            : '${songs.length} songs played',
      ),
      RankBy.albums => _grouped(
        (track) => switch (track.album) {
          // The same title by two artists is two albums, as an album opens.
          final title? when title.isNotEmpty => '$title\n${track.artist}',
          _ => null,
        },
        name: (track) => track.album!,
        detail: (songs) => songs.first.artist,
      ),
    };
    return rows.length > limit ? rows.sublist(0, limit) : rows;
  }

  List<RankedRow> _grouped(
    String? Function(Track track) keyOf, {
    required String Function(Track first) name,
    required String Function(List<Track> songs) detail,
  }) {
    // _played is in rank order, so each group's songs are too.
    final groups = <String, List<(Track, SongPlays)>>{};
    for (final entry in _played) {
      final key = keyOf(entry.$1);
      if (key != null) (groups[key] ??= []).add(entry);
    }
    final rows = [
      for (final members in groups.values)
        RankedRow(
          name: name(members.first.$1),
          detail: detail([for (final (track, _) in members) track]),
          plays: members.fold(0, (sum, m) => sum + m.$2.plays),
          listenedMs: members.fold(0, (sum, m) => sum + m.$2.listenedMs),
          songs: [for (final (track, _) in members) track],
        ),
    ];
    rows.sort(
      (a, b) =>
          _order(a.plays, b.plays, a.listenedMs, b.listenedMs, a.name, b.name),
    );
    return rows;
  }

  /// Most plays first, then most time heard, then by name A to Z.
  static int _order(
    int playsA,
    int playsB,
    int heardA,
    int heardB,
    String nameA,
    String nameB,
  ) {
    if (playsA != playsB) return playsB - playsA;
    if (heardA != heardB) return heardB - heardA;
    return nameA.toLowerCase().compareTo(nameB.toLowerCase());
  }
}

/// The days [period]'s numbers are compared with: the period before it, or,
/// while [period] holds today, the same number of its first days (1 - 8
/// October against 1 - 8 November), cut at that period's end. Null for all
/// time.
DayRange? comparedRange(PlayPeriod period, DateTime now) {
  final range = period.rangeAt(now);
  if (range == null) return null;
  final before = period.step(-1).rangeAt(now)!;
  final today = DateTime(now.year, now.month, now.day);
  if (!range.contains(today.millisecondsSinceEpoch)) return before;
  final days = DayRange(range.first, today).dayCount;
  final end = DateTime(
    before.first.year,
    before.first.month,
    before.first.day + days - 1,
  );
  return DayRange(before.first, end.isAfter(before.last) ? before.last : end);
}

/// What a tile says under its number: the change against [before] (the
/// same number over [compared]), or when counting began. [up] is true for
/// more, false for less, null when no direction applies. Null when there
/// is nothing to say (no plays at all).
///
/// Days that all lie before the first recorded play ([firstPlayMs]) are
/// not compared: "nothing then" would only mean "not counted yet".
({String text, bool? up})? changeAgainst(
  int now,
  int? before,
  DayRange? compared, {
  required int? firstPlayMs,
}) {
  final since = firstPlayMs == null
      ? null
      : 'Counting since ${PlayPeriod.rangeLabel(DayRange.day(DateTime.fromMillisecondsSinceEpoch(firstPlayMs)))}';
  if (compared == null || before == null) {
    return since == null ? null : (text: since, up: null);
  }
  if (firstPlayMs != null && compared.endMs <= firstPlayMs) {
    return (text: since!, up: null);
  }
  final name = PlayPeriod.rangeLabel(compared);
  if (before == 0) return (text: 'Nothing in $name', up: null);
  final percent = ((now - before) * 100 / before).round();
  if (percent == 0) return (text: 'Same as $name', up: null);
  return (text: '${percent > 0 ? '+' : ''}$percent% vs $name', up: percent > 0);
}
