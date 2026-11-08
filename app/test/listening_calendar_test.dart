import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/listening_calendar.dart';
import 'package:ownsemble/library/track.dart';

/// Unix milliseconds of a local time.
int at(int year, int month, int day, [int hour = 12, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

void main() {
  late LibraryStore store;
  late List<int> ids;

  /// Records a play of [trackId] at [atMs] heard for [heardSec].
  void play(
    int trackId,
    int atMs, {
    required double heardSec,
    PlayEnd? ended = PlayEnd.skipped,
  }) {
    final id = store.beginPlay(
      trackId,
      start: PlayStart.chosen,
      shuffle: false,
      atMs: atMs,
    );
    store.updatePlay(id, listenedMs: (heardSec * 1000).round(), ended: ended);
  }

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '42', name: 'VK');
    ids = store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Кино',
        title: 'Кукушка',
        durationSec: 400,
        addedAt: 0,
      ),
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 200,
        addedAt: 0,
      ),
    ]);
  });
  tearDown(() => store.close());

  group('DayRange.days', () {
    test('lists every local day, a clock change included', () {
      final range = DayRange(DateTime(2025, 3, 29), DateTime(2025, 4, 1));
      expect(range.days, [
        DateTime(2025, 3, 29),
        DateTime(2025, 3, 30),
        DateTime(2025, 3, 31),
        DateTime(2025, 4, 1),
      ]);
      expect(DayRange.year(2024).days, hasLength(366));
    });
  });

  group('playsIn', () {
    test('gives the days plays in time order, with what counted', () {
      // Out of order on purpose: the list is sorted by start.
      play(ids[1], at(2025, 10, 16, 21, 5), heardSec: 150); // counts (>= 100)
      play(ids[0], at(2025, 10, 16, 8, 30), heardSec: 12); // early skip
      play(ids[0], at(2025, 10, 17, 0, 0), heardSec: 400); // the next day
      play(ids[1], at(2025, 10, 15, 23, 59), heardSec: 200); // the day before
      store.addPlay(ids[0], atMs: at(2025, 10, 16, 12)); // before schema 9

      final day = store.playsIn(DayRange.day(DateTime(2025, 10, 16)));
      expect([for (final p in day) p.trackId], [ids[0], ids[0], ids[1]]);
      expect(
        [for (final p in day) p.atMs],
        [
          at(2025, 10, 16, 8, 30),
          at(2025, 10, 16, 12),
          at(2025, 10, 16, 21, 5),
        ],
      );
      expect([for (final p in day) p.counted], [false, true, true]);
      expect([for (final p in day) p.listenedMs], [12000, 0, 150000]);
      expect(day.first.ended, PlayEnd.skipped);
      expect(day[1].ended, isNull);

      final three = store.playsIn(
        DayRange(DateTime(2025, 10, 15), DateTime(2025, 10, 17)),
      );
      expect(three, hasLength(5));
      expect(three.first.atMs, at(2025, 10, 15, 23, 59));
      expect(three.last.atMs, at(2025, 10, 17, 0, 0));
      expect(store.playsIn(DayRange.day(DateTime(2025, 10, 18))), isEmpty);
    });

    test('all time when no range is given', () {
      play(ids[0], at(2024, 1, 1), heardSec: 400);
      play(ids[1], at(2026, 1, 1), heardSec: 200);
      expect(store.playsIn(null), hasLength(2));
    });
  });

  group('heardByDay', () {
    test('sums heard time per local day, skips included', () {
      play(ids[0], at(2025, 10, 1, 0, 0), heardSec: 60);
      play(ids[1], at(2025, 10, 1, 23, 59), heardSec: 10);
      play(ids[1], at(2025, 10, 3, 9), heardSec: 30);
      play(ids[1], at(2025, 10, 4, 0, 0), heardSec: 5); // after the range
      final range = DayRange(DateTime(2025, 10, 1), DateTime(2025, 10, 3));
      expect(store.heardByDay(range), [70000, 0, 30000]);
    });
  });

  group('heardByWeekHour', () {
    test('puts each play in the local weekday and hour it started', () {
      // 16 Oct 2025 is a Thursday; 19 Oct a Sunday.
      play(ids[0], at(2025, 10, 16, 21, 5), heardSec: 100);
      play(ids[1], at(2025, 10, 16, 21, 59), heardSec: 20);
      play(ids[1], at(2025, 10, 19, 0, 10), heardSec: 30);
      play(ids[1], at(2025, 10, 20, 8), heardSec: 40); // Monday
      play(ids[0], at(2025, 9, 1, 8), heardSec: 999); // outside the range
      final grid = store.heardByWeekHour(
        DayRange(DateTime(2025, 10, 1), DateTime(2025, 10, 31)),
      );
      expect(grid, hasLength(7 * 24));
      expect(grid[weekHour(DateTime.thursday, 21)], 120000);
      expect(grid[weekHour(DateTime.sunday, 0)], 30000);
      expect(grid[weekHour(DateTime.monday, 8)], 40000);
      expect(grid[0 * 24 + 8], 40000, reason: 'Monday is row 0');
      expect(grid.fold(0, (a, b) => a + b), 190000);
      expect(store.heardByWeekHour(null).fold(0, (a, b) => a + b), 1189000);
    });
  });
}
