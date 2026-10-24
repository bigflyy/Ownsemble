import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/library_probe.dart';

/// Check bounded diagnostic completion without exposing native error contents.
void main() {
  testWidgets(
    'a bounded slow library body can finish before the explicit diagnostic deadline',
    (tester) async {
      // Keep the slow body entirely on the fixture clock instead of using real network time.
      final reports = <Map<String, int>>[];
      // Model a valid response taking longer than the former six-second outer deadline.
      final task = runLibraryProbe(
        read: () => Future.delayed(
          const Duration(milliseconds: 6500),
          () => {
            'counts': {'libraryRows': 2000},
          },
        ),
        report: reports.add,
      );
      await tester.pump(const Duration(seconds: 7));
      await task;
      expect(reports, [
        {'libraryRows': 2000},
      ]);
    },
  );

  test(
    'a stalled probe reports its deadline instead of disappearing',
    () async {
      // Hold the generated request forever to exercise the diagnostic deadline.
      final pending = Completer<Map<String, dynamic>>();
      // Capture only projected numeric reports.
      final reports = <Map<String, int>>[];
      await runLibraryProbe(
        read: () => pending.future,
        report: reports.add,
        deadline: const Duration(milliseconds: 1),
      );
      expect(reports, [
        {'libraryProbeTimeout': 1},
      ]);
    },
  );

  test(
    'successful probe counters are projected again before reporting',
    () async {
      // Capture only recognized, bounded diagnostic counters.
      final reports = <Map<String, int>>[];
      await runLibraryProbe(
        read: () async => {
          'counts': {
            'libraryRows': 2000,
            'privateField': 'generated private value',
          },
        },
        report: reports.add,
      );
      expect(reports, [
        {'libraryRows': 2000},
      ]);
    },
  );

  test('private sign-in cancellation remains a hard boundary', () async {
    // Detect any attempted diagnostic report after access is revoked.
    final reports = <Map<String, int>>[];
    await expectLater(
      runLibraryProbe(
        read: () async =>
            throw const ProofFailure('private_signin_in_progress'),
        report: reports.add,
      ),
      throwsA(isA<ProofFailure>()),
    );
    expect(reports, isEmpty);
  });

  test('native exception details are replaced with a fixed numeric category', () async {
    // Capture sanitized failure information without forwarding exception text.
    final reports = <Map<String, int>>[];
    await runLibraryProbe(
      read: () async => throw StateError('generated private destination'),
      report: reports.add,
    );
    expect(reports, [
      {'libraryProbeScriptFailed': 1},
    ]);
  });
}
