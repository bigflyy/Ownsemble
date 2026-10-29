import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/library_scanner.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test(
    'unchanged rows do not rewrite and rebuild the library on every poll',
    () async {
      var time = Duration.zero, reads = 0;
      final writes = <List<Track>>[];
      final scanner = LibraryScanner(
        elapsed: () => time,
        cancelled: () => false,
        progress: (_) {},
        quietLimit: const Duration(seconds: 3),
        hardLimit: const Duration(seconds: 8),
        read: () async {
          reads++;
          return [Track('1_1', reads < 3 ? 'Before' : 'After', 'Artist', 30)];
        },
        advance: (_, _) async {
          time += const Duration(seconds: 1);
          return false;
        },
        merge: writes.add,
      );
      await scanner.run();
      expect(reads, greaterThan(3));
      expect(writes.map((rows) => rows.single.title), ['Before', 'After']);
    },
  );
  test(
    'slow rows and unchanged virtualized row counts still make progress',
    () async {
      var time = Duration.zero, page = 0;
      final found = <String>{};
      final scanner = LibraryScanner(
        elapsed: () => time,
        cancelled: () => false,
        progress: (_) {},
        quietLimit: const Duration(seconds: 5),
        hardLimit: const Duration(seconds: 24),
        read: () async => [Track('1_${page ~/ 3}', 'Song', 'Artist', 30)],
        advance: (ms, retry) async {
          page++;
          time += const Duration(seconds: 2);
          return page < 8;
        },
        merge: (tracks) => found.addAll(tracks.map((t) => t.id)),
      );
      final result = await scanner.run();
      expect(found.length, greaterThan(3));
      expect(result.reason, 'time_budget');
      expect(result.continueSweep, isTrue);
    },
  );
  test('a stuck loading spinner cannot defeat the hard limit', () async {
    var time = Duration.zero;
    final scanner = LibraryScanner(
      elapsed: () => time,
      cancelled: () => false,
      progress: (_) {},
      hardLimit: const Duration(seconds: 10),
      quietLimit: const Duration(seconds: 2),
      read: () async => [],
      advance: (ms, retry) async {
        time += const Duration(seconds: 2);
        return true;
      },
      merge: (_) {},
    );
    final result = await scanner.run();
    expect(result.reason, 'time_budget');
    expect(time.inSeconds, 10);
  });
  test('yield to playback keeps the already merged partial library', () async {
    var cancel = false;
    final merged = <Track>[];
    final scanner = LibraryScanner(
      elapsed: () => Duration.zero,
      cancelled: () => cancel,
      progress: (_) {},
      read: () async => [const Track('1_1', 'First', 'Artist', 30)],
      advance: (ms, retry) async {
        cancel = true;
        return false;
      },
      merge: merged.addAll,
    );
    expect((await scanner.run()).reason, 'yielded');
    expect(merged.single.id, '1_1');
  });
  test(
    'quiet boundary stays partial and only ends the current sweep',
    () async {
      var time = Duration.zero;
      final scanner = LibraryScanner(
        elapsed: () => time,
        cancelled: () => false,
        progress: (_) {},
        quietLimit: const Duration(seconds: 3),
        hardLimit: const Duration(seconds: 20),
        read: () async => [const Track('1_1', 'First', 'Artist', 30)],
        advance: (ms, retry) async {
          time += const Duration(seconds: 1);
          return false;
        },
        merge: (_) {},
      );
      final result = await scanner.run();
      expect(result.reason, 'quiet_boundary');
      expect(result.continueSweep, isFalse);
    },
  );
}
