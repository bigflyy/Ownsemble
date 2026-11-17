import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/play_stats.dart';
import 'package:ownsemble/library/similar_seeds.dart';
import 'package:ownsemble/library/track.dart';

Track song(int id, String artist, String title, {int? goneAtMs}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: title,
  durationSec: 200,
  sourceKey: '1_$id',
  goneAtMs: goneAtMs,
);

SongPlays heard(int seconds, {int? lastMs}) =>
    SongPlays(plays: 1, listenedMs: seconds * 1000, lastMs: lastMs, starts: 1);

final now = DateTime(2026, 11, 17, 12);

void main() {
  final library = [
    song(1, 'Кино', 'Группа крови'),
    song(2, 'Кино', 'Звезда по имени Солнце'),
    song(3, 'Земфира', 'Искала'),
    song(4, 'Сплин', 'Выхода нет'),
    song(5, 'Metallica', 'One'),
  ];

  List<SimilarSeed> pick({
    Iterable<Track>? songs,
    Map<int, SongPlays> recent = const {},
    Map<int, SongPlays> lastMonth = const {},
    List<int> favorites = const [],
    DateTime? at,
    Set<String> skipTitles = const {},
  }) => pickSimilarSeeds(
    library: songs ?? library,
    recent: recent,
    lastMonth: lastMonth,
    favorites: favorites,
    now: at ?? now,
    skipTitles: skipTitles,
  );

  List<(SimilarSeedKind, int)> ids(List<SimilarSeed> seeds) => [
    for (final seed in seeds) (seed.kind, seed.track.id),
  ];

  test('most heard, then the next one by another artist', () {
    final seeds = pick(
      recent: {1: heard(900), 2: heard(800), 3: heard(300), 4: heard(200)},
    );
    expect(ids(seeds), [
      (SimilarSeedKind.mostHeard, 1),
      (SimilarSeedKind.alsoHeard, 3),
    ]);
  });

  test('a tie goes to the song heard last, then to the lower id', () {
    expect(
      ids(pick(recent: {3: heard(500, lastMs: 10), 4: heard(500, lastMs: 20)})),
      [(SimilarSeedKind.mostHeard, 4), (SimilarSeedKind.alsoHeard, 3)],
    );
    expect(ids(pick(recent: {4: heard(500), 3: heard(500)})), [
      (SimilarSeedKind.mostHeard, 3),
      (SimilarSeedKind.alsoHeard, 4),
    ]);
  });

  test('one artist only gives one seed; artist case and spaces match', () {
    final songs = [
      song(1, 'Кино', 'Группа крови'),
      song(2, ' КИНО ', 'Звезда по имени Солнце'),
    ];
    expect(ids(pick(songs: songs, recent: {1: heard(900), 2: heard(800)})), [
      (SimilarSeedKind.mostHeard, 1),
    ]);
  });

  test('a short listen is no seed', () {
    expect(pick(recent: {1: heard(59)}), isEmpty);
    expect(ids(pick(recent: {1: heard(60)})), [(SimilarSeedKind.mostHeard, 1)]);
  });

  test('no history and no favorites give no seeds', () {
    expect(pick(), isEmpty);
    expect(pick(songs: const []), isEmpty);
  });

  test('a favorite with no play in the last 30 days is rediscovered', () {
    final seeds = pick(
      recent: {1: heard(900), 3: heard(300)},
      lastMonth: {5: heard(200)},
      favorites: [5, 4],
    );
    expect(ids(seeds).last, (SimilarSeedKind.rediscover, 4));
    expect(ids(pick(favorites: [5])), [
      (SimilarSeedKind.rediscover, 5),
    ], reason: 'not played this month');
    // Heard for 10 s today: not a counted play, but heard all the same.
    const brief = SongPlays(plays: 0, listenedMs: 10000, starts: 1);
    expect(
      pick(lastMonth: {5: brief}, favorites: [5]),
      isEmpty,
      reason: 'a short listen today is still a listen',
    );
  });

  test('the rediscovered favorite is by another artist and moves on daily', () {
    // Song 2 is by the most heard song's artist.
    final favorites = [2, 3, 4, 5];
    final picked = <int>{};
    for (var day = 0; day < 3; day++) {
      final seeds = pick(
        recent: {1: heard(900)},
        favorites: favorites,
        at: now.add(Duration(days: day)),
      );
      expect(seeds.last.kind, SimilarSeedKind.rediscover);
      expect(seeds.last.track.id, isNot(2));
      picked.add(seeds.last.track.id);
    }
    expect(picked, {3, 4, 5}, reason: 'three days, three favorites');
  });

  test('gone, removed-from-the-list and unknown songs are no seeds', () {
    final songs = [
      song(1, 'Кино', 'Группа крови', goneAtMs: 1),
      song(3, 'Земфира', 'Искала'),
    ];
    final seeds = pick(
      songs: songs,
      recent: {1: heard(900), 3: heard(300), 99: heard(990)},
      favorites: [1, 98],
    );
    expect(ids(seeds), [(SimilarSeedKind.mostHeard, 3)]);
  });

  test('songs VK already shows a shelf for are left out', () {
    final seeds = pick(
      recent: {1: heard(900), 3: heard(300)},
      skipTitles: {'группа крови'},
    );
    expect(ids(seeds), [(SimilarSeedKind.mostHeard, 3)]);
  });

  test('outside songs (negative ids) are no seeds', () {
    final outside = Track(
      id: -5,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Сплин',
      title: 'Романс',
      durationSec: 200,
      sourceKey: '1_5',
    );
    expect(pick(songs: [outside], recent: {-5: heard(900)}), isEmpty);
  });
}
