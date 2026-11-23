// Real check of plan 10 G4c on live uploads: the real app, real VK, muted,
// off-screen. TEST ACCOUNT ONLY, read-only on VK here: the live uploads
// were added for G4 by tool/g4_live_songs.dart (the user agreed, removed
// after) and their keys are in .local/v2-test/g4-live-added.json.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test \
//       integration_test/lyrics_fit_live_test.dart -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json \
//       --dart-define=OWNSEMBLE_LIVE=20,87
//
// The app runs on a copy of the library ("<data dir>-live", replaced on
// every run) with no stored audio, lyrics or fits; the aligner model is
// linked in from .local/v2-test/fit-model/ (a hard link, no download).
// Per live upload: it plays (decoded); the Lyrics place shows the studio
// song's words as another version: words only, no Timing stepper, a click
// does not seek; Fit to recording saves the song and fits; then the lines
// are timed, the heading says fitted, a click seeks to a fitted start;
// "Show words only" goes back to words. The fitted starts (numbers only)
// are written to <copy>/fit-live.json in the bench's shape, for
// experiments/f2-timing/score_bench_fit.py. Prints counts and times only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');
const liveIndexes = String.fromEnvironment('OWNSEMBLE_LIVE');
const modelName = 'mms_fa.int8.onnx';

// ignore: avoid_print
void say(String line) => print(line);

int rssMb() => ProcessInfo.currentRss ~/ (1 << 20);

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

  testWidgets('live uploads: another version as words, fit, timed, undo', (
    tester,
  ) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(liveIndexes, isNotEmpty, reason: 'pass OWNSEMBLE_LIVE');
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
    final added = (jsonDecode(
      File(p.join(testDir, 'g4-live-added.json')).readAsStringSync(),
    ) as Map).cast<String, String>();
    final wanted = [
      for (final index in liveIndexes.split(','))
        (index: index, key: added[index]!),
    ];

    final copy = Directory('$dataDir-live');
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
    expect(keptModel.existsSync(), isTrue, reason: 'the model is kept there');
    final copyModel = p.join(copy.path, 'models', modelName);
    Directory(p.dirname(copyModel)).createSync(recursive: true);
    final linked = await Process.run('cmd', [
      '/c',
      'mklink',
      '/H',
      p.windows.normalize(copyModel),
      p.windows.normalize(keptModel.path),
    ]);
    expect(linked.exitCode, 0, reason: '${linked.stderr}');

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

    String credit() =>
        tester.widget<Text>(find.byKey(const ValueKey('lyrics-credit'))).data!;

    final rows = <Map<String, Object?>>[];
    for (final (:index, :key) in wanted) {
      final song = library.all.firstWhere(
        (t) => t.source == TrackSource.vk && t.inLibrary && t.sourceKey == key,
        orElse: () => fail('live upload #$index is not in the library'),
      );
      final timings = <PlayTiming>[];
      final listening = player.timings.listen(timings.add);
      await playback.playFrom([song], 0);
      await waitUntil(tester, () => timings.isNotEmpty, what: 'the sound');
      await listening.cancel();
      expect(timings.last.ok, isTrue, reason: 'error ${timings.last.error}');
      expect(timings.last.sampleRate, isNotNull, reason: 'mpv decoded it');

      if (library.view.kind != ViewKind.lyrics) {
        await tester.tap(find.byKey(const ValueKey('lyrics')).first);
        await tester.pump();
      }
      await waitUntil(
        tester,
        () =>
            lyrics.state is LyricsShown &&
            !(lyrics.state as LyricsShown).refreshing,
        timeout: const Duration(seconds: 40),
        what: 'lyrics for #$index',
      );
      await tester.pump(const Duration(milliseconds: 400));
      final shown = (lyrics.state as LyricsShown).lyrics;
      final other = lyrics.otherVersionOf(shown);
      say(
        '#$index (${song.durationSec} s): ${shown.source}, '
        '${shown.lines.length} lines, another version: '
        '${other == null ? 'no' : '$other s'}',
      );
      expect(other, isNotNull, reason: 'the studio song is another length');
      expect(shown.timed, isTrue, reason: 'timed, so it can be fitted');
      expect(credit(), contains('another version'));
      expect(find.byKey(const ValueKey('lyrics-timed')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-offset')), findsNothing);
      final firstLine = shown.lines.indexWhere((l) => !l.isGap);
      final before = player.position;
      await tester.tap(find.text(shown.lines[firstLine].text).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        (player.position - before).inMilliseconds.abs(),
        lessThan(3000),
        reason: 'a click on words does not seek',
      );

      final memoryBefore = rssMb();
      var peak = memoryBefore;
      final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final now = rssMb();
        if (now > peak) peak = now;
      });
      final clock = Stopwatch()..start();
      await tester.tap(find.byKey(const ValueKey('lyrics-fit')));
      await tester.pump();
      await waitUntil(
        tester,
        () =>
            fitter.job == null &&
            lyrics.fitFor(shown) != null &&
            find.byKey(const ValueKey('lyrics-fit')).evaluate().isEmpty,
        timeout: const Duration(minutes: 20),
        what: 'the fit of #$index',
      );
      sampler.cancel();
      await tester.pump(const Duration(seconds: 1));
      final fit = lyrics.fitFor(shown)!;
      final row = <String, Object?>{
        'index': index,
        'key': key,
        'seconds': song.durationSec,
        'otherVersionDiff': other,
        'fit': {
          'ms': clock.elapsedMilliseconds,
          'fits': fit.fits,
          'sure': fit.sureShare,
          'memoryMB': {'before': memoryBefore, 'peak': peak, 'after': rssMb()},
        },
      };
      rows.add(row);
      say(
        '#$index fit in ${clock.elapsedMilliseconds} ms: fits ${fit.fits}, '
        'sure ${fit.sureShare.toStringAsFixed(2)}; memory $memoryBefore -> '
        '$peak -> ${rssMb()} MB (debug)',
      );
      if (!fit.fits) {
        expect(credit(), contains('do not fit'));
        expect(find.byKey(const ValueKey('lyrics-timed')), findsNothing);
        continue;
      }
      final fitted = lyrics.timedOf(shown);
      row['starts'] = {
        'source': [for (final l in shown.lines) l.startMs],
        'fitted': [for (final l in fitted.lines) l.startMs],
        'gap': [for (final l in shown.lines) l.isGap],
      };
      expect(fitted.timed, isTrue);
      expect(credit(), contains('fitted to this recording'));
      expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics-offset')), findsOneWidget);

      // A click on a fitted line ahead jumps to its fitted start (paused,
      // so only the jump can bring it there).
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
        '#$index clicked line $target: at ${player.position.inMilliseconds}'
        ' ms, fitted $targetMs, source ${shown.lines[target].startMs}',
      );
      await playback.playOrPause();

      // Undo: words only again.
      await tester.tap(find.byKey(const ValueKey('lyrics-fitted')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Show words only'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-unfit')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(lyrics.fitFor(shown), isNull);
      expect(find.byKey(const ValueKey('lyrics-timed')), findsNothing);
      expect(credit(), contains('Fit them to this recording'));
      await player.stop();
    }

    File(p.join(copy.path, 'fit-live.json')).writeAsStringSync(
      jsonEncode({
        'fitLive': {'songs': rows},
      }),
    );
    expect(tester.takeException(), isNull);
  });
}
