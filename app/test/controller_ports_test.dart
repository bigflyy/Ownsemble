import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/playback_engine.dart';
import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';

import 'support/fixture_provider.dart';

// An independent engine double; no native player inheritance or plugin imports.
class PortablePlayback implements PlaybackEngine {
  bool playing = false;
  Duration position = Duration.zero;
  double volume = 50;
  final opened = <String>[];
  int disposals = 0;
  final changes = StreamController<bool>.broadcast(sync: true);
  @override
  PlaybackState get state => PlaybackState(
    playing: playing,
    position: position,
    duration: const Duration(seconds: 10),
    volume: volume,
  );
  @override
  PlaybackEvents get stream => PlaybackEvents(
    playing: changes.stream,
    buffering: const Stream.empty(),
    completed: const Stream.empty(),
    position: const Stream.empty(),
    error: const Stream.empty(),
    log: const Stream.empty(),
  );
  @override
  Future<void> openLocal(String path, {bool play = true}) async {
    opened.add(path);
    position = const Duration(milliseconds: 250);
    playing = play;
    changes.add(playing);
  }

  @override
  Future<void> openStream(Uri uri, {bool play = true}) async =>
      throw StateError('unexpected network');
  @override
  Future<void> play() async {
    playing = true;
    changes.add(playing);
  }

  @override
  Future<void> pause() async {
    playing = false;
    changes.add(playing);
  }

  @override
  Future<void> stop() async {
    await pause();
    position = Duration.zero;
  }

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<bool> isPaused() async => !playing;
  @override
  Future<double?> clockSeconds() async => position.inMilliseconds / 1000;
  @override
  Future<void> dispose() async {
    disposals++;
    await changes.close();
  }
}

class PortableController extends AppController {
  final String generatedAudio;
  PortableController(
    super.store,
    PortablePlayback playback,
    FixtureProvider provider,
    this.generatedAudio,
  ) : super(
        playbackPlayer: playback,
        musicProvider: provider,
        demo: true,
        decodeAudio: (_) async => 10,
      );
  @override
  Future<CachedAudio> ensureAsset(Track track, {bool playback = false}) async =>
      CachedAudio(track.id, generatedAudio, 'generated', 1, 10);
}

class PrivateSessionProvider extends FixtureProvider {
  final calls = <String>[];
  bool active = false;
  @override
  bool get privateSignInActive => active;
  @override
  Future<void> signInPrivately() async {
    active = true;
    connected = false;
    calls.add('sign-in');
  }

  @override
  Future<void> finishPrivateSignIn() async {
    active = false;
    calls.add('finish');
  }

  @override
  Future<void> connect() async {
    calls.add('connect');
  }
}

/// Model optional read-only diagnostics without constructing a browser backend.
class DiagnosticLibraryProvider extends FixtureProvider
    implements LibraryMembershipDiagnostics {
  // Count explicit inspections independently of ordinary synchronization.
  int inspections = 0;

  /// Record the diagnostic request without returning or changing music data.
  @override
  Future<void> inspectLibraryMembership() async {
    inspections++;
  }
}

/// Model a native open failure that leaves buffering active until media unloads.
class FailingBufferingPlayback extends PortablePlayback {
  // Preserve the native buffering symptom after an unsuccessful open.
  bool waitingForAudio = false;
  // Count media unloads before startup and during failure recovery.
  int stops = 0;

  /// Report the buffering state independently of the paused state.
  @override
  PlaybackState get state => PlaybackState(
    playing: playing,
    buffering: waitingForAudio,
    position: position,
    duration: const Duration(seconds: 10),
    volume: volume,
  );

  /// Reproduce a failed open without reading or decoding a real audio file.
  @override
  Future<void> openLocal(String path, {bool play = true}) async {
    waitingForAudio = true;
    throw const ProofFailure('decoder_open_failed');
  }

  /// Clear buffering only when the media is unloaded, matching native behavior.
  @override
  Future<void> stop() async {
    stops++;
    waitingForAudio = false;
    await super.stop();
  }
}

/// Delay one failed-open cleanup acknowledgement while a newer Play succeeds.
class DelayedFailureCleanupPlayback extends PortablePlayback {
  // Signal that the old request has entered native cleanup.
  final cleanupStarted = Completer<void>();
  // Release the old native acknowledgement after the newer request finishes.
  final releaseCleanup = Completer<void>();
  // Fail only the first open so the second request can prove successful recovery.
  bool failNextOpen = true;
  // Apply native state immediately, then delay only its acknowledgement.
  bool cleanupPending = false;

  /// Suspend the first failed-open cleanup response without blocking later calls.
  Future<void> _waitForCleanup() async {
    // Leave ordinary player operations unaffected by the controlled delay.
    if (!cleanupPending) return;
    cleanupPending = false;
    cleanupStarted.complete();
    await releaseCleanup.future;
  }

  /// Fail the old request and accept the next request using generated media state.
  @override
  Future<void> openLocal(String path, {bool play = true}) async {
    // Reproduce one failed request before allowing the retry to succeed.
    if (failNextOpen) {
      failNextOpen = false;
      cleanupPending = true;
      throw const ProofFailure('decoder_open_failed');
    }
    await super.openLocal(path, play: play);
  }

  /// Apply a pause before delaying the acknowledgement of the old cleanup.
  @override
  Future<void> pause() async {
    await super.pause();
    await _waitForCleanup();
  }

  /// Apply media unload before delaying its acknowledgement.
  @override
  Future<void> stop() async {
    position = Duration.zero;
    await super.pause();
    await _waitForCleanup();
  }
}

void main() {
  test('diagnostic export retains a failed Play without contacting a private provider', () async {
    // Keep generated diagnostic files separate from the real catalog and browser session.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-controller-diagnostics-',
    );
    // Create one generated recording for a controlled native-open failure.
    final store = LibraryStore(directory);
    store.merge([const Track('17_1', 'Generated', 'Fixture', 10)]);
    // Keep the provider in private sign-in mode throughout collection.
    final provider = PrivateSessionProvider()..active = true;
    // Reproduce a failure without invoking a native player or network.
    final controller = PortableController(
      store,
      FailingBufferingPlayback(),
      provider,
      '${directory.path}/generated.mp3',
    );
    try {
      await controller.playRows(store.rows(), 0);
      // Fill the background ring after the failure to prove its evidence is retained.
      for (var event = 0; event < 100; event++) {
        controller.providerDiagnostic({
          'stage': 'metadata_read',
          'rows': 114,
          'url': 'https://private.example/temporary',
        });
      }
      await controller.writeDiagnosticReport(
        '00000000-0000-4000-8000-000000000001',
      );
      // Read only this fixture's newly generated, app-owned diagnostic artifact.
      final report = jsonDecode(
        await File('${directory.path}/diagnostics-report.json').readAsString(),
      ) as Map;
      expect(report['report_id'], '00000000-0000-4000-8000-000000000001');
      expect(
        (report['failures'] as List).single['category'],
        'decoder_open_failed',
      );
      expect(
        (report['failures'] as List).single['operation_id'],
        startsWith('playback-'),
      );
      expect(provider.calls, isEmpty);
      expect(controller.loading, isFalse);
      expect(jsonEncode(report), isNot(contains('private.example')));
    } finally {
      await controller.shutdown();
      await directory.delete(recursive: true);
    }
  });

  test(
    'late failure cleanup cannot overwrite a newer successful Play',
    () async {
      // Isolate the request race from real catalog and media files.
      final directory = await Directory.systemTemp.createTemp(
        'ownsemble-cleanup-race-',
      );
      // Store one generated recording for both requests.
      final store = LibraryStore(directory);
      store.merge([const Track('17_1', 'Generated', 'Fixture', 10)]);
      // Delay the old cleanup response while allowing the retry to finish.
      final player = DelayedFailureCleanupPlayback();
      // Exercise normal controller request ownership through an independent engine.
      final controller = PortableController(
        store,
        player,
        FixtureProvider(),
        '${directory.path}/generated.mp3',
      );
      try {
        // Start the failing request without waiting for its cleanup acknowledgement.
        final first = controller.playRows(store.rows(), 0);
        await player.cleanupStarted.future;
        await controller.playRows(store.rows(), 0);
        player.releaseCleanup.complete();
        await first;
        expect(store.rows().single.error, isNull);
        expect(player.state.playing, isTrue);
        expect(controller.loading, isFalse);
      } finally {
        // Release the fixture even if an assertion fails before ordinary shutdown.
        if (!player.releaseCleanup.isCompleted) {
          player.releaseCleanup.complete();
        }
        await controller.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );
  test('failed startup unloads media instead of leaving an endless buffering state', () async {
    // Keep this regression isolated from user files and the real media backend.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-failed-start-',
    );
    // Store one generated recording for the ordinary controller Play action.
    final store = LibraryStore(directory);
    store.merge([const Track('17_1', 'Generated', 'Fixture', 10)]);
    // Reproduce the native buffering symptom through an independent engine double.
    final player = FailingBufferingPlayback();
    // Return a generated path directly so the test needs no native media access.
    final controller = PortableController(
      store,
      player,
      FixtureProvider(),
      '${directory.path}/generated.mp3',
    );
    try {
      await controller.playRows(store.rows(), 0);
      expect(controller.loading, isFalse);
      expect(player.state.playing, isFalse);
      expect(player.state.buffering, isFalse);
      expect(player.stops, 2);
    } finally {
      await controller.shutdown();
      await directory.delete(recursive: true);
    }
  });
  test('fixed library inspection leaves catalog and playback unchanged', () async {
    // Keep this controller test isolated from the application's real catalog.
    final directory = await Directory.systemTemp.createTemp(
      'ownsemble-library-inspection-',
    );
    // Store only one generated recording to detect accidental import mutations.
    final store = LibraryStore(directory);
    store.merge([const Track('17_1', 'Generated', 'Fixture', 10)]);
    // Expose only the optional diagnostic capability to the controller.
    final provider = DiagnosticLibraryProvider();
    // Track player operations independently from the provider's inspection count.
    final player = PortablePlayback();
    // Enable the same fixed-command polling used by authorized local checks.
    final controller = AppController(
      store,
      musicProvider: provider,
      playbackPlayer: player,
      decodeAudio: (_) async => 10,
      enableLocalControls: true,
    );
    try {
      await File('${directory.path}/control.json').writeAsString(
        '{"command":"inspect-library","nonce":"12345678-1234-1234-1234-123456789abc"}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(provider.inspections, 1);
      expect(store.count, 1);
      expect(player.opened, isEmpty);
      expect(player.playing, isFalse);
    } finally {
      await controller.shutdown();
      await directory.delete(recursive: true);
    }
  });
  test(
    'scheduler leaves private sign-in alone until explicit Connect VK',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ownsemble-private-controller-',
      );
      final store = LibraryStore(directory);
      final provider = PrivateSessionProvider();
      final controller = AppController(
        store,
        musicProvider: provider,
        playbackPlayer: PortablePlayback(),
        decodeAudio: (_) async => 10,
      );
      try {
        controller.setAutoSync(true);
        await controller.signInVk();
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(provider.calls, ['sign-in']);
        await controller.connectVk();
        expect(provider.calls, ['sign-in', 'finish', 'connect']);
      } finally {
        await controller.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );

  test('shared app playback uses independent ports without native player/provider inheritance', () async {
    final directory = await Directory.systemTemp.createTemp('ownsemble-ports-');
    final store = LibraryStore(directory);
    final engine = PortablePlayback(), provider = FixtureProvider();
    final file = File('${directory.path}/generated.mp3')..writeAsBytesSync([1]);
    store.merge([const Track('1_2', 'Generated', 'Fixture', 10)]);
    final controller = PortableController(store, engine, provider, file.path);
    try {
      controller.offline = true;
      await controller.playLibrary(store.rows());
      expect(engine.opened, [file.path]);
      expect(controller.loading, isFalse);
      expect(engine.playing, isTrue);
      await controller.togglePlay();
      expect(engine.playing, isFalse);
      await controller.togglePlay();
      expect(engine.playing, isTrue);
      await controller.seek(3);
      expect(engine.position, const Duration(seconds: 3));
      await controller.toggleMute();
      expect(engine.volume, 0);
      await controller.toggleMute();
      expect(engine.volume, greaterThan(0));
      expect(provider.connected, isFalse);
      expect(store.count, 1);
    } finally {
      await controller.shutdown();
      expect(engine.disposals, 1);
      await directory.delete(recursive: true);
    }
  });
}
