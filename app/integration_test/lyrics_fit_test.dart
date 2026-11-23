// Real check of "Fit to this recording" (plan 10 G2e): the real app, real
// VK, muted, off-screen. TEST ACCOUNT ONLY, read-only on VK: nothing is
// added, removed or changed there.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/lyrics_fit_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-fit", replaced on
// every run) with no stored audio, no lyrics and no fits, so the song
// streams and must be saved first. The model is downloaded for real from
// the GitHub release when .local/v2-test/fit-model/ has none; afterwards it
// is kept there (a hard link: no second copy on the drive) and linked into
// the next run's copy, so later runs download nothing.
//
// The song: Avicii - Waiting For Love, whose LRCLIB lines come about 7.7 s
// early (plan 10 F2, research song #121). Steps: it plays (decoded); Lyrics
// shows LRCLIB's timed lines; Fit to recording asks before the download
// (first run), downloads, saves the song, fits; the heading says fitted, the
// lines moved by about 7.7 s, the song was saved as cache (not a Download);
// a click on a fitted line jumps to its fitted start; the lit line follows
// the fitted times; "use LRCLIB's own timing" undoes it; a second fit reads
// the cached model output and takes a moment. Memory before, at the peak
// and after. Prints titles, counts and times only.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');
const modelName = 'mms_fa.int8.onnx';
const modelBytes = 355118972;

// ignore: avoid_print
void say(String line) => print(line);

int rssMb() => ProcessInfo.currentRss ~/ (1 << 20);

/// Links [from] at [to] without a second copy (NTFS hard link).
Future<void> hardLink(String from, String to) async {
  File(to).parent.createSync(recursive: true);
  // mklink takes a forward slash for a switch: backslashes only.
  final made = await Process.run('cmd', [
    '/c',
    'mklink',
    '/H',
    p.windows.normalize(to),
    p.windows.normalize(from),
  ]);
  if (made.exitCode != 0) fail('mklink /H failed: ${made.stderr}');
}

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

  testWidgets('Fit to this recording: download, save, fit, lit line, undo, '
      'cached second fit', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(
      session.toLowerCase().contains('session-2'),
      isFalse,
      reason: 'test account',
    );
    expect(
      p.basename(p.dirname(p.normalize(dataDir))),
      'v2-test',
      reason: 'a data folder directly inside .local/v2-test',
    );
    final testDir = p.dirname(p.normalize(dataDir));
    final copy = Directory('$dataDir-fit');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    for (final table in [
      'audio_files',
      'lyrics',
      'lyrics_picks',
      'lyrics_offsets',
      'lyrics_fits',
    ]) {
      final there = copied.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table],
      ).isNotEmpty;
      if (there) copied.execute('DELETE FROM $table');
    }
    copied.close();
    final keptModel = File(p.join(testDir, 'fit-model', modelName));
    final copyModel = p.join(copy.path, 'models', modelName);
    final downloadNow = !keptModel.existsSync();
    if (!downloadNow) await hardLink(keptModel.path, copyModel);

    await app.main([
      '--data-dir',
      copy.path,
      '--vk-session',
      session,
      '--muted',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    final library = screen.library;
    final player = screen.player;
    final playback = screen.playback;
    final lyrics = screen.lyrics!;
    final fitter = screen.lyricsFitter!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await screen.sync!.idle.timeout(const Duration(minutes: 5));
    await tester.pump();

    final song = library.all.firstWhere(
      (t) =>
          t.source == TrackSource.vk &&
          t.inLibrary &&
          t.artist.contains('Avicii') &&
          t.title.contains('Waiting For Love'),
      orElse: () => fail('the test account has no Avicii - Waiting For Love'),
    );
    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    await playback.playFrom([song], 0);
    await waitUntil(
      tester,
      () => timings.isNotEmpty,
      what: 'the song to sound',
    );
    expect(timings.last.ok, isTrue, reason: 'error ${timings.last.error}');
    expect(timings.last.sampleRate, isNotNull, reason: 'mpv decoded it');
    say(
      '"${song.artist} - ${song.title}": sound in '
      '${timings.last.toSoundMs} ms, cached ${timings.last.cached}',
    );

    await tester.tap(find.byKey(const ValueKey('lyrics')).first);
    await tester.pump();
    expect(library.view.kind, ViewKind.lyrics);
    await waitUntil(
      tester,
      () =>
          lyrics.state is LyricsShown &&
          (lyrics.state as LyricsShown).lyrics.timed &&
          !(lyrics.state as LyricsShown).refreshing,
      timeout: const Duration(seconds: 40),
      what: 'timed lyrics',
    );
    final shown = (lyrics.state as LyricsShown).lyrics;
    say('timed lyrics from ${shown.source}: ${shown.lines.length} lines');
    await tester.pump(const Duration(milliseconds: 400));

    // Memory while fitting: sampled in the background.
    final before = rssMb();
    var peak = before;
    final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = rssMb();
      if (now > peak) peak = now;
    });
    addTearDown(sampler.cancel);

    final fitButton = find.byKey(const ValueKey('lyrics-fit'));
    expect(fitButton, findsOneWidget);
    final stages = <String>[];
    void noteStage() {
      final stage = fitter.stageOf(lyrics.shownKey, shown.source);
      final text = stage == null ? null : fitStageText(stage);
      if (text != null && (stages.isEmpty || stages.last != text)) {
        stages.add(text);
      }
    }

    fitter.addListener(noteStage);
    final clock = Stopwatch()..start();
    await tester.tap(fitButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    if (downloadNow) {
      expect(find.byKey(const ValueKey('lyrics-fit-ask')), findsOneWidget);
      expect(find.text('Download 355 MB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-fit-ask-download')));
      await tester.pump();
    } else {
      expect(
        find.byKey(const ValueKey('lyrics-fit-ask')),
        findsNothing,
        reason: 'the model is there: no question',
      );
    }
    var downloadedMs = -1;
    var savedMs = -1;
    await waitUntil(
      tester,
      () {
        final stage = fitter.stageOf(lyrics.shownKey, shown.source);
        if (downloadedMs < 0 && stage != null && stage is! FitDownloading) {
          downloadedMs = clock.elapsedMilliseconds;
        }
        if (savedMs < 0 && stage != null && stage is FitRunning) {
          savedMs = clock.elapsedMilliseconds;
        }
        return fitter.job == null &&
            find.byKey(const ValueKey('lyrics-fitted')).evaluate().isNotEmpty;
      },
      timeout: const Duration(minutes: 15),
      what: 'the fit',
    );
    final fitMs = clock.elapsedMilliseconds;
    sampler.cancel();
    fitter.removeListener(noteStage);
    await Future<void>.delayed(const Duration(seconds: 3));
    final after = rssMb();
    say(
      'fit done in $fitMs ms (model there after $downloadedMs ms, song saved '
      'after $savedMs ms); stages: ${stages.join(' | ')}',
    );
    say('memory: before $before MB, peak $peak MB, after $after MB');

    final fit = lyrics.fitFor(shown)!;
    expect(fit.fits, isTrue);
    final fitted = lyrics.timedOf(shown);
    final moves = [
      for (var i = 0; i < shown.lines.length; i++)
        if (!shown.lines[i].isGap)
          fitted.lines[i].startMs! - shown.lines[i].startMs!,
    ]..sort();
    final median = moves[moves.length ~/ 2];
    say(
      'sure ${fit.sureShare.toStringAsFixed(2)}; lines moved median '
      '${(median / 1000).toStringAsFixed(1)} s, from '
      '${(moves.first / 1000).toStringAsFixed(1)} to '
      '${(moves.last / 1000).toStringAsFixed(1)} s',
    );
    expect(median, inInclusiveRange(6000, 9500), reason: 'about 7.7 s later');
    expect(
      find.textContaining('fitted to this recording'),
      findsWidgets,
      reason: 'the heading says so',
    );
    final state = screen.player.storage!.stateOf(song);
    expect(state.path, isNotNull, reason: 'the song was saved');
    expect(state.pinned, isFalse, reason: 'as cache, not as a Download');
    expect(
      Directory(p.join(copy.path, 'tmp')).listSync(),
      isEmpty,
      reason: 'no decoded samples left behind',
    );

    // A click on a fitted line well ahead jumps to its fitted start. The
    // song is paused first, so only the jump can bring it there (Codex
    // review: playing on could reach the window by itself).
    await playback.playOrPause();
    await tester.pump(const Duration(milliseconds: 500));
    final pausedAt = player.position.inMilliseconds;
    final target = [
      for (var i = 0; i < fitted.lines.length; i++)
        if (!fitted.lines[i].isGap &&
            fitted.lines[i].startMs! > pausedAt + 15000)
          i,
    ].first;
    final line = find.byKey(ValueKey('lyrics-line-$target'));
    await tester.ensureVisible(line);
    await tester.pump(const Duration(milliseconds: 400));
    final targetMs = fitted.lines[target].startMs!;
    await tester.tap(line);
    await waitUntil(
      tester,
      () => (player.position.inMilliseconds - targetMs).abs() <= 300,
      timeout: const Duration(seconds: 15),
      what: 'the seek to the fitted line',
    );
    say(
      'paused at $pausedAt ms, clicked line $target (fitted $targetMs ms, '
      'source ${shown.lines[target].startMs} ms): now at '
      '${player.position.inMilliseconds} ms',
    );
    expect(lyrics.timedOf(shown).lineAt(targetMs + 120), target);
    await playback.playOrPause();

    // The lit line follows the fitted times.
    int litLine() {
      for (final element
          in find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'lyrics-line-',
                    ),
              )
              .evaluate()) {
        final style = find
            .descendant(
              of: find.byWidget(element.widget),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .evaluate()
            .map((e) => (e.widget as AnimatedDefaultTextStyle).style)
            .first;
        if (style.fontWeight == FontWeight.w700) {
          final key = (element.widget.key! as ValueKey<String>).value;
          return int.parse(key.substring('lyrics-line-'.length));
        }
      }
      return -1;
    }

    final checks = <String>[];
    for (var round = 0; round < 3; round++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final at = player.position.inMilliseconds;
      final expected = fitted.lineAt(at + 120);
      final bySource = shown.lineAt(at + 120);
      final lit = litLine();
      checks.add('$at ms: lit $lit, fitted $expected, source $bySource');
      expect(
        (lit - expected).abs() <= 1,
        isTrue,
        reason: 'lit line $lit at $at ms, fitted times say $expected',
      );
    }
    say('following: ${checks.join('; ')}');

    // Undo, then a second fit from the cached model output.
    await tester.tap(find.byKey(const ValueKey('lyrics-fitted')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('lyrics-unfit')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(lyrics.fitFor(shown), isNull);
    expect(find.byKey(const ValueKey('lyrics-fit')), findsOneWidget);
    final again = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('lyrics-fit')));
    await waitUntil(
      tester,
      () =>
          fitter.job == null &&
          find.byKey(const ValueKey('lyrics-fitted')).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
      what: 'the second fit',
    );
    say('second fit (cached model output): ${again.elapsedMilliseconds} ms');
    expect(again.elapsedMilliseconds, lessThan(5000));
    expect(lyrics.timedOf(shown).lines.map((l) => l.startMs), [
      for (final l in fitted.lines) l.startMs,
    ], reason: 'the same fit');

    final perf = File(p.join(copy.path, 'perf.log'))
        .readAsLinesSync()
        .where((l) => l.contains('lyrics fit'))
        .toList();
    say('perf.log: ${perf.join(' / ')}');
    expect(tester.takeException(), isNull);

    // Keeps the downloaded model for the next run, without a second copy.
    if (downloadNow) {
      final got = File(copyModel);
      expect(got.lengthSync(), modelBytes);
      await hardLink(got.path, keptModel.path);
      say('model kept at ${keptModel.path} (hard link)');
    }
  });
}
