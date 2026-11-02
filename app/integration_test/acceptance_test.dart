// Acceptance test: runs the real app on the real test library (VK test
// account, real mpv playback, muted) and uses it the way the user does, with
// taps and key presses delivered inside the app. Run before every handover:
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test -d windows \
//       --dart-define=OWNSEMBLE_DATA=<data dir> \
//       --dart-define=OWNSEMBLE_SESSION=<session file>
//
// The app runs on a fresh copy of the data folder ("<data dir>-acceptance"),
// with one made-up song the VK library does not have, so the start sync must
// mark exactly that song gone; the data folder itself is never written.
//
// The background window opens off-screen without focus, so the user's screen,
// mouse and keyboard stay untouched. Prints counts and the titles of songs that
// failed, never links.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/play_queue.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/playback/stream_proxy.dart' show ProxyRequestLog;
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/storage/cover_store.dart';
import 'package:ownsemble/ui/cover_tile.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const sessionFile = String.fromEnvironment('OWNSEMBLE_SESSION');

/// OWNSEMBLE_QUICK=true plays only the first songs instead of every song,
/// for iterating on the test; never for the check before a handover.
const quick = bool.fromEnvironment('OWNSEMBLE_QUICK');

/// OWNSEMBLE_MPV_LOG=true writes mpv's log (links removed) to mpv.log in the
/// copied data folder, for finding playback problems.
const mpvLog = bool.fromEnvironment('OWNSEMBLE_MPV_LOG');

/// Song key of the made-up song put into the copy: no such song exists on VK.
const fakeAudioId = '999999999';

/// Copies [from] (library and stored audio) into a fresh [to] and adds one
/// made-up song to its VK source. Returns that song's key.
String prepareCopy(String from, String to) {
  final target = Directory(to);
  if (target.existsSync()) target.deleteSync(recursive: true);
  target.createSync(recursive: true);
  // VACUUM INTO makes a consistent copy even while another app has the
  // library open.
  final source = sqlite3.open(
    p.join(from, 'library.db'),
    mode: OpenMode.readOnly,
  );
  source.execute('VACUUM INTO ?', [p.join(to, 'library.db')]);
  source.close();
  final cache = Directory(p.join(from, 'cache'));
  if (cache.existsSync()) {
    Directory(p.join(to, 'cache')).createSync();
    for (final file in cache.listSync().whereType<File>()) {
      file.copySync(p.join(to, 'cache', p.basename(file.path)));
    }
  }
  final store = LibraryStore.open(p.join(to, 'library.db'));
  try {
    // The VK source of a library migrated from the gate build has no account
    // until its first sync, so the owner id comes from the songs' keys.
    final vk = store.sources().firstWhere((s) => s.kind == TrackSource.vk);
    final owner = store.trackKeys(vk.id).keys.first.split('_').first;
    final key = '${owner}_$fakeAudioId';
    store.upsertAll(vk.id, [
      NewTrack(
        sourceKey: key,
        artist: 'Проверка',
        title: 'Песня, которой нет в VK',
        durationSec: 180,
        addedAt: 0,
      ),
    ]);
    return key;
  } finally {
    store.close();
  }
}

/// How a song is named in this test's output.
String songName(Track track) => '${track.artist} - ${track.title}';

/// How many decoded images of [size] logical pixels are on screen.
int shownCovers(double size) => find
    .byWidgetPredicate(
      (widget) =>
          widget is RawImage && widget.image != null && widget.width == size,
    )
    .evaluate()
    .length;

/// Number of History entries in the library of [dataDir].
int _historyLength(String dataDir) {
  final store = LibraryStore.open(p.join(dataDir, 'library.db'));
  try {
    return store.history(limit: 1 << 30).length;
  } finally {
    store.close();
  }
}

/// The VK access key of every song in the library at [dir].
Map<String, String?> accessKeys(String dir) {
  final db = sqlite3.open(p.join(dir, 'library.db'), mode: OpenMode.readOnly);
  try {
    return {
      for (final row in db.select('SELECT source_key, access_key FROM tracks'))
        row['source_key'] as String: row['access_key'] as String?,
    };
  } finally {
    db.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LibraryController library;
  late PlayerService player;
  late SyncController sync;

  /// Pumps frames until [condition] holds; fails after [timeout].
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
    String what = 'condition',
  }) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > timeout) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  /// Scrolls [track] into view and taps its row, like a mouse click.
  Future<void> tapSong(WidgetTester tester, Track track) async {
    final index = library.visible.indexWhere((t) => t.id == track.id);
    expect(index, isNonNegative, reason: 'song is in the visible list');
    library.scroll.jumpTo(
      (index * rowHeight).clamp(0, library.scroll.position.maxScrollExtent),
    );
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('song-${track.id}')));
    await tester.pump();
  }

  /// Taps [track] and waits for that play request's result.
  Future<PlayTiming> playByTap(
    WidgetTester tester,
    Track track, {
    String label = 'song',
  }) async {
    final result = player.timings.first;
    await tapSong(tester, track);
    PlayTiming? timing;
    unawaited(result.then((t) => timing = t));
    await waitUntil(
      tester,
      () => timing != null,
      timeout: const Duration(seconds: 25),
      what: 'play result of $label',
    );
    return timing!;
  }

  /// Length of the file mpv has loaded, in seconds. For streams mpv knows it
  /// shortly after sound starts, so this waits up to 3 s for it.
  Future<double?> loadedLength(WidgetTester tester) async {
    final mpv = player.player.platform as NativePlayer;
    for (var i = 0; i < 30; i++) {
      final length = double.tryParse(await mpv.getProperty('duration'));
      if (length != null && length > 0) return length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    return null;
  }

  /// Moves through the whole list so every song's cover is asked for, the way
  /// scrolling by hand does, then checks they were stored and are shown. The
  /// copied data folder starts without covers, so these are real downloads.
  Future<List<Track>> checkCovers(
    WidgetTester tester,
    CoverStore covers,
  ) async {
    final clock = Stopwatch()..start();
    final withCover = library.all.where((t) => t.coverUrl != null).toList();
    final position = library.scroll.position;
    // Right after a sync the list may not be laid out yet, and this scan
    // would end after one screen.
    await waitUntil(
      tester,
      () => position.maxScrollExtent > 0,
      what: 'the song list laid out',
    );
    final screen = position.viewportDimension;
    final songs = library.visible;
    for (var offset = 0.0; ; offset += screen) {
      final target = min(offset, position.maxScrollExtent);
      library.scroll.jumpTo(target);
      await tester.pump();
      final first = (target / rowHeight).floor();
      final last = min(((target + screen) / rowHeight).ceil(), songs.length);
      final onScreen = songs
          .sublist(first, last)
          .where((t) => t.coverUrl != null);
      await waitUntil(
        tester,
        () => onScreen.every(
          (t) =>
              t.smallCovers.any((url) => covers.storedPath(url) != null) ||
              t.smallCovers.every(covers.isUnavailable),
        ),
        timeout: const Duration(seconds: 30),
        what: 'covers of the rows on screen',
      );
      if (target >= position.maxScrollExtent) break;
    }
    final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    final missing = withCover
        .where((t) => !t.smallCovers.any((u) => covers.storedPath(u) != null))
        .toList();
    final otherSize = withCover
        .where(
          (t) => covers.storedPath(t.coverUrl!) == null && !missing.contains(t),
        )
        .toList();
    final stored = withCover.length - missing.length;
    // ignore: avoid_print
    print(
      'covers: $stored of ${withCover.length} stored in $seconds s, '
      '${library.all.length - withCover.length} songs without a cover show '
      'stand-ins; ${otherSize.length} came from another size because VK '
      'lacks the small one: ${otherSize.map(songName).join('; ')}; VK did not '
      'serve ${missing.length}: ${missing.map(songName).join('; ')}',
    );
    expect(
      missing.length,
      lessThanOrEqualTo(withCover.length ~/ 10),
      reason: 'a few covers may be missing on VK, not many',
    );
    // VK's generic placeholder is never used as a cover.
    for (final track in library.all) {
      if (track.album?.trim().isEmpty ?? true) {
        expect(track.coverUrl, isNull);
      }
    }

    // The rows at the top really show bitmaps, and a restart still knows the
    // covers without the network.
    library.scroll.jumpTo(0);
    await tester.pump();
    final shownOnTop = songs
        .take((screen / rowHeight).floor())
        .where(
          (t) => t.coverUrl != null && covers.storedPath(t.coverUrl!) != null,
        )
        .length;
    await waitUntil(
      tester,
      () => shownCovers(44) >= shownOnTop,
      timeout: const Duration(seconds: 5),
      what: 'stored covers shown in the rows',
    );
    expect(shownOnTop, greaterThan(0));
    final restarted = CoverStore(dataDir: '$dataDir-acceptance');
    await restarted.load();
    expect(restarted.storedCount, covers.storedCount);
    restarted.close();
    return missing;
  }

  testWidgets('the app works the way the user uses it', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    final copyDir = '$dataDir-acceptance';
    final fakeKey = prepareCopy(dataDir, copyDir);
    // The copied library keeps the History of whoever used it before (the
    // user plays the same library), so only entries added now are counted.
    final historyBefore = _historyLength(copyDir);
    // The test's own layout, whatever the user last chose in that library.
    final copied = LibraryStore.open(p.join(copyDir, 'library.db'));
    ShellSettings(
      read: copied.readSetting,
      write: copied.writeSetting,
    ).dockTo(PlayerDock.bottom);
    copied.close();
    await app.main([
      '--data-dir',
      copyDir,
      '--vk-session',
      sessionFile,
      '--muted',
      if (mpvLog) '--mpv-log',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    library = screen.library;
    player = screen.player;
    final playback = screen.playback;
    sync = screen.sync!;
    // Every song that starts playing must get a History entry.
    var soundStarts = 0;
    player.timings.listen((timing) {
      if (timing.ok) soundStarts++;
    });
    final progressSeen = <SyncStage>{};
    sync.addListener(() {
      if (sync.progress case final progress?) progressSeen.add(progress.stage);
    });
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    expect(library.all, isNotEmpty);

    // The app syncs itself on start, in the background, with progress. The
    // made-up song is marked gone and kept; every real song stays. On a slow
    // line one VK page can take 30 s and a dropped request is sent again,
    // so the wait is long.
    await waitUntil(
      tester,
      () => sync.lastOutcome != null,
      timeout: const Duration(minutes: 4),
      what: 'start sync',
    );
    await tester.pump();
    final startSync = sync.lastOutcome!;
    expect(startSync.error, isNull, reason: 'start sync succeeds');
    final synced = startSync.result!;
    final source = sync.syncedSources.single;
    final gone = library.all.where((t) => t.isGone).toList();
    // ignore: avoid_print
    print(
      'start sync: VK listed ${synced.listed} of ${synced.declared}, '
      'added ${synced.added}, updated ${synced.updated}, '
      'newly gone ${synced.newlyGone}; library ${library.all.length} songs, '
      '${gone.length} gone; progress stages seen: '
      '${progressSeen.map((s) => s.name).join(', ')}',
    );
    expect(progressSeen, contains(SyncStage.reading));
    expect(synced.newlyGone, 1);
    expect(gone.map((t) => t.sourceKey), [fakeKey]);
    expect(source.songCount, library.all.length);
    expect(source.goneCount, 1);
    expect(source.lastSyncError, isNull);
    expect(find.textContaining('1 gone from VK'), findsOneWidget);
    final fakeSong = gone.single;

    final covers = CoverScope.maybeOf(
      tester.element(find.byType(LibraryScreen)),
    )!;
    final missingCovers = await checkCovers(tester, covers);

    // Every song: a click starts sound and the loaded audio has the song's
    // listed length (so it is this song, not another one). Songs VK blocks
    // must fail quickly with a message.
    var played = 0;
    var blocked = 0;
    var serverErrors = 0;
    var goneNotStored = 0;
    final playedOk = <int>{};
    final problems = <String>[];
    // Songs that did not play, named so a failure is never just a number.
    final notPlayed = <String>[];
    var slowRetries = 0;
    for (final (index, track)
        in library.all.take(quick ? 15 : 1 << 30).indexed) {
      var timing = await playByTap(tester, track, label: 'song #$index');
      // On a congested line a stream can take longer than the player's 20 s
      // limit; a user clicks again. Only a second failure is a problem.
      if (!timing.ok && timing.error!.startsWith('no sound after 20 s')) {
        slowRetries++;
        timing = await playByTap(tester, track, label: 'song #$index again');
      }
      if (track.id == fakeSong.id) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('song-${track.id}')),
            matching: find.byKey(const ValueKey('gone-tag')),
          ),
          findsOneWidget,
          reason: 'the gone song is marked in the list',
        );
      }
      if (!timing.ok) {
        if (track.isGone &&
            timing.error!.contains('gone from VK') &&
            timing.toSoundMs < 5000) {
          goneNotStored++;
          notPlayed.add('gone, not stored: ${songName(track)}');
        } else if (timing.error!.contains('unavailable on VK') &&
            timing.toSoundMs < 5000) {
          await waitUntil(
            tester,
            () => find
                .textContaining('Cannot play: the artist or their rep')
                .evaluate()
                .isNotEmpty,
            what: 'the message for a withdrawn song',
          );
          blocked++;
          notPlayed.add('withdrawn on VK: ${songName(track)}');
        } else if (timing.error!.contains("VK's server is not delivering") &&
            timing.toSoundMs < 5000) {
          // VK's own server failed; the app must say so quickly.
          serverErrors++;
          notPlayed.add('VK server error: ${songName(track)}');
        } else {
          problems.add('${songName(track)}: ${timing.error}');
        }
        continue;
      }
      // Checked first: if the test stalls, the song ends and auto-advance
      // moves on, and the length below would be another song's.
      if (player.current?.id != track.id || !player.playing.value) {
        problems.add('${songName(track)}: not the current, playing song');
        continue;
      }
      // mpv estimates a stream's length from its bitrate, so allow 3% (at
      // least 3 s); another song would almost always be far off.
      final length = await loadedLength(tester);
      final tolerance = max(3.0, track.durationSec * 0.03);
      if (length == null || (length - track.durationSec).abs() > tolerance) {
        problems.add(
          '${songName(track)}: loaded audio is ${length?.round()} s, '
          'list says ${track.durationSec} s',
        );
        continue;
      }
      // That song's own file is broken: a seek must reach the official
      // release too.
      if (track.title == 'Вуаля') {
        await playback.seek(const Duration(seconds: 150));
        await waitUntil(
          tester,
          () => player.position >= const Duration(seconds: 151),
          timeout: const Duration(seconds: 20),
          what: 'seek in the song playing from its release',
        );
      }
      played++;
      playedOk.add(track.id);
    }
    // ignore: avoid_print
    print(
      'songs: ${library.all.length}, played with matching length: $played, '
      'blocked by VK (failed fast): $blocked, '
      'VK server errors (failed fast): $serverErrors, '
      'gone from VK and not stored (failed fast): $goneNotStored, '
      'retried after no sound in 20 s (slow line): $slowRetries, '
      'problems: ${problems.length}',
    );
    // ignore: avoid_print
    print('not played: ${notPlayed.isEmpty ? 'none' : notPlayed.join('; ')}');
    expect(problems, isEmpty);
    if (!quick) expect(goneNotStored, 1);
    // This copy's file is broken on VK's audio server (always 504): it plays
    // from the official release, which is the same recording.
    if (!quick) {
      final voila = library.all.firstWhere((t) => t.title == 'Вуаля');
      expect(playedOk, contains(voila.id), reason: 'plays from its release');
    }

    // Clicking the playing song pauses it; clicking it again resumes.
    final song = library.all.firstWhere((t) => t.isCached);
    expect((await playByTap(tester, song)).ok, isTrue);
    await tapSong(tester, song);
    await waitUntil(tester, () => !player.playing.value, what: 'pause');
    // mpv reports the audio already in the output buffer once more (about
    // 0.1 s), then the position must stand still.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final pausedAt = player.player.state.position;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(player.player.state.position, pausedAt, reason: 'stays paused');
    await tapSong(tester, song);
    await waitUntil(tester, () => player.playing.value, what: 'resume');

    // Ctrl+F after clicking a song focuses search; typing filters with
    // matches inside words; Enter plays the first result; Esc clears.
    final field = find.byType(TextField);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
      reason: 'Ctrl+F focuses search',
    );
    // A query from inside a title whose first result is not the song that
    // is playing (Enter on that one would pause it instead).
    late Track target;
    for (final candidate in library.all.where(
      (t) => t.title.length >= 5 && !t.isGone,
    )) {
      await tester.enterText(field, candidate.title.substring(1, 5));
      await tester.pump();
      target = candidate;
      if (library.visible.first.id != player.current?.id) break;
    }
    expect(library.visible.map((t) => t.id), contains(target.id));
    expect(library.visible.length, lessThan(library.all.length));
    final first = library.visible.first;
    final result = player.timings.first;
    await tester.testTextInput.receiveAction(TextInputAction.done);
    PlayTiming? enterTiming;
    unawaited(result.then((t) => enterTiming = t));
    await waitUntil(tester, () => enterTiming != null, what: 'Enter plays');
    expect(enterTiming!.ok, isTrue);
    expect(player.current?.id, first.id, reason: 'Enter plays first result');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(library.searchText.text, isEmpty, reason: 'Esc clears search');
    expect(library.visible.length, library.all.length);

    // Player controls on real playback, used through the player bar.
    Future<PlayTiming> waitForTiming(
      Future<PlayTiming> result,
      String what, {
      Duration timeout = const Duration(seconds: 25),
    }) async {
      PlayTiming? timing;
      unawaited(result.then((t) => timing = t));
      await waitUntil(
        tester,
        () => timing != null,
        timeout: timeout,
        what: what,
      );
      return timing!;
    }

    Future<PlayTiming> tapForTiming(String key) async {
      final result = player.timings.first;
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      return waitForTiming(result, 'play result of $key');
    }

    /// Clicks the seek bar at [fraction] of its length, like a mouse click.
    Future<void> tapSeekAt(double fraction) async {
      final bar = tester.getRect(find.byKey(const ValueKey('seek')));
      // The track is inset by the handle's overlay radius (12 px) per side.
      final x = bar.left + 12 + (bar.width - 24) * fraction;
      await tester.tapAt(Offset(x, bar.center.dy));
      await tester.pump();
    }

    // A seek in a stream waits for VK to send audio from the new place.
    // On 2026-10-30 at night VK sent 256 KB in 3 to 42 s, so up to 60 s;
    // the measured time is printed.
    Future<void> waitForPosition(bool Function(Duration) ok, String what) =>
        waitUntil(
          tester,
          () => ok(player.position),
          timeout: const Duration(seconds: 60),
          what: what,
        );

    // A streamed song whose neighbours in the list play, long enough to seek.
    final list = library.visible;
    final i = [for (var k = 1; k + 1 < list.length; k++) k].firstWhere(
      (k) =>
          !list[k].isCached &&
          list[k].id != player.current?.id &&
          list[k].durationSec >= 60 &&
          playedOk.containsAll([list[k - 1].id, list[k].id, list[k + 1].id]),
    );
    expect((await playByTap(tester, list[i], label: 'stream song')).ok, isTrue);

    // Seek: a click at the middle of the bar moves the streamed song there
    // and it keeps playing from there.
    final length = player.duration;
    final seekRequests = <ProxyRequestLog>[];
    final seekListening = player.proxyRequests.listen(seekRequests.add);
    final seekClock = Stopwatch()..start();
    final seekStartedAt = DateTime.now();
    await tapSeekAt(0.5);
    await waitForPosition(
      (at) => (at - length * 0.5).abs() < length * 0.06,
      'seek to the middle',
    );
    final afterSeek = player.position;
    // A stream continues once mpv's new ranged request brings audio.
    await waitForPosition(
      (at) => at > afterSeek + const Duration(milliseconds: 300),
      'playing on after the seek',
    );
    final seekResumeMs = seekClock.elapsedMilliseconds;
    final seekEndedAt = DateTime.now();
    // A seek past what mpv holds must ask VK for a range; reading the song
    // up to the new place took up to 22 s (bug of 2026-10-30). A seek
    // inside what is already buffered may skip the request, and is quick.
    // The ranged request is logged when it ends, so it is checked after
    // the next song starts (below).
    bool seekRanged() => seekRequests.any(
      (r) =>
          r.fromByte != null &&
          !r.startedAt.isBefore(seekStartedAt) &&
          r.startedAt.isBefore(seekEndedAt),
    );

    // Previous after 3 s restarts the song; right after that it goes to the
    // previous song of the list; Next comes back.
    await tester.tap(find.byKey(const ValueKey('prev')));
    await tester.pump();
    await waitForPosition((at) => at < const Duration(seconds: 2), 'restart');
    expect(player.current?.id, list[i].id, reason: 'same song restarted');
    expect((await tapForTiming('prev')).ok, isTrue);
    expect(player.current?.id, list[i - 1].id, reason: 'previous song');
    expect((await tapForTiming('next')).ok, isTrue);
    expect(player.current?.id, list[i].id, reason: 'Next');

    // A song that ends moves on to the next song of the list.
    var ended = player.timings.first;
    await playback.seek(player.duration - const Duration(seconds: 2));
    final advanced = await waitForTiming(
      ended,
      'auto-advance',
      timeout: const Duration(seconds: 90),
    );
    expect(advanced.ok, isTrue);
    expect(player.current?.id, list[i + 1].id, reason: 'auto-advance');

    // Repeat one plays the same song again when it ends.
    await tester.tap(find.byKey(const ValueKey('repeat')));
    await tester.tap(find.byKey(const ValueKey('repeat')));
    await tester.pump();
    expect(playback.repeat, Repeat.one);
    ended = player.timings.first;
    await playback.seek(player.duration - const Duration(seconds: 2));
    expect(
      (await waitForTiming(
        ended,
        'repeat one',
        timeout: const Duration(seconds: 90),
      )).ok,
      isTrue,
    );
    expect(player.current?.id, list[i + 1].id, reason: 'same song again');
    await tester.tap(find.byKey(const ValueKey('repeat')));
    await tester.pump();
    expect(playback.repeat, Repeat.off);

    // Shuffle: Next picks another song of the list.
    await tester.tap(find.byKey(const ValueKey('shuffle')));
    await tester.pump();
    expect(playback.shuffle, isTrue);
    await tapForTiming('next');
    expect(player.current?.id, isNot(list[i + 1].id));
    expect(list.map((t) => t.id), contains(player.current?.id));
    await tester.tap(find.byKey(const ValueKey('shuffle')));
    await tester.pump();
    expect(playback.shuffle, isFalse);

    // Play next and Add to queue, by right click on real rows: Up next shows
    // the queued songs, one can be removed, the others play in order before
    // the list goes on. Neighbours of the stream song are known to play.
    // Shuffle may have landed on that song, and a click on the playing song
    // pauses it instead of giving a play result.
    if (player.current?.id == list[i - 1].id) {
      // ignore: avoid_print
      print('shuffle landed on the song before the queue, moving off it');
      await playByTap(tester, list[i], label: 'away from that song');
    }
    await playByTap(tester, list[i - 1], label: 'before the queue');
    Future<void> queueByMenu(Track track, String menuKey) async {
      library.scroll.jumpTo(
        (list.indexOf(track) * rowHeight).clamp(
          0,
          library.scroll.position.maxScrollExtent,
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(ValueKey('song-${track.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(menuKey)));
      await tester.pumpAndSettle();
    }

    final queuedSong = list.firstWhere(
      (t) => playedOk.contains(t.id) && !{list[i - 1], list[i]}.contains(t),
    );
    final removedSong = list.lastWhere((t) => playedOk.contains(t.id));
    await queueByMenu(queuedSong, 'menu-add-to-queue');
    await queueByMenu(removedSong, 'menu-play-next');
    expect(player.current?.id, list[i - 1].id, reason: 'playing song goes on');
    expect(
      [for (final t in playback.queue.queued) t.id],
      [removedSong.id, queuedSong.id],
    );
    // Up next in the bottom bar (the layout saved in `feel`): a button with
    // the count opens the list, and a song can be removed from it.
    expect(playback.queue.queued, hasLength(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('up-next-open')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('up-next-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queued-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queued-remove-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queued-1')), findsNothing);
    expect(find.byKey(const ValueKey('queued-0')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queued-0')), findsNothing);

    // The side panel shows the same queue with a real song on screen.
    await tester.tap(find.byKey(const ValueKey('dock-side')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queued-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock-bottom')));
    await tester.pumpAndSettle();

    ended = player.timings.first;
    await playback.seek(player.duration - const Duration(seconds: 2));
    expect(
      (await waitForTiming(
        ended,
        'queued song after the current one ends',
        timeout: const Duration(seconds: 90),
      )).ok,
      isTrue,
    );
    expect(player.current?.id, queuedSong.id, reason: 'queued song plays');
    expect(playback.queue.queued, isEmpty);
    ended = player.timings.first;
    await playback.seek(player.duration - const Duration(seconds: 2));
    expect(
      (await waitForTiming(
        ended,
        'the list after the queue',
        timeout: const Duration(seconds: 90),
      )).ok,
      isTrue,
    );
    expect(player.current?.id, list[i].id, reason: 'the list goes on');
    // ignore: avoid_print
    print('Queue: Play next, Add to queue, remove, order all ok');

    // The time label switches between total and remaining time. (The song
    // shuffle picked may be one VK blocks; then a known good one is used.)
    if (!player.currentLoaded) {
      expect(
        (await playByTap(tester, list[i], label: 'stream song')).ok,
        isTrue,
      );
    }
    final timeLabel = find.descendant(
      of: find.byKey(const ValueKey('time')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(timeLabel).data, isNot(startsWith('-')));
    await tester.tap(find.byKey(const ValueKey('time')));
    await tester.pump();
    expect(tester.widget<Text>(timeLabel).data, startsWith('-'));
    await tester.tap(find.byKey(const ValueKey('time')));
    await tester.pump();

    // Volume reaches mpv; mute and unmute never unmute an app started with
    // --muted.
    final mpv = player.player.platform as NativePlayer;
    final volumeBar = tester.getRect(find.byKey(const ValueKey('volume')));
    await tester.tapAt(
      Offset(
        volumeBar.left + 12 + (volumeBar.width - 24) * 0.3,
        volumeBar.center.dy,
      ),
    );
    await tester.pump();
    await waitUntil(
      tester,
      () => (playback.volume - 30).abs() < 8,
      what: 'volume slider',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final mpvVolume = double.parse(await mpv.getProperty('volume'));
    expect((mpvVolume - playback.volume).abs(), lessThan(0.6));
    // The speed gate proves a saved volume comes back after a restart.
    final savedVolume = LibraryStore.open(p.join(copyDir, 'library.db'));
    expect(
      double.parse(savedVolume.readSetting(PlaybackController.volumeSetting)!),
      closeTo(playback.volume, 0.1),
      reason: 'letting go of the slider saves the volume',
    );
    savedVolume.close();
    await tester.tap(find.byKey(const ValueKey('mute')));
    await tester.pump();
    expect(playback.mutedByUser, isTrue);
    await tester.tap(find.byKey(const ValueKey('mute')));
    await tester.pump();
    expect(playback.mutedByUser, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await mpv.getProperty('mute'), 'yes', reason: 'agent runs muted');

    // Space pauses and resumes when no text field has the focus.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(player.playing.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitUntil(tester, () => !player.playing.value, what: 'Space pause');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitUntil(tester, () => player.playing.value, what: 'Space resume');
    // In the search box Space is a character and never pauses the song.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.playing.value, isTrue, reason: 'Space in the search box');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // The player's keys on real playback: arrows seek and change the volume
    // in mpv, Ctrl+arrow changes the song, Ctrl+M mutes.
    await playback.seek(const Duration(seconds: 30));
    await waitUntil(
      tester,
      () => player.position >= const Duration(seconds: 30),
      what: 'seek before the keys',
      timeout: const Duration(seconds: 60),
    );
    final beforeKey = player.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await waitUntil(
      tester,
      () => player.position >= beforeKey + const Duration(seconds: 4),
      what: 'Right moves 5 s on',
      timeout: const Duration(seconds: 60),
    );
    final afterRight = player.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await waitUntil(
      tester,
      () => player.position <= afterRight - const Duration(seconds: 3),
      what: 'Left moves 5 s back',
      timeout: const Duration(seconds: 60),
    );
    final volumeBefore = playback.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(playback.volume, closeTo(volumeBefore + 5, 0.1));
    expect(
      double.parse(await mpv.getProperty('volume')),
      closeTo(playback.volume, 0.6),
      reason: 'Up reaches mpv',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(playback.mutedByUser, isTrue, reason: 'Ctrl+M');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(playback.mutedByUser, isFalse, reason: 'Ctrl+M again');
    final keyedFrom = player.current!.id;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitUntil(
      tester,
      () => player.current?.id != keyedFrom,
      what: 'Ctrl+Right changes the song',
    );
    // ignore: avoid_print
    print('Keys: Right, Left, Up, Down, Ctrl+M, Ctrl+Right all ok');
    // The song after that key may be one VK blocks: back to a good one.
    await waitUntil(
      tester,
      () => player.currentLoaded || !player.playing.value,
      what: 'the song after Ctrl+Right',
      timeout: const Duration(seconds: 60),
    );
    if (!player.currentLoaded) {
      expect(
        (await playByTap(tester, list[i], label: 'stream song')).ok,
        isTrue,
      );
    }

    // Type to jump on real rows: Cyrillic letters reach a song far down
    // without filtering, its row comes into view, Down walks the matches,
    // Enter plays it for real, a text with no match says so, Esc ends it.
    FocusManager.instance.primaryFocus?.unfocus();
    library.scroll.jumpTo(0);
    await tester.pump();
    Future<void> typeOnList(String text) async {
      for (final character in text.split('')) {
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyA,
          character: character,
        );
      }
      await tester.pump();
    }

    final cyrillicTitle = RegExp('^[а-яА-Я]{3}');
    final jumpTarget = library.visible.lastWhere(
      (t) =>
          playedOk.contains(t.id) &&
          t.id != player.current?.id &&
          cyrillicTitle.hasMatch(t.title),
    );
    final jumpText = jumpTarget.title.substring(0, 3);
    final rowsBefore = library.visible.length;
    await typeOnList(jumpText);
    expect(library.visible, hasLength(rowsBefore), reason: 'jump filters none');
    expect(library.jump.row, isNotNull, reason: 'letters found a row');
    final jumpMatches = library.jump.matchCount;
    for (var step = 1; step < jumpMatches; step++) {
      if (library.visible[library.jump.row!].id == jumpTarget.id) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    expect(library.visible[library.jump.row!].id, jumpTarget.id);
    expect(
      find.byKey(ValueKey('song-${jumpTarget.id}')),
      findsOneWidget,
      reason: 'the row is on screen',
    );
    final jumpResult = player.timings.first;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final jumpPlay = await waitForTiming(jumpResult, 'Enter on the jumped row');
    expect(jumpPlay.ok, isTrue);
    expect(player.current?.id, jumpTarget.id, reason: 'Enter plays the row');
    expect(library.jump.row, isNull, reason: 'Enter ends the jump');
    await typeOnList('ъъъ');
    expect(library.jump.matchCount, 0);
    expect(find.textContaining('no match'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(library.jump.isTyping, isFalse, reason: 'Esc ends the jump');
    // ignore: avoid_print
    print(
      'Type to jump: "$jumpText" reached row '
      '${library.visible.indexOf(jumpTarget)} of $rowsBefore, '
      '$jumpMatches matches, played in ${jumpPlay.toSoundMs} ms',
    );

    // Going to the playing song, on real rows: the song was started by Enter
    // from the whole list. From History a click on the player's title comes
    // back to its row, Alt+Left and Alt+Right walk the places, Ctrl+L does it
    // by key, and the scroll offset comes back too.
    final playingRow = library.visible.indexWhere(
      (t) => t.id == player.current?.id,
    );
    final rowKey = ValueKey('song-${player.current?.id}');
    library.scroll.jumpTo(0);
    await tester.pump();
    library.showView(const LibraryView(ViewKind.history));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('go-to-song')));
    await tester.pump();
    await tester.pump();
    expect(library.view, LibraryView.songs, reason: 'the title goes to Songs');
    expect(library.jump.row, playingRow, reason: 'the row is outlined');
    expect(find.byKey(rowKey), findsOneWidget, reason: 'the row is on screen');
    final revealedAt = library.scroll.offset;
    Future<void> pressAlt(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.pump();
    }

    await pressAlt(LogicalKeyboardKey.arrowLeft);
    expect(library.view, const LibraryView(ViewKind.history));
    await pressAlt(LogicalKeyboardKey.arrowLeft);
    expect(library.view, LibraryView.songs);
    expect(library.scroll.offset, 0, reason: 'the old place had the top');
    await pressAlt(LogicalKeyboardKey.arrowRight);
    await pressAlt(LogicalKeyboardKey.arrowRight);
    expect(library.scroll.offset, revealedAt, reason: 'and back to the row');
    library.showView(const LibraryView(ViewKind.history));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
    expect(library.view, LibraryView.songs, reason: 'Ctrl+L');
    expect(library.jump.row, playingRow);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // ignore: avoid_print
    print(
      'Go to the song: row $playingRow of ${library.visible.length}, '
      'title click, Ctrl+L, Alt+Left, Alt+Right ok',
    );

    // Stored audio: a streamed song is saved while it plays and then plays
    // from disk; Download keeps a song; the cache limit removes cached
    // songs but never downloaded ones.
    final storage = player.storage!;
    bool storedNow(Track t) => storage.stateOf(t).path != null;
    final streamable = [
      for (final t in list)
        if (playedOk.contains(t.id) &&
            !storedNow(t) &&
            t.id != player.current?.id)
          t,
    ];
    // The shortest songs, so a slow line still finishes them; saving and
    // downloading wait up to 5 minutes for the same reason.
    streamable.sort((a, b) => a.durationSec.compareTo(b.durationSec));
    final toCache = streamable[0];
    final toDownload = streamable[1];

    /// Watches a save of [song] the way the user sees it: the shares it
    /// goes through, and whether the row's mark filled and (when [playing])
    /// the seek bar's band moved. Returns what stops the watching.
    ({List<double> shares, bool Function() filled, VoidCallback stop})
    watchSave(WidgetTester tester, Track song, {required bool playing}) {
      final shares = <double>[];
      var filled = false;
      var bandSeen = !playing;
      void look() {
        final share = storage.savedShare(song);
        shares.add(share);
        filled =
            filled ||
            find.byKey(ValueKey('filling-${song.id}')).evaluate().isNotEmpty;
        if (playing && share > 0 && share < 1) {
          // Not tester.widget: a listener can run while a pump is under way.
          final seek =
              find.byKey(const ValueKey('seek')).evaluate().single.widget
                  as Slider;
          final band = seek.secondaryTrackValue ?? 0;
          bandSeen = bandSeen || (band > 0 && band < seek.max);
        }
      }

      storage.progress.addListener(look);
      return (
        shares: shares,
        filled: () => filled && bandSeen,
        stop: () => storage.progress.removeListener(look),
      );
    }

    final cacheClock = Stopwatch()..start();
    final cacheWatch = watchSave(tester, toCache, playing: true);
    expect(
      (await playByTap(tester, toCache, label: 'song to cache')).ok,
      isTrue,
    );
    await waitUntil(
      tester,
      () => storedNow(toCache),
      timeout: const Duration(minutes: 5),
      what: 'song saved while streaming',
    );
    cacheWatch.stop();
    expect(
      cacheWatch.shares.where((s) => s > 0 && s < 1).length,
      greaterThan(3),
      reason: 'the saved part grows along the way',
    );
    expect(
      cacheWatch.shares,
      orderedEquals([...cacheWatch.shares]..sort()),
      reason: 'the saved part only grows',
    );
    expect(
      cacheWatch.filled(),
      isTrue,
      reason: 'the row filled and the seek bar showed the saved part',
    );
    await tester.pump();
    final seekWhenSaved = tester.widget<Slider>(
      find.byKey(const ValueKey('seek')),
    );
    expect(
      seekWhenSaved.secondaryTrackValue,
      seekWhenSaved.max,
      reason: 'a stored song is saved all the way along the seek bar',
    );
    final cachedFile = storage.fileAt(storage.stateOf(toCache).path!);
    final cachedAfterMs = cacheClock.elapsedMilliseconds;
    expect(cachedFile.lengthSync(), greaterThan(100000));
    expect(storage.stateOf(toCache).pinned, isFalse, reason: 'cache only');
    expect(File('${cachedFile.path}.part').existsSync(), isFalse);
    await tester.pump();
    expect(
      find.byKey(
        ValueKey('mark-${toCache.id}-${Icons.cloud_done_outlined.codePoint}'),
      ),
      findsOneWidget,
      reason: 'the row shows the song as cached',
    );
    // Played again it comes from disk, at the cached-song speed.
    expect(
      (await playByTap(tester, toDownload, label: 'other song')).ok,
      isTrue,
    );
    final fromDisk = await playByTap(tester, toCache, label: 'cached song');
    expect(fromDisk.ok, isTrue);
    expect(fromDisk.cached, isTrue, reason: 'plays from the saved file');
    final savedLength = await loadedLength(tester);
    expect(
      (savedLength! - toCache.durationSec).abs(),
      lessThan(max(3.0, toCache.durationSec * 0.03)),
      reason: 'the saved file is the whole song',
    );

    // Download from the song's right-click menu.
    final downloadIndex = library.visible.indexWhere(
      (t) => t.id == toDownload.id,
    );
    library.scroll.jumpTo(
      (downloadIndex * rowHeight).clamp(
        0,
        library.scroll.position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('song-${toDownload.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    // On a fast line the song may have been saved while it played.
    final downloadFetches = !storedNow(toDownload);
    final downloadWatch = watchSave(tester, toDownload, playing: false);
    await tester.tap(find.byKey(const ValueKey('menu-download')));
    await tester.pump();
    await waitUntil(
      tester,
      () => storage.stateOf(toDownload).pinned,
      timeout: const Duration(minutes: 5),
      what: 'download',
    );
    downloadWatch.stop();
    if (downloadFetches) {
      expect(
        downloadWatch.shares.where((s) => s > 0 && s < 1).length,
        greaterThan(3),
        reason: 'a download shows how far it got',
      );
      expect(
        downloadWatch.filled(),
        isTrue,
        reason: 'the row filled during the download',
      );
    }
    final downloadedFile = storage.fileAt(storage.stateOf(toDownload).path!);
    expect(downloadedFile.lengthSync(), greaterThan(100000));
    await tester.pump();
    expect(
      find.byKey(
        ValueKey('mark-${toDownload.id}-${Icons.download_done.codePoint}'),
      ),
      findsOneWidget,
      reason: 'the row shows the song as downloaded',
    );

    // The player bar's button downloads the playing (cached) song at once
    // and removes the download again.
    await tester.tap(find.byKey(const ValueKey('download')));
    await tester.pump();
    expect(storage.stateOf(toCache).pinned, isTrue);
    await tester.tap(find.byKey(const ValueKey('download')));
    await tester.pump();
    expect(storage.stateOf(toCache).pinned, isFalse);

    // A cache limit of 1 byte: every cached song goes except the one
    // playing; the downloaded song and its file stay.
    final settings = LibraryStore.open(p.join(copyDir, 'library.db'));
    settings.writeSetting(AudioStorage.limitSetting, '1');
    settings.close();
    final evicted = storage.applyLimit(keep: {player.current!.id});
    await tester.pump();
    expect(storage.stateOf(toDownload).pinned, isTrue);
    expect(downloadedFile.existsSync(), isTrue);
    expect(storedNow(toCache), isTrue, reason: 'playing now, kept');
    final stillCached = library.all.where(
      (t) =>
          storedNow(t) &&
          !storage.stateOf(t).pinned &&
          t.id != player.current?.id,
    );
    expect(stillCached, isEmpty);
    // The downloaded song plays from disk.
    final offline = await playByTap(tester, toDownload, label: 'downloaded');
    expect(offline.ok && offline.cached, isTrue);
    // ignore: avoid_print
    print(
      'storage: song saved while streaming after $cachedAfterMs ms '
      '(${cachedFile.lengthSync() ~/ 1024} KB), replayed from disk in '
      '${fromDisk.toSoundMs} ms; download kept; cache limit removed '
      '${evicted.length} cached songs, kept downloads and the playing song',
    );
    // Download of the song whose own file is broken: the audio comes from
    // the official release, and from disk it is the whole song. Last here:
    // it applies the 1-byte limit again, removing the song cached above.
    if (!quick) {
      final voila = library.all.firstWhere((t) => t.title == 'Вуаля');
      expect(storedNow(voila), isFalse);
      expect(await playback.download(voila), isNull);
      final saved = await playByTap(tester, voila, label: 'downloaded Вуаля');
      expect(saved.ok && saved.cached, isTrue);
      expect(
        (await loadedLength(tester))! - voila.durationSec,
        inInclusiveRange(-3, 3),
        reason: 'the downloaded file is the whole song',
      );
    }

    // Every song that started playing is in the History, newest first.
    // The side panel downloads and shows the large cover of the song playing.
    final withLargeCover = library.all.firstWhere(
      (t) =>
          t.coverLargeUrl != null &&
          t.coverFullUrl != null &&
          t.id != player.current?.id &&
          playedOk.contains(t.id) &&
          !missingCovers.any((missing) => missing.id == t.id),
    );
    await playByTap(tester, withLargeCover, label: 'song with a large cover');
    await tester.tap(find.byKey(const ValueKey('dock-side')));
    await tester.pumpAndSettle();
    // The small cover stands in until the large one is there, so only a
    // bitmap wider than the small cover proves the large one shows.
    await waitUntil(
      tester,
      () =>
          covers.storedPath(withLargeCover.coverLargeUrl!) != null &&
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is RawImage &&
                    widget.width == 220 &&
                    (widget.image?.width ?? 0) > TrackTile.smallCoverPixels,
              )
              .evaluate()
              .isNotEmpty,
      timeout: const Duration(seconds: 20),
      what: 'the large cover in the side panel',
    );
    // ignore: avoid_print
    print('side panel: large cover downloaded and shown');

    // A click on a player's cover opens the biggest size; Esc or a click
    // closes it, and a row opens one from its menu without playing it.
    final viewer = find.byKey(const ValueKey('cover-viewer'));
    int viewerPixels() {
      final images = find.descendant(
        of: viewer,
        matching: find.byType(RawImage),
      );
      return [
        0,
        for (final element in images.evaluate())
          (element.widget as RawImage).image?.width ?? 0,
      ].reduce((a, b) => a > b ? a : b);
    }

    Future<void> closeViewerByEsc() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(viewer, findsNothing, reason: 'Esc closes the cover');
    }

    final viewerClock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('open-cover')));
    await waitUntil(
      tester,
      () => covers.storedPath(withLargeCover.coverFullUrl!) != null,
      timeout: const Duration(seconds: 20),
      what: 'the biggest cover stored',
    );
    // A smaller size shows first, so only the saved file's own width proves
    // that the biggest one is on screen.
    final fullFile = img.decodeImage(
      await File(covers.storedPath(withLargeCover.coverFullUrl!)!)
          .readAsBytes(),
    )!;
    await waitUntil(
      tester,
      () => viewerPixels() == fullFile.width,
      timeout: const Duration(seconds: 20),
      what: 'the biggest cover in the viewer',
    );
    final fullPixels = viewerPixels();
    final fullShownMs = viewerClock.elapsedMilliseconds;
    final largeFile = img.decodeImage(
      await File(covers.storedPath(withLargeCover.coverLargeUrl!)!)
          .readAsBytes(),
    )!;
    await closeViewerByEsc();

    await tester.tap(find.byKey(const ValueKey('open-cover')));
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing, reason: 'a click closes the cover');

    await tester.tap(find.byKey(const ValueKey('dock-bottom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-cover')));
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget, reason: 'the bottom bar cover opens too');
    await closeViewerByEsc();

    final rowCover = library.visible.firstWhere(
      (t) =>
          t.hasCover &&
          t.id != player.current?.id &&
          !missingCovers.any((missing) => missing.id == t.id),
    );
    library.scroll.jumpTo(
      (library.visible.indexOf(rowCover) * rowHeight).clamp(
        0,
        library.scroll.position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('song-${rowCover.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    final playingBefore = player.current?.id;
    await tester.tap(find.byKey(const ValueKey('menu-view-cover')));
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget, reason: 'View cover in a row menu');
    expect(player.current?.id, playingBefore, reason: 'looking plays nothing');
    await closeViewerByEsc();
    // ignore: avoid_print
    print(
      'cover viewer: ${withLargeCover.artist} - ${withLargeCover.title}: '
      'saved files ${largeFile.width} and ${fullFile.width} px, '
      '$fullPixels px bitmap shown in $fullShownMs ms; side panel, bottom '
      'bar and row menu open it; Esc and a click close it',
    );

    final historyStore = LibraryStore.open(p.join(copyDir, 'library.db'));
    await seekListening.cancel();
    expect(
      seekRanged() || seekResumeMs < 5000,
      isTrue,
      reason: 'stream seek took $seekResumeMs ms without a ranged request',
    );
    final history = historyStore.history(limit: 1 << 30);
    historyStore.close();
    final historyAdded = history.length - historyBefore;
    // ignore: avoid_print
    print(
      'controls: seek, previous (restart and back), next, auto-advance, '
      'repeat one, shuffle, time label, volume, mute, Space checked; '
      'stream seek: click to playing on ${seekResumeMs - 300} ms or less '
      '(${seekRanged() ? 'ranged request' : 'from buffer'}); '
      'History entries added $historyAdded for $soundStarts sound starts',
    );
    expect(historyAdded, soundStarts);
    expect(history.first.trackId, player.current?.id);

    // Sync now right after the start sync finds nothing new and leaves the
    // library as it is.
    final before = library.all;
    final keysBefore = accessKeys(copyDir);
    await tester.tap(find.byKey(const ValueKey('sync-now')));
    await tester.pump();
    expect(sync.running, isTrue, reason: 'Sync now starts a sync');
    await waitUntil(
      tester,
      () => !sync.running,
      timeout: const Duration(seconds: 60),
      what: 'Sync now',
    );
    await tester.pump();
    final again = sync.lastOutcome!;
    expect(again.error, isNull);
    // ignore: avoid_print
    print(
      'Sync now: added ${again.result!.added}, updated '
      '${again.result!.updated}, newly gone ${again.result!.newlyGone}',
    );
    expect(again.result!.added, 0);
    expect(again.result!.newlyGone, 0);
    // VK now and then gives every song a new access key, which can happen
    // during this test. Only that may count as a change here.
    final keysAfter = accessKeys(copyDir);
    final newKeys = keysAfter.keys
        .where((key) => keysAfter[key] != keysBefore[key])
        .length;
    expect(again.result!.updated, newKeys, reason: 'only new access keys');
    if (newKeys == 0) {
      expect(identical(library.all, before), isTrue, reason: 'not reloaded');
      expect(find.textContaining('no changes'), findsOneWidget);
    } else {
      // ignore: avoid_print
      print('Sync now: VK changed $newKeys access keys, nothing else');
    }

    await player.stop();
  });
}
