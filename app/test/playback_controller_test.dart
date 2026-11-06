import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/play_queue.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';

/// Player stand-in: records requests; songs in [failing] cannot play.
class FakePlayer implements PlayerService {
  final played = <int>[];
  final seeks = <Duration>[];
  final seekOffsets = <Duration>[];
  final failing = <int>{};

  /// The position each play request asked to start from.
  final startedFrom = <Duration?>[];

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
  Duration duration = const Duration(seconds: 200);
  @override
  Duration? resumeAt;

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
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    played.add(track.id);
    startedFrom.add(from);
    await holdPlay?.future;
    _current = track;
    final ok = !failing.contains(track.id);
    _loaded = ok;
    playing.value = ok;
    if (ok) resumeAt = null;
    position = from ?? Duration.zero;
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
  void restore(Track track, Duration position) {
    _current = track;
    resumeAt = position;
    this.position = position;
  }

  @override
  Future<void> seek(Duration to) async {
    seeks.add(to);
    if (resumeAt != null) {
      resumeAt = to;
      position = to;
    }
  }

  @override
  Future<void> seekBy(Duration offset) async => seekOffsets.add(offset);
  @override
  Future<void> setVolume(double volume) async => lastVolume = volume;
  @override
  Future<void> setMuted(bool mute) async => lastMuted = mute;

  @override
  AudioStorage? storage;

  /// Songs whose VK file was checked before a Download.
  final versionChecks = <int>[];

  /// When set, a version check waits for this (a slow line).
  Completer<void>? holdVersionCheck;

  @override
  Future<void> checkVersion(Track track) async {
    versionChecks.add(track.id);
    await holdVersionCheck?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// History stand-in: keeps each play as the app's History table would.
class FakePlays implements PlayLog {
  final rows = <HistoryEntry>[];

  /// The songs played, oldest first.
  List<int> get trackIds => [for (final row in rows) row.trackId];

  @override
  int beginPlay(
    int trackId, {
    required PlayStart start,
    required bool shuffle,
  }) {
    rows.add(
      HistoryEntry(
        rows.length + 1,
        trackId,
        rows.length,
        started: start,
        shuffle: shuffle,
        listenedMs: 0,
      ),
    );
    return rows.length;
  }

  @override
  void updatePlay(int playId, {required int listenedMs, PlayEnd? ended}) {
    final index = rows.indexWhere((row) => row.id == playId);
    final row = rows[index];
    rows[index] = HistoryEntry(
      row.id,
      row.trackId,
      row.playedAtMs,
      started: row.started,
      shuffle: row.shuffle,
      listenedMs: listenedMs,
      ended: ended,
    );
  }

  @override
  HistoryEntry? lastPlay() => rows.isEmpty ? null : rows.last;
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
  late FakePlays plays;
  late PlaybackController playback;

  /// The clock the controller times listening with.
  var nowMs = 0;

  setUp(() {
    player = FakePlayer();
    plays = FakePlays();
    nowMs = 0;
    playback = PlaybackController(
      player: player,
      plays: plays,
      clockMs: () => nowMs,
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
      expect(plays.trackIds, [0]);
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
    expect(plays.trackIds, [1, 2]);
  });

  test('auto-advance skips songs that cannot play', () async {
    final list = songs(5);
    player.failing.addAll({1, 2});
    await playback.playFrom(list, 0);
    player.endedController.add(null);
    await settle();
    expect(player.played, [0, 1, 2, 3]);
    expect(plays.trackIds, [0, 3]);
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

  group('play details', () {
    test(
      'a song heard to its end: picked, all of it heard, finished',
      () async {
        await playback.playFrom(songs(3), 0);
        nowMs += 200000;
        player.endedController.add(null);
        await settle();
        final first = plays.rows.first;
        expect(first.started, PlayStart.chosen);
        expect(first.shuffle, isFalse);
        expect(first.listenedMs, 200000);
        expect(first.ended, PlayEnd.finished);
        expect(plays.rows[1].started, PlayStart.auto);
        expect(plays.rows[1].ended, isNull, reason: 'still playing');
      },
    );

    test('paused time is not heard time; Next skips the song', () async {
      await playback.playFrom(songs(3), 0);
      nowMs += 10000;
      player.playing.value = false;
      nowMs += 60000;
      player.playing.value = true;
      nowMs += 5000;
      await playback.next();
      expect(plays.rows.first.listenedMs, 15000);
      expect(plays.rows.first.ended, PlayEnd.skipped);
      expect(plays.rows[1].started, PlayStart.next);
    });

    test('a pause writes the heard time at once', () async {
      await playback.playFrom(songs(3), 0);
      nowMs += 7000;
      player.playing.value = false;
      expect(plays.rows.first.listenedMs, 7000);
      expect(plays.rows.first.ended, isNull);
    });

    test('Previous, the queue and shuffle are told apart', () async {
      final list = songs(3);
      playback.toggleShuffle();
      await playback.playFrom(list, 1);
      player.position = Duration.zero;
      await playback.previous();
      await playback.addToQueue(list[2]);
      player.endedController.add(null);
      await settle();
      expect(plays.rows.map((row) => row.started), [
        PlayStart.chosen,
        PlayStart.previous,
        PlayStart.queued,
      ]);
      expect(plays.rows.map((row) => row.shuffle), [true, true, true]);
    });

    test('a song that fails to start ends the one before it', () async {
      final list = songs(3);
      player.failing.add(1);
      await playback.playFrom(list, 0);
      nowMs += 3000;
      await playback.playFrom(list, 1);
      expect(plays.rows.single.ended, PlayEnd.skipped);
      expect(plays.rows.single.listenedMs, 3000);
    });

    test('closing the app ends the play as closed', () async {
      await playback.playFrom(songs(3), 0);
      nowMs += 42000;
      playback.closePlay();
      expect(plays.rows.single.listenedMs, 42000);
      expect(plays.rows.single.ended, PlayEnd.closed);
    });

    test('a new version of the same song goes on in the same play', () async {
      final list = songs(3);
      await playback.playFrom(list, 0);
      nowMs += 4000;
      await playback.versionChanged(list[0]);
      nowMs += 6000;
      await playback.next();
      expect(plays.rows.first.listenedMs, 10000);
      expect(plays.rows, hasLength(2));
    });
  });

  group('saved volume', () {
    late Map<String, String?> saved;

    PlaybackController started() => PlaybackController(
      player: player,
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
      expect(plays.trackIds, [0, 50]);
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

  group('last song', () {
    late Map<String, String?> saved;
    late List<Track> list;
    late FakePlayer firstPlayer;
    late FakePlayer restarted;
    late FakePlays plays;

    Track? find(int id) => id < list.length ? list[id] : null;

    /// A controller over the first run's [saved] settings.
    PlaybackController run(FakePlayer onPlayer) {
      final controller = PlaybackController(
        player: onPlayer,
        plays: plays,
        readSetting: (key) => saved[key],
        writeSetting: (key, value) => saved[key] = value,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    /// The next run: a new player and everything restored.
    PlaybackController restart() {
      restarted = FakePlayer();
      return run(restarted)..restoreSession(find);
    }

    setUp(() {
      saved = {};
      plays = FakePlays();
      list = songs(5);
    });

    /// The first run plays song [index] and is [at] into it.
    Future<PlaybackController> played(int index, Duration at) async {
      final first = run(firstPlayer = FakePlayer());
      await first.playFrom(list, index);
      firstPlayer.position = at;
      return first..saveSession();
    }

    test('comes back paused at its position, nothing loaded', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      expect(restarted.current?.id, 2);
      expect(restarted.resumeAt, const Duration(seconds: 42));
      expect(restarted.playing.value, isFalse);
      expect(restarted.played, isEmpty);
      expect(second.queue.current?.id, 2);
    });

    test('Play goes on from there; History gets no second entry', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      await second.playOrPause();
      expect(restarted.played, [2]);
      expect(restarted.startedFrom, [const Duration(seconds: 42)]);
      expect(plays.trackIds, [2]);
      expect(restarted.pauseToggles, 0);
    });

    test('a play closed with the app goes on in the next run', () async {
      final first = await played(2, const Duration(seconds: 42));
      first.closePlay();
      expect(plays.rows.single.ended, PlayEnd.closed);
      final second = restart();
      await second.playOrPause();
      expect(plays.trackIds, [2]);
      expect(plays.rows.single.ended, isNull);
      await second.next();
      expect(plays.rows.first.ended, PlayEnd.skipped);
      expect(plays.trackIds, [2, 3]);
    });

    test('a second press while it starts does not start it again', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      restarted.holdPlay = Completer();
      final first = second.playOrPause();
      await second.playOrPause();
      restarted.holdPlay!.complete();
      await first;
      expect(restarted.played, [2]);
    });

    test('a click on the restored song goes on from there too', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      await second.playFrom(list, 2);
      expect(restarted.startedFrom, [const Duration(seconds: 42)]);
    });

    test('a failed start keeps the position for the next try', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      restarted.failing.add(2);
      await second.playOrPause();
      expect(restarted.resumeAt, const Duration(seconds: 42));
      restarted.failing.clear();
      await second.playOrPause();
      expect(restarted.startedFrom.last, const Duration(seconds: 42));
    });

    test('another song starts from its beginning', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      await second.playFrom(list, 4);
      expect(restarted.startedFrom, [null]);
    });

    test('Next and Previous move in the saved list', () async {
      await played(2, Duration.zero);
      final second = restart();
      await second.next();
      expect(restarted.played, [3]);
      await second.previous();
      expect(restarted.played, [3, 2]);
    });

    test('a seek before Play moves where it goes on from', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      var notified = 0;
      second.addListener(() => notified++);
      await second.seek(const Duration(seconds: 10));
      expect(notified, 1);
      await second.playOrPause();
      expect(restarted.startedFrom, [const Duration(seconds: 10)]);
    });

    test('a song near its end comes back from its start', () async {
      await played(2, const Duration(seconds: 198));
      restart();
      expect(restarted.resumeAt, Duration.zero);
    });

    test('the same song listed twice keeps its own place', () async {
      list = [...songs(3), ...songs(3)];
      final first = run(FakePlayer());
      await first.playFrom(list, 4);
      first.saveSession();
      final second = restart();
      expect(second.queue.contextIndex, 4);
      expect(second.queue.upcoming(1), [5]);
    });

    test('the queue comes back, in order, and does not start', () async {
      final first = await played(2, const Duration(seconds: 42));
      await first.addToQueue(list[4]);
      await first.addToQueue(list[0]);
      final second = restart();
      expect([for (final t in second.queue.queued) t.id], [4, 0]);
      expect(restarted.played, isEmpty);
    });

    test('a queued song goes on, then the list after it', () async {
      final first = await played(1, Duration.zero);
      await first.addToQueue(list[4]);
      await first.next();
      first.saveSession();
      final second = restart();
      expect(restarted.current?.id, 4);
      await second.next();
      expect(restarted.played, [2]);
    });

    test('a song queued after the restart waits for Play', () async {
      await played(2, const Duration(seconds: 42));
      final second = restart();
      await second.addToQueue(list[4]);
      expect(restarted.played, isEmpty);
      expect(restarted.current?.id, 2);
    });

    test('a saved song no longer in the library restores nothing', () async {
      await played(4, const Duration(seconds: 42));
      list = songs(3);
      final second = restart();
      expect(restarted.current, isNull);
      expect(second.queue.current, isNull);
    });

    test('songs gone from the list leave the saved one in place', () async {
      await played(3, Duration.zero);
      list = List.of(list);
      final gone = <int>{0, 1};
      restarted = FakePlayer();
      final second = run(restarted)
        ..restoreSession((id) => gone.contains(id) ? null : find(id));
      expect(second.queue.current?.id, 3);
      expect(second.queue.contextIndex, 1);
    });

    test('broken saved settings restore nothing', () {
      saved[PlaybackController.songSetting] = '{not json';
      final second = restart();
      expect(restarted.current, isNull);
      expect(second.queue.current, isNull);
    });

    test('a song that failed does not replace the saved one', () async {
      final first = await played(2, const Duration(seconds: 42));
      firstPlayer.failing.add(3);
      await first.playFrom(list, 3);
      first.saveSession();
      restart();
      expect(restarted.current?.id, 2);
      expect(restarted.resumeAt, const Duration(seconds: 42));
    });

    test('pausing saves the place at once', () async {
      await played(2, Duration.zero);
      firstPlayer.position = const Duration(seconds: 77);
      firstPlayer.playing.value = false;
      restart();
      expect(restarted.resumeAt, const Duration(seconds: 77));
    });

    test('while playing the place is saved every few seconds', () {
      fakeAsync((time) {
        run(firstPlayer = FakePlayer()).playFrom(list, 2);
        time.flushMicrotasks();
        firstPlayer.position = const Duration(seconds: 33);
        time.elapse(PlaybackController.saveEvery);
        restart();
        expect(restarted.resumeAt, const Duration(seconds: 33));
      });
    });

    test('a long list is written once, not at each save', () async {
      final writes = <String>[];
      final controller = PlaybackController(
        player: FakePlayer(),
        writeSetting: (key, value) => writes.add(key),
      );
      addTearDown(controller.dispose);
      await controller.playFrom(list, 0);
      controller
        ..saveSession()
        ..saveSession();
      expect(
        writes.where((key) => key == PlaybackController.listSetting),
        hasLength(1),
      );
      await controller.next();
      controller.saveSession();
      expect(
        writes.where((key) => key == PlaybackController.listSetting),
        hasLength(1),
      );
      await controller.playFrom(songs(2), 0);
      expect(
        writes.where((key) => key == PlaybackController.listSetting),
        hasLength(2),
      );
    });

    test('a new library version takes the songs over and keeps the old '
        'list saved', () async {
      final writes = <String>[];
      final controller = PlaybackController(
        player: FakePlayer(),
        writeSetting: (key, value) => writes.add(key),
      );
      addTearDown(controller.dispose);
      await controller.playFrom(list, 1);
      controller.saveSession();
      final fresh = songs(5);

      // A sync reloaded the library: the old songs must not stay alive
      // through the play list, which can hold the whole library.
      controller.refreshTracks((id) => fresh[id]);

      for (final (i, track) in controller.queue.context.indexed) {
        expect(track, same(fresh[i]), reason: 'song $i');
      }
      controller.saveSession();
      expect(
        writes.where((key) => key == PlaybackController.listSetting),
        hasLength(1),
        reason: 'the same ids in the same order are not written again',
      );
      await controller.next();
      expect(controller.queue.current, same(fresh[2]));
    });
  });

  group('download', () {
    late LibraryStore store;
    late Directory dir;
    late Track song;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ownsemble_download_');
      store = LibraryStore.open(':memory:');
      final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      store.upsertAll(vk, [
        const NewTrack(
          sourceKey: '1_1',
          artist: 'Операция Пластилин',
          title: 'Ты и я',
          durationSec: 219,
          addedAt: 1,
        ),
      ]);
      song = store.loadAll().single;
      player.storage = AudioStorage(dataDir: dir.path, store: store);
    });
    tearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });

    test('a cached song is kept at once, without asking VK', () async {
      final storage = player.storage!;
      final path = storage.relativePathFor(song);
      storage.fileAt(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(1000, 1));
      storage.recordStored(song, path, 1000);
      // A version check on a slow line never answers here.
      player.holdVersionCheck = Completer<void>();
      unawaited(playback.download(song));
      await settle();
      expect(storage.stateOf(song).pinned, isTrue);
      expect(player.versionChecks, isEmpty);
    });
  });
}
