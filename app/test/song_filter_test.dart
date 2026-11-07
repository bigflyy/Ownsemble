import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/play_stats.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';

/// Saturday 7 November 2026, mid-day.
final now = DateTime(2026, 11, 7, 14);

Track track(
  int id,
  String artist, {
  int seconds = 200,
  DateTime? added,
  String? cover,
}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: 'Песня $id',
  durationSec: seconds,
  addedAt: (added ?? DateTime(2020)).millisecondsSinceEpoch ~/ 1000,
  coverUrl: cover,
);

SongPlays plays(int n, {int? lastMs, int starts = 0, int earlySkips = 0}) =>
    SongPlays(
      plays: n,
      listenedMs: n * 200000,
      lastMs: lastMs,
      firstMs: lastMs,
      starts: starts == 0 ? n : starts,
      earlySkips: earlySkips,
    );

void main() {
  group('PlayPeriod', () {
    test('week, month and year are the current ones, stepped back by '
        'the offset', () {
      expect(
        const PlayPeriod.week().rangeAt(now),
        DayRange(DateTime(2026, 11, 2), DateTime(2026, 11, 8)),
      );
      expect(
        const PlayPeriod.week(offset: -1).rangeAt(now),
        DayRange(DateTime(2026, 10, 26), DateTime(2026, 11, 1)),
      );
      expect(const PlayPeriod.month().rangeAt(now), DayRange.month(2026, 11));
      expect(
        const PlayPeriod.month(offset: -11).rangeAt(now),
        DayRange.month(2025, 12),
      );
      expect(
        const PlayPeriod.year(offset: -1).rangeAt(now),
        DayRange.year(2025),
      );
      expect(const PlayPeriod.all().rangeAt(now), isNull);
    });

    test('labels', () {
      expect(const PlayPeriod.week().label(now), '2 - 8 Nov 2026');
      expect(const PlayPeriod.week(offset: -10).label(now), '24 - 30 Aug 2026');
      expect(
        PlayPeriod.custom(
          DayRange(DateTime(2026, 10, 26), DateTime(2026, 11, 1)),
        ).label(now),
        '26 Oct - 1 Nov 2026',
      );
      expect(const PlayPeriod.month().label(now), 'November 2026');
      expect(const PlayPeriod.year().label(now), '2026');
      expect(const PlayPeriod.all().label(now), 'All time');
      expect(
        PlayPeriod.custom(
          DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30)),
        ).label(now),
        '1 Oct - 30 Nov 2025',
      );
      expect(
        PlayPeriod.custom(
          DayRange(DateTime(2024, 12, 20), DateTime(2025, 1, 5)),
        ).label(now),
        '20 Dec 2024 - 5 Jan 2025',
      );
      expect(
        PlayPeriod.custom(DayRange.month(2025, 10)).label(now),
        'October 2025',
      );
    });

    test('arrows step by the range; whole months step by months', () {
      final octNov = PlayPeriod.custom(
        DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30)),
      );
      expect(
        octNov.step(-1).rangeAt(now),
        DayRange(DateTime(2025, 8, 1), DateTime(2025, 9, 30)),
      );
      expect(
        octNov.step(1).rangeAt(now),
        DayRange(DateTime(2025, 12, 1), DateTime(2026, 1, 31)),
      );
      final tenDays = PlayPeriod.custom(
        DayRange(DateTime(2025, 10, 1), DateTime(2025, 10, 10)),
      );
      expect(
        tenDays.step(1).rangeAt(now),
        DayRange(DateTime(2025, 10, 11), DateTime(2025, 10, 20)),
      );
      expect(
        const PlayPeriod.month().step(-2),
        const PlayPeriod.month(offset: -2),
      );
    });

    test('no step into the future', () {
      expect(const PlayPeriod.month().canStepForward(now), isFalse);
      expect(const PlayPeriod.month(offset: -1).canStepForward(now), isTrue);
      expect(
        PlayPeriod.custom(DayRange.month(2026, 10)).canStepForward(now),
        isTrue,
      );
      expect(
        PlayPeriod.custom(DayRange.month(2026, 11)).canStepForward(now),
        isFalse,
      );
      expect(const PlayPeriod.all().canStepForward(now), isFalse);
    });

    test('current week, month and year move with time; anything stepped '
        'back is saved as fixed dates', () {
      expect(const PlayPeriod.month().moves, isTrue);
      expect(const PlayPeriod.month().fixedAt(now), const PlayPeriod.month());
      expect(
        const PlayPeriod.month(offset: -1).fixedAt(now),
        PlayPeriod.custom(DayRange.month(2026, 10)),
      );
      final custom = PlayPeriod.custom(DayRange.month(2025, 10));
      expect(custom.moves, isFalse);
      expect(custom.fixedAt(now), custom);
      expect(const PlayPeriod.all().fixedAt(now), const PlayPeriod.all());
    });

    test('a JSON round trip', () {
      for (final period in [
        const PlayPeriod.week(),
        const PlayPeriod.month(offset: -3),
        const PlayPeriod.year(),
        const PlayPeriod.all(),
        PlayPeriod.custom(
          DayRange(DateTime(2025, 10, 1), DateTime(2025, 11, 30)),
        ),
      ]) {
        final json = jsonEncode(period.toJson());
        expect(PlayPeriod.fromJson(jsonDecode(json)), period, reason: json);
      }
      expect(PlayPeriod.fromJson('rubbish'), isNull);
    });
  });

  group('SongFilter', () {
    final songs = [
      track(1, 'Кино', seconds: 398, cover: 'c'),
      track(2, 'Сплин', seconds: 232, added: DateTime(2026, 11, 3)),
      track(3, 'Земфира', seconds: 150, added: DateTime(2026, 2, 1)),
      track(4, 'Кино', seconds: 286),
    ];
    final allTime = {
      1: plays(96, lastMs: DateTime(2026, 3, 1).millisecondsSinceEpoch),
      2: plays(3, lastMs: DateTime(2026, 11, 7, 9).millisecondsSinceEpoch),
      3: plays(0, starts: 6, earlySkips: 5),
    };
    final inMonth = {2: plays(3)};
    final facts = SongFacts(
      now: now,
      allTime: allTime,
      period: inMonth,
      isOffline: (t) => t.id == 4,
      isFavorite: (t) => t.id == 2 || t.id == 3,
    );
    List<int> ids(SongFilter filter, [SongFacts? with_]) => [
      for (final song in songs)
        if (filter.matches(song, with_ ?? facts)) song.id,
    ];

    test('no rules lets every song through', () {
      expect(ids(const SongFilter()), [1, 2, 3, 4]);
      expect(const SongFilter().isEmpty, isTrue);
    });

    test('several values in one chip: any of them', () {
      final filter = const SongFilter().withRule(
        const FilterRule(FilterField.artist, values: {'Кино', 'Земфира'}),
      );
      expect(ids(filter), [1, 3, 4]);
    });

    test('is not', () {
      final filter = const SongFilter().withRule(
        const FilterRule(FilterField.artist, values: {'Кино'}, negate: true),
      );
      expect(ids(filter), [2, 3]);
    });

    test('different chips must all match', () {
      final filter = const SongFilter()
          .withRule(
            const FilterRule(FilterField.artist, values: {'Кино', 'Сплин'}),
          )
          .withRule(const FilterRule(FilterField.length, values: {'long'}));
      expect(ids(filter), [1, 4]);
    });

    test('plays count in the page period, or in the chip own dates', () {
      final inPage = const SongFilter().withRule(
        const FilterRule(FilterField.plays, values: {'1'}),
      );
      expect(ids(inPage), [2]);
      final notPlayed = const SongFilter().withRule(
        const FilterRule(FilterField.plays, values: {'0'}),
      );
      expect(ids(notPlayed), [1, 3, 4]);
      final own = PlayPeriod.custom(DayRange.year(2025));
      final ownDates = const SongFilter().withRule(
        FilterRule(FilterField.plays, values: const {'20'}, period: own),
      );
      final withOwn = SongFacts(
        now: now,
        allTime: allTime,
        period: inMonth,
        isOffline: (_) => false,
        own: {
          own: {1: plays(40), 4: plays(19)},
        },
      );
      expect(ids(ownDates, withOwn), [1]);
      expect(ownDates.ownPeriods, [own]);
    });

    test('dates: added, last played, never played', () {
      SongFilter one(FilterField field, String value, {bool negate = false}) =>
          const SongFilter().withRule(
            FilterRule(field, values: {value}, negate: negate),
          );
      expect(ids(one(FilterField.added, '7d')), [2]);
      expect(ids(one(FilterField.added, 'year')), [2, 3]);
      expect(ids(one(FilterField.added, 'old')), [1, 4]);
      expect(ids(one(FilterField.lastPlayed, 'today')), [2]);
      expect(ids(one(FilterField.lastPlayed, '7d')), [2]);
      expect(ids(one(FilterField.lastPlayed, 'month+')), [1]);
      expect(ids(one(FilterField.lastPlayed, 'half+')), [
        1,
      ], reason: '8 months');
      expect(ids(one(FilterField.never, 'yes')), [3, 4]);
      expect(ids(one(FilterField.never, 'yes', negate: true)), [1, 2]);
    });

    test('offline, cover, often skipped, favorite', () {
      SongFilter on(FilterField field, {bool negate = false}) =>
          const SongFilter().withRule(
            FilterRule(field, values: const {'yes'}, negate: negate),
          );
      expect(ids(on(FilterField.offline)), [4]);
      expect(ids(on(FilterField.offline, negate: true)), [1, 2, 3]);
      expect(ids(on(FilterField.cover)), [1]);
      expect(ids(on(FilterField.skipped)), [3]);
      expect(ids(on(FilterField.favorite)), [2, 3]);
      expect(ids(on(FilterField.favorite, negate: true)), [1, 4]);
    });

    test('a rule without values is no rule', () {
      final filter = const SongFilter().withRule(
        const FilterRule(FilterField.artist, values: {}),
      );
      expect(filter.isEmpty, isTrue);
    });

    test('replacing and removing a chip', () {
      final filter = const SongFilter()
          .withRule(const FilterRule(FilterField.artist, values: {'Кино'}))
          .withRule(const FilterRule(FilterField.artist, values: {'Сплин'}));
      expect(filter.rules.single.values, {'Сплин'});
      expect(filter.without(FilterField.artist).isEmpty, isTrue);
      expect(filter.ruleFor(FilterField.plays), isNull);
    });

    test('held as a rule tree, kept as JSON with Cyrillic intact', () {
      final filter = const SongFilter()
          .withRule(
            const FilterRule(FilterField.artist, values: {'Кино', 'Сплин'}),
          )
          .withRule(
            FilterRule(
              FilterField.plays,
              values: const {'5'},
              negate: true,
              period: PlayPeriod.custom(DayRange.year(2025)),
            ),
          );
      final json = jsonEncode(filter.toJson());
      expect(json, contains('"all"'));
      expect(json, contains('Кино'));
      final back = SongFilter.fromJson(jsonDecode(json));
      expect(back, filter);
      // A group inside a group (nested AND/OR, later) is read, not lost.
      final nested = SongFilter.fromJson({
        'all': [
          {
            'any': [
              {
                'f': 'artist',
                'v': ['Кино'],
              },
              {
                'f': 'length',
                'v': ['long'],
              },
            ],
          },
        ],
      });
      expect(ids(nested), [1, 4]);
      expect(SongFilter.fromJson({'all': 'rubbish'}).isEmpty, isTrue);
    });
  });

  test('date chips over 10,000 songs stay fast', () {
    final many = [
      for (var i = 0; i < 10000; i++)
        track(
          i,
          'Artist ${i % 500}',
          added: DateTime(2020 + i % 7, 1 + i % 12),
        ),
    ];
    final allTime = {
      for (var i = 0; i < 10000; i += 2)
        i: plays(3, lastMs: DateTime(2026, 1 + i % 11).millisecondsSinceEpoch),
    };
    final facts = SongFacts(
      now: now,
      allTime: allTime,
      period: const {},
      isOffline: (_) => false,
    );
    final filter = const SongFilter()
        .withRule(
          const FilterRule(FilterField.lastPlayed, values: {'month+', '7d'}),
        )
        .withRule(const FilterRule(FilterField.added, values: {'old'}));
    for (final song in many) {
      filter.matches(song, facts);
    }
    final watch = Stopwatch()..start();
    var kept = 0;
    for (final song in many) {
      if (filter.matches(song, facts)) kept++;
    }
    final ms = watch.elapsedMicroseconds / 1000;
    expect(kept, greaterThan(0));
    expect(ms, lessThan(15), reason: '$ms ms');
  });

  group('auto names', () {
    test('period first, then the chips', () {
      final filter = const SongFilter()
          .withRule(const FilterRule(FilterField.artist, values: {'Кино'}))
          .withRule(const FilterRule(FilterField.plays, values: {'5'}));
      expect(
        autoViewName(filter, PlayPeriod.custom(DayRange.month(2025, 11)), now),
        'November 2025 - Кино, 5+ plays',
      );
      expect(
        autoViewName(filter, const PlayPeriod.month(), now),
        'This month - Кино, 5+ plays',
      );
      expect(
        autoViewName(filter, const PlayPeriod.all(), now),
        'Кино, 5+ plays',
      );
      expect(
        autoViewName(const SongFilter(), const PlayPeriod.year(), now),
        'This year',
      );
    });

    test('negated chips, many values and own dates', () {
      final filter = const SongFilter()
          .withRule(
            const FilterRule(
              FilterField.artist,
              values: {'Кино', 'Сплин', 'Земфира'},
              negate: true,
            ),
          )
          .withRule(
            FilterRule(
              FilterField.plays,
              values: const {'20'},
              period: PlayPeriod.custom(DayRange.year(2025)),
            ),
          )
          .withRule(const FilterRule(FilterField.offline, values: {'yes'}));
      expect(
        autoViewName(filter, const PlayPeriod.all(), now),
        'not Кино +2, 20+ plays in 2025, offline',
      );
    });
  });
}
