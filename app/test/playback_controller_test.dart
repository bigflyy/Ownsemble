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
}
