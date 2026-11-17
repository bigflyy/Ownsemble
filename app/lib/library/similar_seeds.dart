import 'play_stats.dart';
import 'track.dart';

/// Why a song was picked to find songs similar to it (plan 07, Stage E).
enum SimilarSeedKind {
  /// The song heard longest in the last [recentDays] days.
  mostHeard,

  /// The next most heard song there, by another artist.
  alsoHeard,

  /// A favorite not heard for [rediscoverAfterDays] days or more; which one
  /// changes from day to day.
  rediscover,
}

/// One song the For you place shows a "Similar to" shelf for.
typedef SimilarSeed = ({SimilarSeedKind kind, Track track});

/// The days whose heard time picks [SimilarSeedKind.mostHeard] and
/// [SimilarSeedKind.alsoHeard].
const recentDays = 14;

/// How long a favorite must go unheard to be a
/// [SimilarSeedKind.rediscover] seed.
const rediscoverAfterDays = 30;

/// Heard time below which a recent song is not a seed: one short listen
/// says little about taste.
const minSeedHeardMs = 60 * 1000;

/// Picks up to three seeds, each by a different artist: the most heard
/// song of the last [recentDays] days ([recent]), the next most heard by
/// another artist, and a favorite ([favorites], track ids) that has no play
/// at all in [lastMonth], the plays of the last [rediscoverAfterDays] days
/// (any start counts, also a short one: a favorite heard briefly today is
/// not "not heard in a while"). Only songs listed in [library] that
/// are not gone from VK can be seeds; songs whose title is in [skipTitles]
/// (lower case: VK's own "Similar to" shelves) are left out.
///
/// Ties in heard time go to the song heard last, then to the lower id, so
/// the same history always gives the same seeds. The rediscovered favorite
/// moves on by one each day.
List<SimilarSeed> pickSimilarSeeds({
  required Iterable<Track> library,
  required Map<int, SongPlays> recent,
  required Map<int, SongPlays> lastMonth,
  required List<int> favorites,
  required DateTime now,
  Set<String> skipTitles = const {},
}) {
  final byId = <int, Track>{
    for (final track in library)
      if (track.inLibrary &&
          !track.isGone &&
          !skipTitles.contains(track.title.trim().toLowerCase()))
        track.id: track,
  };
  final seeds = <SimilarSeed>[];
  final artists = <String>{};
  bool takes(Track track) => !artists.contains(_artistOf(track));
  void add(SimilarSeedKind kind, Track track) {
    seeds.add((kind: kind, track: track));
    artists.add(_artistOf(track));
  }

  final heard =
      [
        for (final MapEntry(key: id, value: plays) in recent.entries)
          if (byId[id] != null && plays.listenedMs >= minSeedHeardMs)
            (track: byId[id]!, plays: plays),
      ]..sort((a, b) {
        final byHeard = b.plays.listenedMs.compareTo(a.plays.listenedMs);
        if (byHeard != 0) return byHeard;
        final byLast = (b.plays.lastMs ?? 0).compareTo(a.plays.lastMs ?? 0);
        if (byLast != 0) return byLast;
        return a.track.id.compareTo(b.track.id);
      });
  for (final kind in [SimilarSeedKind.mostHeard, SimilarSeedKind.alsoHeard]) {
    final next = heard.where((h) => takes(h.track)).firstOrNull;
    if (next != null) add(kind, next.track);
  }

  final unheard = [
    for (final id in favorites.toSet())
      if (byId[id] case final track?)
        if ((lastMonth[id]?.starts ?? 0) == 0 && takes(track)) track,
  ]..sort((a, b) => a.id.compareTo(b.id));
  if (unheard.isNotEmpty) {
    // Counted in UTC, so a summer-time change cannot make a day 23 hours.
    final day = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(2000)).inDays;
    add(SimilarSeedKind.rediscover, unheard[day % unheard.length]);
  }
  return seeds;
}

/// A song's artist as seeds compare it: case and spaces do not matter.
String _artistOf(Track track) => track.artist.trim().toLowerCase();
