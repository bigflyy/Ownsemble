import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';

import 'controller_ports_test.dart' show PortableController, PortablePlayback;
import 'support/fixture_provider.dart';

class PendingSequenceProvider extends FixtureProvider {
  final entered = Completer<void>();
  final source = Completer<ResolvedAudio>();
  PendingSequenceProvider() {
    connected = true;
  }
  @override
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) {
    if (!entered.isCompleted) entered.complete();
    return source.future;
  }
}

class DelayedDiagnosticStop extends PortablePlayback {
  int stops = 0;
  final cleanupEntered = Completer<void>();
  final releaseCleanup = Completer<void>();
  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
    if (stops == 4) {
      cleanupEntered.complete();
      await releaseCleanup.future;
    }
  }
}

void main() {
  late Directory folder;
  late LibraryStore store;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp(
      'ownsemble-sequence-safety-',
    );
    store = LibraryStore(folder)
      ..merge([
        const Track('17_1', 'Generated', 'Fixture', 10),
        const Track('17_2', 'Second', 'Fixture', 10),
        const Track('17_3', 'Third', 'Fixture', 10),
      ])
      ..setSetting('auto_sync', false);
  });
  tearDown(() async {
    await folder.delete(recursive: true);
  });

  test('sequence refuses a paused real listening session without finalizing or replacing it', () async {
    final player = PortablePlayback();
    final controller = PortableController(
      store,
      player,
      FixtureProvider()..connected = true,
      '${folder.path}/generated.mp3',
    );
    try {
      await controller.volume(0);
      await controller.playRows(store.rows(), 0);
      await controller.togglePlay();
      final queue = controller.queue.toJson();
      final history = store.db
          .select('SELECT * FROM plays')
          .map((r) => Map.of(r))
          .toList();
      final opened = List.of(player.opened);
      final position = player.state.position;
      await controller.checkQueueStartup(shuffled: true, sequence: true);
      final report = jsonDecode(
        File('${folder.path}/queue-check.json').readAsStringSync(),
      ) as Map;
      expect(report['category'], 'diagnostic_requires_idle');
      expect(player.opened, opened);
      expect(player.state.playing, isFalse);
      expect(player.state.position, position);
      expect(controller.queue.toJson(), queue);
      expect(
        store.db.select('SELECT * FROM plays').map((r) => Map.of(r)).toList(),
        history,
      );
      // The original paused session still resumes without a new open/history row.
      await controller.togglePlay();
      expect(player.opened, opened);
      expect(player.state.playing, isTrue);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 1);
    } finally {
      await controller.shutdown();
    }
  });

  for (final action in ['shuffle', 'repeat', 'enqueue']) {
    test(
      '$action during a check edits and persists the original queue',
      () async {
        final provider = PendingSequenceProvider();
        final controller = AppController(
          store,
          playbackPlayer: PortablePlayback(),
          musicProvider: provider,
          decodeAudio: (_) async => 10,
          diagnosticStore: DiagnosticStore.memory(),
        );
        controller.queue.replace([
          const QueueEntry('17_3', 4),
          const QueueEntry('17_3', 5),
        ], 1);
        try {
          await controller.volume(0);
          final check = controller.checkQueueStartup(
            shuffled: true,
            sequence: true,
          );
          await provider.entered.future;
          final mutation = Future<void>.sync(
            () => switch (action) {
              'shuffle' => controller.shuffle(),
              'repeat' => controller.repeat(),
              _ => controller.enqueue(store.rows().first),
            },
          );
          await Future<void>.delayed(Duration.zero);
          provider.source.completeError(
            const ProofFailure('fixture_network_disabled'),
          );
          await mutation;
          await check;
          expect(controller.queue.entries.length, action == 'enqueue' ? 3 : 2);
          expect(controller.queue.entries.take(2).map((e) => e.occurrence), [
            4,
            5,
          ]);
          if (action == 'shuffle') {
            expect(controller.queue.shuffle, isTrue);
          }
          if (action == 'repeat') {
            expect(controller.queue.repeat, QueueRepeat.all);
          }
          expect(store.setting('queue'), controller.queue.toJson());
          expect(
            store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'],
            0,
          );
        } finally {
          await controller.shutdown();
        }
      },
    );
  }

  test('a user selection during diagnostic native cleanup keeps its queue and playback', () async {
    final player = DelayedDiagnosticStop();
    final controller = PortableController(
      store,
      player,
      FixtureProvider()..connected = true,
      '${folder.path}/generated.mp3',
    );
    try {
      await controller.volume(0);
      final check = controller.checkQueueStartup(
        shuffled: true,
        sequence: true,
      );
      await player.cleanupEntered.future.timeout(const Duration(seconds: 2));
      controller.queue.replace([const QueueEntry('17_1', 92)], 0);
      final selected = controller.queue.toJson();
      await controller.playCurrent();
      final message = controller.message;
      player.releaseCleanup.complete();
      await check;
      expect(controller.queue.toJson(), selected);
      expect(controller.player.state.playing, isTrue);
      expect(controller.message, message);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 1);
    } finally {
      if (!player.releaseCleanup.isCompleted) player.releaseCleanup.complete();
      await controller.shutdown();
    }
  });

  test(
    'a newer user selection is not overwritten by diagnostic cleanup',
    () async {
      final provider = PendingSequenceProvider();
      final controller = AppController(
        store,
        playbackPlayer: PortablePlayback(),
        musicProvider: provider,
        decodeAudio: (_) async => 10,
        startupTimeout: const Duration(seconds: 2),
        diagnosticStore: DiagnosticStore.memory(),
      );
      try {
        await controller.volume(0);
        final check = controller.checkQueueStartup(
          shuffled: true,
          sequence: true,
        );
        await provider.entered.future;
        controller.queue.replace([const QueueEntry('17_1', 91)], 0);
        final selection = controller.queue.toJson();
        final play = controller.playCurrent();
        provider.source.completeError(
          const ProofFailure('fixture_network_disabled'),
        );
        await play;
        await check;
        expect(controller.queue.toJson(), selection);
        final report = jsonDecode(
          File('${folder.path}/queue-check.json').readAsStringSync(),
        ) as Map;
        expect(report['passed'], isFalse);
        expect(report['category'], 'cancelled');
        expect(report['cancel_reason'], 'selection_changed');
      } finally {
        await controller.shutdown();
      }
    },
  );

  test(
    'internal startup timeout restores the diagnostic queue without history',
    () async {
      final provider = PendingSequenceProvider();
      final controller = AppController(
        store,
        playbackPlayer: PortablePlayback(),
        musicProvider: provider,
        decodeAudio: (_) async => 10,
        startupTimeout: const Duration(milliseconds: 120),
        diagnosticStore: DiagnosticStore.memory(),
      );
      controller.queue.replace([
        const QueueEntry('17_3', 4),
        const QueueEntry('17_3', 5),
      ], 1);
      final original = controller.queue.toJson();
      try {
        await controller.volume(0);
        await controller
            .checkQueueStartup(shuffled: true, sequence: true)
            .timeout(const Duration(seconds: 2));
        final report = jsonDecode(
          File('${folder.path}/queue-check.json').readAsStringSync(),
        ) as Map;
        expect(report['passed'], isFalse);
        expect(report['category'], 'player_start_timeout');
        expect(controller.queue.toJson(), original);
        expect(controller.loading, isFalse);
        expect(controller.player.state.playing, isFalse);
        expect(
          store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'],
          0,
        );
      } finally {
        await controller.shutdown();
      }
    },
  );
}
