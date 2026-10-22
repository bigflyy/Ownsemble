import 'package:ownsemble/platform/media_kit_playback.dart';
import 'package:ownsemble/media/local_audio.dart';

import 'support/fixture_provider.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/playback_queue.dart';
import 'package:ownsemble/ui/ownsemble_app.dart';

class ControlledPlayer extends PlatformPlayer {
  ControlledPlayer() : super(configuration: const PlayerConfiguration());
  bool failPause = false;
  Completer<void>? pauseGate;
  @override
  Future<void> pause() async {
    await pauseGate?.future;
    if (failPause) throw StateError('synthetic native failure');
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() => pause();
}

class PreparingController extends AppController {
  final preparation = Completer<CachedAudio>();
  bool requested = false;
  final failures = <String, ProofFailure>{};
  PreparingController(
    super.store,
    ControlledPlayer native, {
    super.startupTimeout,
  }) : super(
         demo: true,
         playbackPlayer: MediaKitPlayback(Player(platformPlayer: native)),
         decodeAudio: decodeLocalAudio,
         musicProvider: FixtureProvider(),
       );
  @override
  Future<CachedAudio> ensureAsset(Track track, {bool playback = false}) {
    requested = true;
    final failure = failures[track.id];
    if (failure != null) return Future.error(failure);
    return preparation.future;
  }
}

void main() {
  late Directory directory;
  late LibraryStore store;
  late ControlledPlayer native;
  late PreparingController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ownsemble-controls-');
    store = LibraryStore(directory);
    store.merge([
      const Track('1_2', 'Generated song', 'Generated artist', 180),
    ]);
    native = ControlledPlayer();
    controller = PreparingController(store, native);
  });
  tearDown(() async {
    await controller.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'library Play skips a known unavailable song without removing it',
    () async {
      store.trackError('1_2', 'audio_restricted');
      store.merge([const Track('1_3', 'Generated playable', 'Fixture', 180)]);
      final rows = store.rows()
        ..sort((a, b) => a.track.id.compareTo(b.track.id));
      final operation = controller.playLibrary(rows);
      await Future<void>.delayed(Duration.zero);
      expect(controller.current!.id, '1_3');
      expect(controller.requested, isTrue);
      expect(store.track('1_2'), isNotNull);
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_2').error,
        'audio_restricted',
      );
      await controller.stopPlayback();
      controller.preparation.completeError(const ProofFailure('cancelled'));
      await operation;
    },
  );

  test(
    'an entirely unavailable library does not start another loading loop',
    () async {
      store.trackError('1_2', 'audio_restricted');
      await controller.playLibrary(store.rows());
      expect(controller.requested, isFalse);
      expect(controller.loading, isFalse);
      expect(store.count, 1);
    },
  );

  test(
    'Library Play advances when VK reports a newly unavailable song',
    () async {
      store.merge([const Track('1_3', 'Generated playable', 'Fixture', 180)]);
      controller.failures['1_2'] = const ProofFailure('audio_restricted');
      final rows = store.rows()
        ..sort((a, b) => a.track.id.compareTo(b.track.id));
      final operation = controller.playLibrary(rows);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.current!.id, '1_3');
      expect(controller.loading, isTrue);
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_2').error,
        'audio_restricted',
      );
      await controller.stopPlayback();
      controller.preparation.completeError(const ProofFailure('cancelled'));
      await operation;
    },
  );

  test(
    'Library Play uses a saved song after a new unavailable result',
    () async {
      store.merge([
        const Track('1_3', 'Generated unknown', 'Fixture', 180),
        const Track('1_4', 'Generated cached', 'Fixture', 180),
      ]);
      store.saveAsset(
        const CachedAudio('1_4', 'generated.mp3', 'fixture', 100, 180),
      );
      controller.failures['1_2'] = const ProofFailure('audio_restricted');
      final rows = store.rows()
        ..sort((a, b) => a.track.id.compareTo(b.track.id));
      final operation = controller.playLibrary(rows);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.current!.id, '1_4');
      await controller.stopPlayback();
      controller.preparation.completeError(const ProofFailure('cancelled'));
      await operation;
    },
  );

  test(
    'Stop prevents Library Play from advancing after a late result',
    () async {
      store.merge([const Track('1_3', 'Generated next', 'Fixture', 180)]);
      final rows = store.rows()
        ..sort((a, b) => a.track.id.compareTo(b.track.id));
      final operation = controller.playLibrary(rows);
      await Future<void>.delayed(Duration.zero);
      await controller.stopPlayback();
      controller.preparation.completeError(
        const ProofFailure('audio_restricted'),
      );
      await operation;
      expect(controller.current!.id, '1_2');
      expect(controller.loading, isFalse);
      expect(controller.message, 'Playback stopped');
    },
  );

  test('loading is published before a pending native pause', () async {
    native.pauseGate = Completer<void>();
    var observed = false;
    controller.addListener(() => observed = observed || controller.loading);
    final operation = controller.playRows(store.rows(), 0);
    expect(controller.loading, isTrue);
    expect(observed, isTrue);
    native.failPause = true;
    native.pauseGate!.complete();
    await operation;
    expect(controller.loading, isFalse);
    expect(store.rows().single.error, 'operation_failed');
  });

  test('Stop cancels preparation and ignores its late failure', () async {
    final operation = controller.playRows(store.rows(), 0);
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isTrue);
    await controller.togglePlay();
    expect(controller.loading, isFalse);
    expect(controller.message, 'Playback stopped');
    controller.preparation.completeError(const ProofFailure('cancelled'));
    await operation;
    expect(controller.message, 'Playback stopped');
    expect(store.rows().single.error, isNull);
    expect(native.state.playing, isFalse);
  });

  test('ordinary pending Play expires and ignores late preparation', () async {
    await controller.shutdown();
    store = LibraryStore(directory);
    native = ControlledPlayer();
    controller = PreparingController(
      store,
      native,
      startupTimeout: const Duration(milliseconds: 100),
    );
    final operation = controller.playRows(store.rows(), 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controller.requested, isTrue);
    expect(controller.loading, isFalse);
    expect(store.rows().single.error, 'player_start_timeout');
    expect(native.state.playing, isFalse);
    final failureMessage = controller.message;
    controller.preparation.completeError(const ProofFailure('cancelled'));
    await operation;
    expect(controller.message, failureMessage);
    expect(store.rows().single.error, 'player_start_timeout');
  });

  test('source lookup never displays an empty megabyte download', () {
    controller.downloadStage = 'finding_source';
    controller.downloadBytes = 0;
    expect(controller.downloadLabel, 'Finding source');
    controller.downloadStage = 'receiving';
    expect(controller.downloadLabel, 'Waiting for audio');
    controller.downloadBytes = 1024;
    expect(controller.downloadLabel, '1 KB received');
    controller.downloadStage = 'decoding';
    expect(controller.downloadLabel, 'Validating complete audio');
  });

  test(
    'shutdown ignores a late preparation failure after the database closes',
    () async {
      final operation = controller.playRows(store.rows(), 0);
      await Future<void>.delayed(Duration.zero);
      await controller.shutdown();
      controller.preparation.completeError(const ProofFailure('cancelled'));
      await expectLater(operation, completes);
    },
  );

  testWidgets('a confirmed VK restriction is labelled before Play', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.trackError('1_2', 'audio_restricted');
    await tester.pumpWidget(OwnsembleApp(controller: controller));
    expect(find.text('Restricted in VK'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('loading keeps the main Stop button enabled', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.queue.replace([const QueueEntry('1_2')], 0);
    controller.loading = true;
    await tester.pumpWidget(OwnsembleApp(controller: controller));
    final stop = find.widgetWithIcon(FilledButton, Icons.stop_rounded);
    expect(stop, findsOneWidget);
    expect(tester.widget<FilledButton>(stop).onPressed, isNotNull);
    await tester.tap(stop);
    await tester.pump();
    expect(controller.loading, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.shutdown);
  });
}
