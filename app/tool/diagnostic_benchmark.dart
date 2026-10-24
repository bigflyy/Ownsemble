import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/services/diagnostic_journal.dart';

/// Measure generated logging cost separately from network, native decoding and disk.
Future<void> main() async {
  // Warm the Dart JIT before reporting per-event timings.
  final journal = DiagnosticJournal();
  // Model a typical bounded provider observation without any private content.
  const event = <String, Object>{
    'stage': 'waiting_source',
    'requests': 8,
    'candidates': 0,
    'counts': {
      'modernRows': 114,
      'modernPropsFound': 114,
      'modernURLsFound': 114,
    },
  };
  for (var sample = 0; sample < 500; sample++) {
    journal.record(event);
  }
  // Collect independent samples so a slow export cannot hide in an average event cost.
  final timings = <int>[];
  await journal.run('playback', () async {
    for (var sample = 0; sample < 5000; sample++) {
      // Include filtering, correlation and bounded ring maintenance in each measurement.
      final watch = Stopwatch()..start();
      journal.record(event);
      timings.add(watch.elapsedMicroseconds);
    }
  });
  timings.sort();
  // Measure report serialization independently from ordinary event collection.
  final exportWatch = Stopwatch()..start();
  // Serialize exactly the same safe snapshot as the file writer.
  final report = journal.snapshot();
  // Report only generated counts/timings; never inspect runtime data or profiles.
  final bytes = utf8.encode(jsonEncode(report)).length;
  stdout.writeln(
    jsonEncode({
      'generated_events': timings.length,
      'median_us': timings[timings.length ~/ 2],
      'p95_us': timings[(timings.length * 0.95).floor()],
      'p99_us': timings[(timings.length * 0.99).floor()],
      'snapshot_us': exportWatch.elapsedMicroseconds,
      'retained_events': (report['events'] as List).length,
      'snapshot_bytes': bytes,
    }),
  );
}
