// Adds a generated listening history to a speed-gate library, so the play
// counts, filters and sorts of plan 04 are measured against years of plays.
// Only for the agent's gate data folder: never run it on a real library.
//
// The plays end today and go back --days days, --per-day a day, spread
// unevenly (a quarter of them on 200 favorite songs), a third skipped early.
// The library remembers that it got them; a second run adds nothing.
//
// Run from app/:
//   dart run tool/add_gate_history.dart --data-dir ../.local/v2-test/gate
//       [--days 1095] [--per-day 100]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:path/path.dart' as p;

const _doneSetting = 'gate.generated_history';

void main(List<String> args) {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  if (dataDir == null) {
    print(
      'Usage: add_gate_history.dart --data-dir DIR [--days N] '
      '[--per-day N]',
    );
    exit(64);
  }
  if (!p.normalize(dataDir).contains('v2-test')) {
    print('Refused: $dataDir is not an agent test folder (.local/v2-test).');
    exit(65);
  }
  final days = int.parse(valueOf('--days') ?? '1095');
  final perDay = int.parse(valueOf('--per-day') ?? '100');
  final store = LibraryStore.open(p.join(dataDir, 'library.db'));
  try {
    final done = store.readSetting(_doneSetting);
    if (done != null) {
      print('This library already has a generated history: $done.');
      return;
    }
    final ids = [for (final track in store.loadAll()) track.id];
    if (ids.isEmpty) {
      print('No songs in the library.');
      exit(1);
    }
    final rows = <(int, int, int, String)>[];
    final today = DateTime.now();
    var seed = 11;
    int next(int bound) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % bound;
    }

    for (var d = days - 1; d >= 1; d--) {
      final dayStart = DateTime(today.year, today.month, today.day - d, 8);
      for (var n = 0; n < perDay; n++) {
        final index = next(4) == 0 ? next(200) : next(ids.length);
        final atMs =
            dayStart.millisecondsSinceEpoch + n * 4 * 60 * 1000 + next(60000);
        final skipped = next(3) == 0;
        rows.add((
          ids[index % ids.length],
          atMs,
          skipped ? next(20000) : 150000 + next(90000),
          skipped ? 'skipped' : 'finished',
        ));
      }
    }
    final watch = Stopwatch()..start();
    store.addPlays(rows);
    store.writeSetting(
      _doneSetting,
      '${rows.length} plays over $days days, added ${today.toIso8601String()}',
    );
    print(
      'Added ${rows.length} plays over $days days to ${ids.length} songs '
      'in ${watch.elapsedMilliseconds} ms.',
    );
  } finally {
    store.close();
  }
}
