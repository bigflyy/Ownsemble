import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/playback_engine.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';

import 'support/fixture_provider.dart';
import 'support/ui_performance_fixture.dart';

/// Simulate acknowledged native progress without opening media or an output device.
class QueueProbePlayback extends UiBenchmarkPlayback {
  bool playing = false;
  @override
  PlaybackState get state => PlaybackState(
    playing: playing,
    position: const Duration(milliseconds: 200),
    duration: const Duration(minutes: 3),
    volume: volume,
  );
}

/// Exercise the production queue/check orchestration while replacing audio startup only.
class QueueProbeController extends AppController {
  final QueueProbePlayback playback;
  final selections = <String>[];
  int? failAtStart;
  final sizes = <int>[];
  final modes = <bool>[];
  final diagnosticFlags = <bool>[];
  QueueProbeController(super.store, this.playback)
    : super(
        enableLocalControls: true,
        playbackPlayer: playback,
        musicProvider: FixtureProvider()..connected = true,
        decodeAudio: (_) async => 180,
        diagnosticStore: DiagnosticStore.memory(),
      );

  @override
  Future<void> playCurrent({bool diagnostic = false}) async {
    selections.add(queue.current!.id);
    sizes.add(queue.entries.length);
    modes.add(queue.shuffle);
    diagnosticFlags.add(diagnostic);
    playback.playing = selections.length != failAtStart;
    if (!playback.playing) {
      store.trackError(queue.current!.id, 'music_script_failed');
    }
  }

  @override
  Future<void> stopPlayback({bool diagnostic = false}) async {
    playback.playing = false;
  }
}

void main() {
  late Directory folder;
  late MeasuredLibraryStore store;
  late QueueProbeController controller;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-queue-probe-');
    store = MeasuredLibraryStore(folder);
    seedUiPerformanceLibrary(store, 2633);
    controller = QueueProbeController(store, QueueProbePlayback());
    controller.queue.replace(const [
      QueueEntry('900000000000002_5', 55),
      QueueEntry('900000000000002_5', 56),
      QueueEntry('900000000000002_10', 57),
    ], 1);
    controller.queue.setShuffle(true, random: Random(11));
  });
  tearDown(() async {
    await controller.shutdown();
    await folder.delete(recursive: true);
  });

  Future<Map> request(WidgetTester tester, String command, int nonce) async {
    File('${folder.path}/control.json').writeAsStringSync(
      jsonEncode({
        'command': command,
        'nonce': '00000000-0000-0000-0000-${nonce.toString().padLeft(12, '0')}',
      }),
    );
    // The controller is created in setUp, so its control timer uses the real event loop.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2200)),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final report = File('${folder.path}/queue-check.json');
    expect(
      report.existsSync(),
      isTrue,
      reason: 'A fixed queue-check command must publish its safe outcome',
    );
    return jsonDecode(report.readAsStringSync()) as Map;
  }

  for (final count in [1, 2]) {
    testWidgets('sequence refuses a $count-track library without starting', (
      tester,
    ) async {
      store.db.execute(
        'DELETE FROM tracks WHERE id NOT IN (SELECT id FROM tracks LIMIT ?)',
        [count],
      );
      final original = controller.queue.toJson();
      final report = await request(tester, 'check-queue-sequence', 1);
      expect(report['passed'], isFalse);
      expect(report['category'], 'diagnostic_insufficient_tracks');
      expect(controller.selections, isEmpty);
      expect(controller.queue.toJson(), original);
    });
  }

  testWidgets(
    'sequence reports an initial failure as attempt one without advancing',
    (tester) async {
      controller.failAtStart = 1;
      final original = controller.queue.toJson();
      final report = await request(tester, 'check-queue-sequence', 1);
      expect(report['passed'], isFalse);
      expect(report['failed_attempt'], 1);
      expect(report['attempts_count'], 0);
      expect(controller.selections.length, 1);
      expect(controller.queue.toJson(), original);
    },
  );
  testWidgets('sequence refuses to interrupt existing muted playback', (
    tester,
  ) async {
    controller.playback.playing = true;
    final original = controller.queue.toJson();
    final report = await request(tester, 'check-queue-sequence', 1);
    expect(report['category'], 'diagnostic_requires_idle');
    expect(controller.selections, isEmpty);
    expect(controller.playback.playing, isTrue);
    expect(controller.queue.toJson(), original);
  });

  testWidgets(
    'fixed shuffle sequence exercises three Next starts and restores history/queue',
    (tester) async {
      final original = controller.queue.toJson();
      final report = await request(tester, 'check-queue-sequence', 1);
      expect(report['passed'], isTrue);
      expect(report['attempts_count'], 3);
      expect((report['attempts'] as List).length, 3);
      expect(controller.selections.toSet().length, 3);
      expect(controller.sizes, [2633, 2633, 2633]);
      expect(controller.diagnosticFlags, [true, true, true]);
      expect(controller.queue.toJson(), original);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 0);
      expect(report.toString(), isNot(contains('900000000000002_')));
    },
  );

  testWidgets(
    'fixed shuffle sequence stops on its first failed Next and restores queue',
    (tester) async {
      final original = controller.queue.toJson();
      controller.failAtStart = 2;
      final report = await request(tester, 'check-queue-sequence', 1);
      expect(report['passed'], isFalse);
      expect(report['category'], 'music_script_failed');
      expect(report['failed_attempt'], 2);
      expect(controller.selections.length, 2);
      expect(controller.queue.toJson(), original);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 0);
    },
  );

  testWidgets(
    'normal and shuffled startup checks preserve queue/history and select the same uncached identity',
    (tester) async {
      final original = controller.queue.toJson();
      final normal = await request(tester, 'check-queue-normal', 1);
      final shuffled = await request(tester, 'check-queue-shuffle', 2);
      expect(controller.queue.toJson(), original);
      expect(controller.selections, hasLength(2));
      expect(controller.selections.first, controller.selections.last);
      expect(controller.sizes, [2633, 2633]);
      expect(controller.modes, [false, true]);
      expect(controller.diagnosticFlags, [true, true]);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 0);
      for (final report in [normal, shuffled]) {
        expect(report['passed'], isTrue);
        expect(report['was_cached'], isFalse);
        expect(report['selected_identity_preserved'], isTrue);
        expect(report.toString(), isNot(contains('900000000000002_')));
      }
    },
  );

  testWidgets(
    'queue startup checks refuse unmuted playback without changing selection',
    (tester) async {
      await tester.runAsync(() => controller.volume(35));
      final original = controller.queue.toJson();
      final report = await request(tester, 'check-queue-shuffle', 1);
      expect(report['passed'], isFalse);
      expect(report['category'], 'diagnostic_requires_mute');
      expect(controller.selections, isEmpty);
      expect(controller.queue.toJson(), original);
    },
  );
}
