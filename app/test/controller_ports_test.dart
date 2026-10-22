import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/playback_engine.dart';
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

void main() {
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
