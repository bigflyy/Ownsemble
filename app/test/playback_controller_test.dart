import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/play_queue.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';

/// Player stand-in: records requests; songs in [failing] cannot play.
class FakePlayer implements PlayerService {
  final played = <int>[];
  final seeks = <Duration>[];
  final failing = <int>{};

  /// When set, a song keeps starting until this completes.
  Completer<void>? holdPlay;
  final endedController = StreamController<void>.broadcast(sync: true);
  int pauseToggles = 0;
  double? lastVolume;
  bool? lastMuted;
  Track? _current;
  bool _loaded = false;

  @override
  Duration position = Duration.zero;

  @override
  bool get isReady => true;
  @override
  Track? get current => _current;
  @override
  bool get currentLoaded => _loaded;
  @override
  Stream<void> get ended => endedController.stream;
  @override
  final ValueNotifier<bool> playing = ValueNotifier(false);

  @override
  Future<PlayTiming> play(Track track) async {
    played.add(track.id);
    await holdPlay?.future;
    _current = track;
    final ok = !failing.contains(track.id);
    _loaded = ok;
    playing.value = ok;
    position = Duration.zero;
    return PlayTiming(
      ok: ok,
      cached: true,
      resolveMs: 0,
      toSoundMs: 1,
      error: ok ? null : 'VK has no stream for this song',
    );
  }

  @override
  Future<void> playOrPause() async => pauseToggles++;
  @override
  Future<void> seek(Duration to) async => seeks.add(to);
  @override
  Future<void> setVolume(double volume) async => lastVolume = volume;
  @override
  Future<void> setMuted(bool mute) async => lastMuted = mute;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Track> songs(int count) => [
  for (var i = 0; i < count; i++)
    Track(
      id: i,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Исполнитель',
      title: 'Песня $i',
      durationSec: 200,
    ),
];

void main() {
  late FakePlayer player;
  late List<int> history;
  late PlaybackController playback;

  setUp(() {
    player = FakePlayer();
    history = [];
    playback = PlaybackController(
      player: player,
      recordPlay: (track) => history.add(track.id),
    );
  });
  tearDown(() => playback.dispose());

  /// Lets queued async work (auto-advance after "ended") finish.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'a click plays the song; History records only songs that play',
    () async {
      final list = songs(3);
      player.failing.add(1);
      await playback.playFrom(list, 0);
      await playback.playFrom(list, 1);
      expect(player.played, [0, 1]);
      expect(history, [0]);
    },
  );

  test('clicking the loaded song pauses or resumes it', () async {
    final list = songs(3);
    await playback.playFrom(list, 2);
    await playback.playFrom(list, 2);
    expect(player.played, [2]);
    expect(player.pauseToggles, 1);
  });

  test('a song that ends moves on in its list and stops at the end', () async {
    final list = songs(3);
    await playback.playFrom(list, 1);
    player.endedController.add(null);
    await settle();
    player.endedController.add(null);
    await settle();
    expect(player.played, [1, 2]);
    expect(history, [1, 2]);
  });

  test('auto-advance skips songs that cannot play', () async {
    final list = songs(5);
    player.failing.addAll({1, 2});
    await playback.playFrom(list, 0);
    player.endedController.add(null);
    await settle();
    expect(player.played, [0, 1, 2, 3]);
    expect(history, [0, 3]);
  });

  test('skipping gives up after a limit when nothing can play', () async {
    final list = songs(60);
    player.failing.addAll({for (var i = 1; i < 60; i++) i});
    playback.cycleRepeat(); // repeat list: it would go round forever
    await playback.playFrom(list, 0);
    player.endedController.add(null);
    await settle();
    expect(player.played, hasLength(1 + PlaybackController.maxSkips));
  });

  test(
    'repeat one replays the song but does not retry a failing one',
    () async {
      final list = songs(3);
      await playback.playFrom(list, 0);
      playback
        ..cycleRepeat()
        ..cycleRepeat();
      expect(playback.repeat, Repeat.one);
      player.endedController.add(null);
      await settle();
      expect(player.played, [0, 0]);

      player.failing.add(0);
      player.endedController.add(null);
      await settle();
      expect(player.played, [0, 0, 0]);
    },
  );

  test('previous restarts after 3 s, else plays the previous song', () async {
    final list = songs(3);
    await playback.playFrom(list, 1);
    player.position = const Duration(seconds: 10);
    await playback.previous();
    expect(player.seeks, [Duration.zero]);
    expect(player.played, [1]);
    player.position = const Duration(seconds: 1);
    await playback.previous();
    expect(player.played, [1, 0]);
  });

  test('next and previous use the list the song was started from', () async {
    final first = songs(5);
    await playback.playFrom(first, 3);
    await playback.next();
    await playback.next();
    expect(player.played, [3, 4, 0], reason: 'Next wraps');
  });

  test('a click during automatic skipping stops the skipping', () async {
    final list = songs(10);
    player.failing.addAll({1, 2, 3, 4, 5, 6, 7, 8});
    await playback.playFrom(list, 0);
    player.endedController.add(null);
    // The skip loop runs one song per microtask turn; click right away.
    await playback.playFrom(list, 9);
    await settle();
    await settle();
    expect(player.played.last, 9);
    expect(player.played.where((id) => id == 9), hasLength(1));
    expect(player.played.length, lessThan(10));
  });

  group('saved volume', () {
    late Map<String, String?> saved;

    PlaybackController started() => PlaybackController(
      player: player,
      recordPlay: (_) {},
      readSetting: (key) => saved[key],
      writeSetting: (key, value) => saved[key] = value,
    );

    setUp(() => saved = {});

    test('with nothing saved the volume is full and not muted', () {
      final fresh = started();
      addTearDown(fresh.dispose);
      expect(fresh.volume, 100);
      expect(fresh.mutedByUser, isFalse);
    });

    test('the volume and mute survive a restart', () async {
      final first = started();
      await first.setVolume(35);
      first.saveVolume();
      await first.toggleMute();
      first.dispose();

      final second = started();
      addTearDown(second.dispose);
      expect(second.volume, 35);
      expect(second.mutedByUser, isTrue);
    });

    test('moving the slider does not write until it is let go', () async {
      final first = started();
      addTearDown(first.dispose);
      await first.setVolume(35);
      await first.setVolume(36);
      expect(saved, isEmpty);
      first.saveVolume();
      expect(double.parse(saved[PlaybackController.volumeSetting]!), 36);
    });

    test('unmuting by the slider is saved too', () async {
      final first = started();
      await first.toggleMute();
      await first.setVolume(20);
      first.saveVolume();
      first.dispose();

      final second = started();
      addTearDown(second.dispose);
      expect(second.mutedByUser, isFalse);
    });

    test('a saved value out of range or unreadable is not used', () {
      saved[PlaybackController.volumeSetting] = '500';
      final loud = started();
      addTearDown(loud.dispose);
      expect(loud.volume, 100);

      saved[PlaybackController.volumeSetting] = 'loud';
      final unreadable = started();
      addTearDown(unreadable.dispose);
      expect(unreadable.volume, 100);
    });
  });

  test('moving the volume unmutes; mute is passed to the player', () async {
    await playback.toggleMute();
    expect(player.lastMuted, isTrue);
    expect(playback.mutedByUser, isTrue);
    await playback.setVolume(40);
    expect(player.lastMuted, isFalse);
    expect(player.lastVolume, 40);
    expect(playback.mutedByUser, isFalse);
  });

  test('shuffle, repeat and the time label notify the UI', () {
    var notified = 0;
    playback.addListener(() => notified++);
    playback
      ..toggleShuffle()
      ..cycleRepeat()
      ..toggleRemaining();
    expect(notified, 3);
    expect(playback.shuffle, isTrue);
    expect(playback.repeat, Repeat.list);
    expect(playback.showRemaining, isTrue);
  });

  group('the queue', () {
    final queued = Track(
      id: 50,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Исполнитель',
      title: 'В очереди',
      durationSec: 200,
    );

    test('with a song playing it waits for that song to end', () async {
      await playback.playFrom(songs(3), 0);
      await playback.addToQueue(queued);
      expect(player.played, [0]);
      player.endedController.add(null);
      await settle();
      expect(player.played, [0, 50]);
      expect(history, [0, 50]);
    });

    test('with a song paused it still waits', () async {
      await playback.playFrom(songs(3), 0);
      await playback.playOrPause();
      await playback.playNext(queued);
      expect(player.played, [0]);
    });

    test('with nothing started it plays at once', () async {
      await playback.addToQueue(queued);
      expect(player.played, [50]);
      expect(playback.queue.queued, isEmpty);
    });

    test('after the list ended it plays at once', () async {
      await playback.playFrom(songs(2), 1);
      player.endedController.add(null);
      await settle();
      await playback.addToQueue(queued);
      expect(player.played, [1, 50]);
    });

    // Found while writing the tests: after the list ended, resuming its last
    // song left the app "idle", so queueing a song cut the playing one off.
    test('a last song resumed after the list ended is not cut off', () async {
      await playback.playFrom(songs(2), 1);
      player.playing.value = false;
      player.endedController.add(null);
      await settle();
      player.playing.value = true;
      await playback.addToQueue(queued);
      expect(player.played, [1]);
      expect(playback.queue.queued, hasLength(1));
    });

    test(
      'a last song moved back after the list ended is not cut off',
      () async {
        await playback.playFrom(songs(2), 1);
        player.playing.value = false;
        player.endedController.add(null);
        await settle();
        await playback.seek(Duration.zero);
        await playback.addToQueue(queued);
        expect(player.played, [1]);
      },
    );

    test('after a song failed to start it plays at once', () async {
      player.failing.add(0);
      await playback.playFrom(songs(2), 0);
      await playback.playNext(queued);
      expect(player.played, [0, 50]);
    });

    test('while a song is starting it waits', () async {
      final slow = Completer<void>();
      player.holdPlay = slow;
      final starting = playback.playFrom(songs(3), 0);
      await playback.addToQueue(queued);
      slow.complete();
      await starting;
      expect(player.played, [0]);
      expect(playback.queue.queued, hasLength(1));
    });

    test(
      'a queued song that cannot play is skipped, also on repeat one',
      () async {
        final second = Track(
          id: 51,
          sourceId: 1,
          source: TrackSource.vk,
          artist: 'Исполнитель',
          title: 'Вторая',
          durationSec: 200,
        );
        player.failing.add(50);
        await playback.playFrom(songs(3), 0);
        await playback.addToQueue(queued);
        await playback.addToQueue(second);
        playback
          ..cycleRepeat()
          ..cycleRepeat();
        expect(playback.repeat, Repeat.one);
        player.endedController.add(null);
        await settle();
        await settle();
        expect(player.played, [0, 50, 51]);
      },
    );

    test('Next plays the queued song; removing one notifies the UI', () async {
      await playback.playFrom(songs(3), 0);
      await playback.addToQueue(queued);
      await playback.next();
      expect(player.played, [0, 50]);
      await playback.addToQueue(queued);
      var notified = 0;
      playback.addListener(() => notified++);
      playback.removeQueued(0);
      expect(notified, 1);
      expect(playback.queue.queued, isEmpty);
    });

    test('picking a queued song plays it now', () async {
      await playback.playFrom(songs(3), 0);
      await playback.addToQueue(queued);
      await playback.playQueued(0);
      expect(player.played, [0, 50]);
      expect(playback.queue.queued, isEmpty);
      expect(playback.queue.upcoming(5), [1, 2]);
    });
  });

  group('choices kept between runs', () {
    late Map<String, String?> saved;

    /// A controller reading and writing [saved], as the app's settings do.
    PlaybackController restart() {
      final controller = PlaybackController(
        player: FakePlayer(),
        recordPlay: (_) {},
        readSetting: (key) => saved[key],
        writeSetting: (key, value) => saved[key] = value,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    setUp(() => saved = {});

    test('shuffle, repeat and the time display survive a restart', () {
      restart()
        ..toggleShuffle()
        ..cycleRepeat()
        ..cycleRepeat()
        ..toggleRemaining();
      final second = restart();
      expect(second.shuffle, isTrue);
      expect(second.repeat, Repeat.one);
      expect(second.showRemaining, isTrue);
    });

    test('nothing saved means shuffle off, repeat off, total time', () {
      final fresh = restart();
      expect(fresh.shuffle, isFalse);
      expect(fresh.repeat, Repeat.off);
      expect(fresh.showRemaining, isFalse);
    });

    test('an unknown saved repeat mode falls back to off', () {
      saved[PlaybackController.repeatSetting] = 'sideways';
      expect(restart().repeat, Repeat.off);
    });
  });
}
