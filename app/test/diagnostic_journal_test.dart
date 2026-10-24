import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/diagnostic_journal.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/diagnostic_schema.dart';

/// Verify private-data exclusion, asynchronous tracing and retained failure evidence.
void main() {
  test('a timeout retains its last active phase even after context rotation and restart', () async {
    // Keep the source lookup phase distinct from the terminal failed outcome.
    final journal = DiagnosticJournal();
    await journal.run('playback', () async {
      journal.record({'stage': 'playback_status', 'phase': 'resolving_source'});
      // Rotate the ordinary context beyond the initial startup-phase event.
      for (var event = 0; event < 100; event++) {
        journal.record({'stage': 'waiting_source', 'requests': event});
      }
      journal.record({
        'stage': 'playback_status',
        'phase': 'failed',
        'category': 'player_start_timeout',
      });
    });
    // Require triage to identify source resolution rather than generic native playback.
    final failure = (journal.snapshot()['failures'] as List).single as Map;
    expect(failure['area'], 'source_resolution');
    expect(failure['phase'], 'resolving_source');
    // Preserve the same location after revalidating a saved report from the earlier run.
    final restarted = DiagnosticJournal()..restoreFailures(journal.snapshot());
    expect(
      (restarted.snapshot()['failures'] as List).single['area'],
      'source_resolution',
    );
  });

  test('unexpected failures retain a safe component and exception kind', () {
    // Preserve useful locations without exporting a stack, path or exception message.
    final journal = DiagnosticJournal();
    journal.record({
      'stage': 'operation_failed',
      'category': 'operation_failed',
      'component': 'provider',
      'kind': 'type',
    });
    // Inspect the generated event, independently from failure-area suggestions.
    final event = (journal.snapshot()['events'] as List).single as Map;
    expect(event['component'], 'provider');
    expect(event['kind'], 'type');
  });

  test('every literal production failure category has a registered safe diagnostic name', () {
    // Search public application source only, never runtime or browser/profile files.
    final pattern = RegExp(r"ProofFailure\(\s*'([a-z][a-z0-9_]+)'");
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      // Skip non-Dart resources without opening their contents.
      if (!file.path.endsWith('.dart')) continue;
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        expect(
          safeDiagnosticCategory(match.group(1)),
          match.group(1),
          reason: file.path,
        );
      }
    }
  });

  test(
    'native follow-up symptoms preserve the first transfer cause and status',
    () async {
      // Preserve the network error even when relay/native cleanup reports another symptom.
      final journal = DiagnosticJournal();
      await journal.run('playback', () async {
        journal.record({
          'stage': 'transfer_failed',
          'category': 'audio_http_failed',
          'code': 403,
        });
        journal.record({
          'stage': 'operation_failed',
          'category': 'decoder_open_failed',
        });
        journal.record({
          'stage': 'playback_status',
          'phase': 'failed',
          'category': 'decoder_open_failed',
        });
      });
      // Keep the actual first cause at the top of the retained incident.
      final failure = (journal.snapshot()['failures'] as List).single as Map;
      expect(failure['category'], 'audio_http_failed');
      expect(failure['code'], 403);
    },
  );

  test(
    'recovered cache warnings do not classify a successful attempt as failed',
    () async {
      // Model a preserved stale cache that is successfully replaced after verification.
      final journal = DiagnosticJournal();
      await journal.run('playback', () async {
        journal.record({
          'stage': 'cache_revalidation_required',
          'category': 'cache_identity_unverified',
        });
        journal.record({'stage': 'playback_status', 'phase': 'playing'});
      });
      expect(journal.snapshot()['failures'], isEmpty);
      expect(
        (journal.snapshot()['operations'] as List).single['status'],
        'finished',
      );
    },
  );

  test('overlapping attempts retain their own asynchronous events', () async {
    // Hold the earlier request while another request fails independently.
    final release = Completer<void>();
    // Use generated environment labels without any account or machine details.
    final journal = DiagnosticJournal(
      platform: 'windows',
      buildRevision: 'abcdef1',
    );
    // Keep the old operation alive across the newer operation's failure.
    final earlier = journal.run('playback', () async {
      await release.future;
      journal.record({
        'stage': 'recording_source_bound',
        'identity_bound': true,
      });
    });
    await expectLater(
      journal.run('playback', () async {
        journal.record({
          'stage': 'playback_status',
          'phase': 'resolving_source',
        });
        throw const ProofFailure('audio_destination_rejected');
      }),
      throwsA(isA<ProofFailure>()),
    );
    release.complete();
    await earlier;
    // Inspect only the generated trace to check that events were not reassigned.
    final report = journal.snapshot();
    // Locate the late event from the first operation.
    final bound = (report['events'] as List).cast<Map>().singleWhere(
      (event) => event['stage'] == 'recording_source_bound',
    );
    // Keep the second operation's cause even after the first one finishes.
    final failure = (report['failures'] as List).single as Map;
    expect(bound['operation_id'], 'playback-1');
    expect(failure['operation_id'], 'playback-2');
    expect(failure['area'], 'cdn_destination');
    expect(failure['category'], 'audio_destination_rejected');
  });

  test('unknown page fields, strings and account identifiers never enter reports', () {
    // Fill every untrusted position with generated private-looking values.
    final journal = DiagnosticJournal(
      platform: 'private-machine',
      buildRevision: 'private-build',
    );
    journal.record({
      'stage': 'waiting_source',
      'url': 'https://private.example/temporary',
      'title': 'Private title',
      'userId': 123456789,
      'cookie': 'Private cookie',
      'category': 'private_category',
      'adapter_sha256': 'private_digest',
      'counts': {
        'modernRows': 12,
        'userId': 123456789,
        'privateField': 'Private value',
      },
      'controls': {'playingControls': 1, 'privateField': 987654321},
      'source_shape': {'https': true, 'host': 'private.example'},
    });
    // Unknown stage names themselves may contain page/private content.
    journal.record({'stage': 'Private stage', 'elapsed_ms': double.infinity});
    // Serialize exactly the artifact that a diagnostic collector would receive.
    final text = jsonEncode(journal.snapshot());
    expect(text.toLowerCase(), isNot(contains('private')));
    expect(text, isNot(contains('123456789')));
    expect(text, isNot(contains('987654321')));
    expect(text, contains('modernRows'));
    expect(text, contains('unrecognized_stage'));
    expect(text, contains('omitted_fields'));
  });

  test('background spam cannot erase the last failure and output stays bounded', () async {
    // Generate repeated request failures without any filesystem or browser access.
    final journal = DiagnosticJournal();
    for (var attempt = 0; attempt < 20; attempt++) {
      await expectLater(
        journal.run('playback', () async {
          journal.record({'stage': 'waiting_source', 'requests': attempt});
          throw const ProofFailure('audio_http_failed', code: 403);
        }),
        throwsA(isA<ProofFailure>()),
      );
    }
    // Overwrite the ordinary event ring with unrelated sync events.
    for (var event = 0; event < 2000; event++) {
      journal.record({'stage': 'scan_pagination', 'elapsed_ms': event});
    }
    // Keep bounded failure snapshots independently from the recent event ring.
    final report = journal.snapshot();
    expect((report['events'] as List).length, lessThanOrEqualTo(64));
    expect((report['failures'] as List).length, lessThanOrEqualTo(4));
    expect((report['failures'] as List).last['category'], 'audio_http_failed');
    expect(jsonEncode(report).length, lessThanOrEqualTo(196608));
  });

  test('slow diagnostic writes cannot block recording or playback operations', () async {
    // Isolate the generated journal from application state and private profiles.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-diagnostics-slow-',
    );
    // Hold one asynchronous write while more events arrive.
    final release = Completer<void>();
    // Signal when the deliberately stalled writer has started.
    final started = Completer<void>();
    // Count physical writes to prove that no per-event queue accumulates.
    var writes = 0;
    // Keep playback-independent state in a bounded in-memory journal.
    final journal = DiagnosticJournal();
    // Substitute only the file sink; no user data or real network is involved.
    final store = DiagnosticStore(
      directory,
      journal,
      write: (name, contents) async {
        writes++;
        // Delay only the first write to expose queueing mistakes.
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      },
    );
    try {
      journal.record({'stage': 'finding_track'});
      store.changed();
      // Force one write while leaving the ordinary event path synchronous and cheap.
      final flushing = store.flush();
      await started.future;
      for (var event = 0; event < 500; event++) {
        journal.record({'stage': 'waiting_source', 'requests': event});
        store.changed();
      }
      await journal
          .run('playback', () async {
            journal.record({'stage': 'playback_status', 'phase': 'playing'});
          })
          .timeout(const Duration(seconds: 1));
      expect(writes, 1);
      release.complete();
      await flushing;
      await store.close();
      expect(writes, lessThanOrEqualTo(6));
    } finally {
      // Release the generated sink even when a bounded assertion fails.
      if (!release.isCompleted) release.complete();
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  test('failures survive restart and corrupt diagnostic files do not break startup', () async {
    // Keep both simulated app runs inside a generated report-only directory.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-diagnostics-restart-',
    );
    // Create one known failure and persist its safe evidence.
    final first = DiagnosticJournal();
    // Use the real bounded asynchronous file store.
    final firstStore = DiagnosticStore(directory, first);
    try {
      first.record({
        'stage': 'adapter_loaded',
        'adapter_sha256': List.filled(64, 'a').join(),
      });
      await expectLater(
        first.run('playback', () async {
          throw const ProofFailure('audio_http_failed', code: 403);
        }),
        throwsA(isA<ProofFailure>()),
      );
      firstStore.changed();
      await firstStore.close();
      // Restore only previously sanitized diagnostic evidence into a new run.
      final second = DiagnosticJournal();
      // Construct the same store as an ordinary application restart.
      final secondStore = DiagnosticStore(directory, second);
      await secondStore.ready;
      expect(
        (second.snapshot()['failures'] as List).single['category'],
        'audio_http_failed',
      );
      expect(
        (second.snapshot()['failures'] as List).single['adapter_sha256'],
        List.filled(64, 'a').join(),
      );
      expect(
        (second.snapshot()['failures'] as List).single['updatedAt'],
        isA<String>(),
      );
      await secondStore.close();
      await File('${directory.path}/diagnostics.json')
          .writeAsString('{broken generated JSON');
      // A damaged optional report must not prevent the application from starting.
      final thirdStore = DiagnosticStore(directory, DiagnosticJournal());
      await thirdStore.ready;
      await thirdStore.close();
    } finally {
      await firstStore.close();
      await directory.delete(recursive: true);
    }
  });
}
