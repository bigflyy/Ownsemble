// Swapped-file check (Stage K): the real app, real VK, muted, off-screen, on
// one song whose VK file was swapped for another recording.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/versions_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<data dir with both accounts> \
//       --dart-define=OWNSEMBLE_SESSION=<first test account's session file> \
//       --dart-define=OWNSEMBLE_SESSION_2=<second test account's session file> \
//       --dart-define=OWNSEMBLE_TRACK=<library id of the swapped song>
//
// The app runs on a copy of the library ("<data dir>-versions", replaced on
// every run) with nothing stored, so the song streams. It plays the song,
// expects the suggested version (a file within 1 s of the listed length),
// the mark on the row, the versions dialog, a pick of VK's own file, the
// stored copy of the other recording thrown away, and a reset back to the
// suggestion. The second account is read-only: only reads and muted
// streaming. Its songs stay out of the public repo, so this file and its
// output name the song by its library id and lengths only, never a title.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const firstSession = String.fromEnvironment('OWNSEMBLE_SESSION');
const secondSession = String.fromEnvironment('OWNSEMBLE_SESSION_2');
const trackId = int.fromEnvironment('OWNSEMBLE_TRACK', defaultValue: -1);

// ignore: avoid_print
void say(String line) => print(line);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 60),
    String what = 'condition',
  }) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > timeout) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump().timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('no frame for 30 s, waiting for $what'),
      );
    }
  }

  testWidgets('a song whose VK file was swapped', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(trackId, isNot(-1), reason: 'pass OWNSEMBLE_TRACK');
    // A fresh copy of the library alone: no stored audio, so it streams.
    final copy = Directory('$dataDir-versions');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    // Brought to the current schema first, then emptied of stored audio and
    // of choices made by earlier runs.
    LibraryStore.open(p.join(copy.path, 'library.db')).close();
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    copied.execute('DELETE FROM song_versions');
    copied.close();

    await app.main([
      '--data-dir',
      copy.path,
      '--vk-session',
      firstSession,
      '--vk-session',
      secondSession,
      '--muted',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    final library = screen.library;
    final player = screen.player;
    final playback = screen.playback;
    final versions = player.versions!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await waitUntil(
      tester,
      () => !screen.sync!.running,
      timeout: const Duration(minutes: 3),
      what: 'the start sync',
    );
    final track = library.byId(trackId)!;
    say(
      'song $trackId: listed ${track.durationSec} s, '
      '${track.copies.length} other copies',
    );

    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    Future<PlayTiming> nextTiming(int before, String what) async {
      await waitUntil(
        tester,
        () => timings.length > before,
        timeout: const Duration(seconds: 60),
        what: what,
      );
      return timings.last;
    }

    Future<double?> loadedLength() async {
      final mpv = player.player.platform as NativePlayer;
      for (var i = 0; i < 30; i++) {
        final length = double.tryParse(await mpv.getProperty('duration'));
        if (length != null && length > 0) return length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      return null;
    }

    String describe(PlayTiming timing, double? length) =>
        '${timing.cached ? 'cached' : 'stream'} sound ${timing.toSoundMs} ms, '
        'file ${timing.fileSeconds?.toStringAsFixed(1)} s, mpv length '
        '${length?.toStringAsFixed(1)} s, version ${timing.version?.name}'
        '${timing.versionNews == null ? '' : ', found swapped'}';

    // 1. First play: the own file is another recording; the suggested
    // version plays instead, within 1 s of the listed length.
    var before = timings.length;
    unawaited(playback.playFrom([track], 0));
    final first = await nextTiming(before, 'the first play');
    expect(first.ok, isTrue, reason: 'error: ${first.error}');
    final firstLength = await loadedLength();
    say('first play: ${describe(first, firstLength)}');
    expect(first.versionNews, isNotNull, reason: 'the swap was found');
    expect(first.version, VersionState.suggested);
    expect((first.fileSeconds! - track.durationSec).abs(), lessThan(1.0));
    expect((firstLength! - track.durationSec).abs(), lessThan(1.5));
    final suggested = versions.choiceFor(track)!;
    say(
      'choice: ${suggested.state.name}, own file '
      '${suggested.ownSeconds.toStringAsFixed(1)} s (${suggested.ownBytes} '
      'bytes), suggested file ${suggested.fileSeconds?.toStringAsFixed(1)} s',
    );
    expect(suggested.ownSeconds - track.durationSec, greaterThan(3));
    // Mpv plays it for a while, so its save can finish.
    await waitUntil(
      tester,
      () => player.storage!.stateOf(track).path != null,
      timeout: const Duration(seconds: 60),
      what: 'the suggested version saved',
    );
    say('suggested version saved');

    // 2. The mark shows on the row and in the player; it opens the dialog.
    await tester.pump(const Duration(milliseconds: 300));
    final tags = find.byKey(ValueKey('version-tag-$trackId'));
    expect(tags, findsWidgets, reason: 'the song is marked');
    say('marks found: ${tags.evaluate().length}');
    await tester.tap(tags.first);
    await tester.pump(const Duration(milliseconds: 300));
    final ownUse = find.byKey(ValueKey('version-use-${track.sourceKey}'));
    final failed = find.textContaining("VK's search failed");
    final dialogClock = Stopwatch()..start();
    // What the dialog shows when it is slow, for the log.
    void sayDialog() => say(
      'dialog after ${dialogClock.elapsedMilliseconds} ms: open '
      '${find.textContaining('Versions of').evaluate().isNotEmpty}, '
      'searching ${find.text('Looking for versions on VK...').evaluate().isNotEmpty}, '
      'failed ${failed.evaluate().isNotEmpty}, '
      'version rows ${find.textContaining('Use this').evaluate().length + find.textContaining('In use').evaluate().length}',
    );
    try {
      await waitUntil(
        tester,
        () => ownUse.evaluate().isNotEmpty || failed.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
        what: 'the versions list',
      );
    } finally {
      sayDialog();
    }
    if (failed.evaluate().isNotEmpty) {
      final text = tester.widget<Text>(failed.first).data;
      fail('the dialog says: $text');
    }
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('version-use-'),
    );
    say('dialog lists ${rows.evaluate().length} versions');
    expect(rows.evaluate().length, greaterThanOrEqualTo(2));

    // 3. The user picks VK's own file: it plays (another length), and the
    // stored suggested file is thrown away first, since it no longer fits.
    before = timings.length;
    await tester.tap(ownUse);
    await tester.pump(const Duration(milliseconds: 300));
    final picked = await nextTiming(before, 'the play of the pick');
    final pickedLength = await loadedLength();
    say('picked VK file: ${describe(picked, pickedLength)}');
    expect(picked.ok, isTrue, reason: 'error: ${picked.error}');
    expect(picked.version, VersionState.picked);
    expect(picked.cached, isFalse, reason: 'the stored other file went');
    expect(
      (picked.fileSeconds! - suggested.ownSeconds).abs(),
      lessThan(otherRecordingAllowance),
    );
    expect(versions.choiceFor(track)!.state, VersionState.picked);
    final stored = LibraryStore.open(p.join(copy.path, 'library.db'));
    expect(stored.versionChoices()[trackId]?.state, VersionState.picked);
    stored.close();

    // 4. Back to automatic: the next play finds the swap again.
    await tester.tap(find.byKey(ValueKey('version-tag-$trackId')).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('versions-reset')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(versions.choiceFor(track), isNull);
    await player.stop();
    before = timings.length;
    // Straight to the player: the controller would pause the loaded song.
    unawaited(player.play(track));
    final again = await nextTiming(before, 'the play after the reset');
    final againLength = await loadedLength();
    say('after reset: ${describe(again, againLength)}');
    expect(again.ok, isTrue, reason: 'error: ${again.error}');
    expect(again.version, VersionState.suggested);
    expect((againLength! - track.durationSec).abs(), lessThan(1.5));
    await player.stop();
    say('versions check passed');
  });
}

/// How far two measurements of one file may differ.
const otherRecordingAllowance = 0.5;
