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
// mouse and keyboard stay untouched. Prints counts only: no titles or links.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const sessionFile = String.fromEnvironment('OWNSEMBLE_SESSION');

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

  testWidgets('the app works the way the user uses it', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    final copyDir = '$dataDir-acceptance';
    final fakeKey = prepareCopy(dataDir, copyDir);
    await app.main([
      '--data-dir',
      copyDir,
      '--vk-session',
      sessionFile,
      '--muted',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    library = screen.library;
    player = screen.player;
    sync = screen.sync!;
    final progressSeen = <SyncStage>{};
    sync.addListener(() {
      if (sync.progress case final progress?) progressSeen.add(progress.stage);
    });
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    expect(library.all, isNotEmpty);

    // The app syncs itself on start, in the background, with progress. The
    // made-up song is marked gone and kept; every real song stays.
    await waitUntil(
      tester,
      () => sync.lastOutcome != null,
      timeout: const Duration(seconds: 60),
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

    // Every song: a click starts sound and the loaded audio has the song's
    // listed length (so it is this song, not another one). Songs VK blocks
    // must fail quickly with a message.
    var played = 0;
    var blocked = 0;
    var serverErrors = 0;
    var goneNotStored = 0;
    final problems = <String>[];
    for (final (index, track) in library.all.indexed) {
      final timing = await playByTap(tester, track, label: 'song #$index');
      if (track.id == fakeSong.id) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('song-${track.id}')),
            matching: find.text('gone from VK'),
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
        } else if (timing.error!.contains('no stream') &&
            timing.toSoundMs < 5000) {
          blocked++;
        } else if (timing.error!.contains('VK audio server') &&
            timing.toSoundMs < 5000) {
          // VK's own server failed; the app must say so quickly.
          serverErrors++;
        } else {
          problems.add('song #$index: ${timing.error}');
        }
        continue;
      }
      // mpv estimates a stream's length from its bitrate, so allow 3% (at
      // least 3 s); another song would almost always be far off.
      final length = await loadedLength(tester);
      final tolerance = max(3.0, track.durationSec * 0.03);
      if (length == null || (length - track.durationSec).abs() > tolerance) {
        problems.add(
          'song #$index: loaded audio is ${length?.round()} s, '
          'list says ${track.durationSec} s',
        );
        continue;
      }
      if (player.current?.id != track.id || !player.playing.value) {
        problems.add('song #$index: not the current, playing song');
        continue;
      }
      played++;
    }
    // ignore: avoid_print
    print(
      'songs: ${library.all.length}, played with matching length: $played, '
      'blocked by VK (failed fast): $blocked, '
      'VK server errors (failed fast): $serverErrors, '
      'gone from VK and not stored (failed fast): $goneNotStored, '
      'problems: ${problems.length}',
    );
    expect(problems, isEmpty);
    expect(goneNotStored, 1);

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

    // Sync now right after the start sync finds nothing new and leaves the
    // library as it is.
    final before = library.all;
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
    expect(again.result!.changedLibrary, isFalse);
    expect(identical(library.all, before), isTrue, reason: 'not reloaded');
    expect(find.textContaining('no changes'), findsOneWidget);

    await player.stop();
  });
}
