import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';

import 'controller_ports_test.dart' show PortablePlayback;
import 'support/fixture_provider.dart';

/// Mark only generated alternate identities as observed in the provider listing.
class ListedAlternatesProvider extends FixtureProvider {
  /// Keep the selected historical identity outside the generated current list.
  @override
  int? libraryPosition(String id) => id == '17_1' ? null : 1;
}

/// Diagnose metadata lookalikes without treating them as recording identity proof.
void main() {
  test('named diagnostic locates only supplied music metadata and reports ambiguity without exposing catalog text', () async {
    // Keep the user-supplied lookup independent of list ordering and current selection.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-named-report-',
    );
    // Include two versions to prove metadata is never enough for automatic substitution.
    final store = LibraryStore(directory)
      ..merge(const [
        Track('17_1', 'Тестовая песня', 'Тестовый артист', 60),
        Track('17_2', 'Тестовая песня', 'Тестовый артист', 120),
      ]);
    // Enable only the ordinary fixed control boundary with a silent engine.
    final player = PortablePlayback();
    // Keep provider lookup completely local to generated listing positions.
    final controller = AppController(
      store,
      playbackPlayer: player,
      musicProvider: ListedAlternatesProvider(),
      decodeAudio: (_) async => 60,
      enableLocalControls: true,
      diagnosticStore: DiagnosticStore.memory(),
    );
    try {
      await File('${directory.path}/control.json').writeAsString(
        jsonEncode({
          'command': 'inspect-recording',
          'nonce': '00000000-0000-4000-8000-000000000004',
          'title': 'Тестовая песня',
          'artist': 'ТЕСТОВЫЙ АРТИСТ',
        }),
      );
      // Wait for a real poll acknowledgement rather than relying on one timer turn.
      final reportFile = File('${directory.path}/named-recording-status.json');
      // Bound a missing-control regression without opening a media device.
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (!reportFile.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(reportFile.existsSync(), true);
      // Accept only counts and selection flags in the generated diagnostic result.
      final report = jsonDecode(reportFile.readAsStringSync()) as Map;
      expect(report['catalog_matches'], 2);
      expect(report['listed_matches'], 1);
      expect(report['selection_matches'], false);
      expect(report['ambiguous'], true);
      expect(controller.current, isNull);
      expect(player.opened, isEmpty);
      expect(report.toString(), isNot(contains('Тестовая')));
      expect(report.toString(), isNot(contains('17_')));
    } finally {
      await controller.shutdown();
      await directory.delete(recursive: true);
    }
  });

  test('passive report counts listed metadata alternatives without switching recordings or exposing text', () async {
    // Isolate all generated catalog data from normal application storage.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-selection-report-',
    );
    // Keep one old selection and three deliberately different same-title alternatives.
    final store = LibraryStore(directory)
      ..merge(const [
        Track('17_1', 'Тестовая песня', 'Тестовый артист', 60),
        Track('17_2', 'Тестовая песня', 'Тестовый артист', 60),
        Track('17_3', 'Тестовая песня', 'Тестовый артист', 120),
        Track('17_4', 'Тестовая песня', 'Other', 60),
      ]);
    // Keep report generation independent of native devices and external requests.
    final controller = AppController(
      store,
      playbackPlayer: PortablePlayback(),
      musicProvider: ListedAlternatesProvider(),
      decodeAudio: (_) async => 60,
      diagnosticStore: DiagnosticStore.memory(),
    );
    controller.queue.replace([const QueueEntry('17_1')], 0);
    try {
      await controller.writeDiagnosticReport(
        '00000000-0000-4000-8000-000000000001',
      );
      // Require numeric evidence without publishing track names, identities or choosing a substitute.
      final context =
          (controller.diagnostics.snapshot()['events'] as List).last as Map;
      expect(context['selection_listed'], false);
      expect(context['same_title_listed'], 3);
      expect(context['same_artist_title_listed'], 2);
      expect(context['same_metadata_duration_listed'], 1);
      expect(controller.current!.id, '17_1');
      expect(context.toString(), isNot(contains('Тестовый артист')));
      expect(context.toString(), isNot(contains('17_1')));
    } finally {
      await controller.shutdown();
      await directory.delete(recursive: true);
    }
  });
}
