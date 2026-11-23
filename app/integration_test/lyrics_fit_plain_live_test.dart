// Real check of plan 10 H2 on plain words: the real app, real VK, muted,
// off-screen. TEST ACCOUNT ONLY, read-only on VK.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test \
//       integration_test/lyrics_fit_plain_live_test.dart -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json \
//       --dart-define=OWNSEMBLE_PLAIN=3=660306161_456239144,28=...
//
// OWNSEMBLE_PLAIN lists test songs whose best lyrics are plain words
// (index=library key; tool/check_lyrics_sources.dart found 7). The app runs
// on a copy of the library ("<data dir>-plain", replaced on every run)
// with no stored audio, lyrics or fits; the aligner model is linked in
// from .local/v2-test/fit-model/ (a hard link, no download).
// Per song: it plays (decoded); the Lyrics place shows plain words (no
// timed list, no Timing stepper) and the Fit button; Fit to recording
// saves the song and fits. When the words fit: the lines are timed, the
// heading says "timed by fitting", the stepper shows, a click seeks to a
// fitted start, the fit is still there after the song is opened again,
// and "Show words only" goes back to words. Every song's verdict is pinned
// ([expectedFits], plan 10 H4, user 2026-11-23): a song that fits when it
// should be refused, or the other way, fails the test. Around a verse
// break the lit row is checked against the fitted starts (the line before
// the break, the break itself, the line after it), and a refused song is
// still refused after it is opened again.
// Written to <copy>/plain-live.json: per song the fit's numbers and the
// fitted starts; and, for scoring against a heard truth
// (experiments/f2-timing/score_plain_fit.py), the lines' words and the
// stored song file's path under <copy>/plain-live/ (local only, never
// printed). Prints counts and times only.

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
import 'package:ownsemble/ui/lyrics_page.dart' show lyricsLeadMs;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');
const plainSongs = String.fromEnvironment('OWNSEMBLE_PLAIN');
const modelName = 'mms_fa.int8.onnx';

/// The verdict each test song must get, by its index in OWNSEMBLE_PLAIN
/// (plan 10 H2e, checked against a heard truth: the five that fit have
/// 72-100% of their heard lines within 1 s; #31's words are not of its
/// 336 s file and #48's placed lines are 28% within 1 s, so both must be
/// refused).
const expectedFits = {
  '3': true,
  '28': true,
  '94': true,
  '114': true,
  '116': true,
  '31': false,
  '48': false,
};

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

  testWidgets('plain words: button, fit, timed, click, reopen, undo', (
    tester,
  ) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(plainSongs, isNotEmpty, reason: 'pass OWNSEMBLE_PLAIN');
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
    final wanted = [
      for (final item in plainSongs.split(','))
        (index: item.split('=').first, key: item.split('=').last),
    ];
    for (final (:index, key: _) in wanted) {
      expect(
        expectedFits.containsKey(index),
        isTrue,
        reason: '#$index has no pinned verdict in expectedFits',
      );
    }

    final copy = Directory('$dataDir-plain');
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
    final words = Directory(p.join(copy.path, 'plain-live'))..createSync();

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

    Future<void> showLyricsOf(Track song, String index) async {
      if (library.view.kind != ViewKind.lyrics) {
        await tester.tap(find.byKey(const ValueKey('lyrics')).first);
        await tester.pump();
      }
      await waitUntil(
        tester,
        () =>
            lyrics.track?.sourceKey == song.sourceKey &&
            lyrics.state is LyricsShown &&
            !(lyrics.state as LyricsShown).refreshing,
        timeout: const Duration(seconds: 60),
        what: 'lyrics for #$index',
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> play(Track song) async {
      final timings = <PlayTiming>[];
      final listening = player.timings.listen(timings.add);
      await playback.playFrom([song], 0);
      await waitUntil(tester, () => timings.isNotEmpty, what: 'the sound');
      await listening.cancel();
      expect(timings.last.ok, isTrue, reason: 'error ${timings.last.error}');
      expect(timings.last.sampleRate, isNotNull, reason: 'mpv decoded it');
    }

    /// The row lit now: the line drawn bold, -1 when none is.
    int litRow(int count) {
      for (var i = 0; i < count; i++) {
        final style = find.descendant(
          of: find.byKey(ValueKey('lyrics-line-$i')),
          matching: find.byType(AnimatedDefaultTextStyle),
        );
        if (style.evaluate().isEmpty) continue;
        final weight = tester
            .widget<AnimatedDefaultTextStyle>(style.first)
            .style
            .fontWeight;
        if (weight == FontWeight.w700) return i;
      }
      return -1;
    }

    /// Paused at [ms] into the song: waits for the player to be there and
    /// for the lit row to settle; that row.
    Future<int> litAt(int ms, int count) async {
      await player.seek(Duration(milliseconds: ms));
      await waitUntil(
        tester,
        () => (player.position.inMilliseconds - ms).abs() <= 300,
        timeout: const Duration(seconds: 15),
        what: 'the seek to $ms ms',
      );
      await tester.pump(const Duration(milliseconds: 400));
      return litRow(count);
    }

    final rows = <Map<String, Object?>>[];
    var fitted = 0;
    for (final (:index, :key) in wanted) {
      final song = library.all.firstWhere(
        (t) => t.source == TrackSource.vk && t.inLibrary && t.sourceKey == key,
        orElse: () => fail('#$index is not in the library'),
      );
      await play(song);
      await showLyricsOf(song, index);
      final shown = (lyrics.state as LyricsShown).lyrics;
      say(
        '#$index (${song.durationSec} s): ${shown.source}, '
        '${shown.lines.length} lines, timed ${shown.timed}',
      );
      final row = <String, Object?>{
        'index': index,
        'key': key,
        'seconds': song.durationSec,
        'source': shown.source,
        'lines': shown.lines.length,
      };
      rows.add(row);
      if (shown.timed) {
        // The source answers timed lyrics now: not a plain-words case.
        row['skipped'] = 'timed now';
        continue;
      }
      expect(credit(), startsWith('Words only'));
      expect(find.byKey(const ValueKey('lyrics-timed')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-offset')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-fit')), findsOneWidget);

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
      row['fit'] = {
        'ms': clock.elapsedMilliseconds,
        'fits': fit.fits,
        'sure': fit.sureShare,
        'memoryMB': {'before': memoryBefore, 'peak': peak, 'after': rssMb()},
      };
      say(
        '#$index fit in ${clock.elapsedMilliseconds} ms: fits ${fit.fits}, '
        'sure ${fit.sureShare.toStringAsFixed(2)}; memory $memoryBefore -> '
        '$peak -> ${rssMb()} MB (debug)',
      );
      // For scoring against a heard truth: the words and the song file
      // (local only).
      File(p.join(words.path, '$index.json')).writeAsStringSync(
        jsonEncode({
          'index': index,
          'lines': [for (final l in shown.lines) l.text],
          'audio': fitter.storedAudioOf?.call(song),
        }),
      );
      expect(
        fit.fits,
        expectedFits[index],
        reason:
            '#$index: pinned ${expectedFits[index]! ? 'fits' : 'refused'}, '
            'got sure ${fit.sureShare.toStringAsFixed(2)}',
      );
      if (!fit.fits) {
        expect(
          find.byKey(const ValueKey('lyrics-fit-no-match')),
          findsOneWidget,
        );
        expect(credit(), contains('could not be matched'));
        // Opened again (another song, then this one): still refused, the
        // words shown, no timed list.
        final other = library.all.firstWhere(
          (t) => t.inLibrary && t.sourceKey != key,
        );
        await play(other);
        await showLyricsOf(other, 'other');
        await play(song);
        await showLyricsOf(song, index);
        expect(lyrics.fitFor(shown)?.fits, isFalse);
        expect(
          find.byKey(const ValueKey('lyrics-fit-no-match')),
          findsOneWidget,
        );
        expect(credit(), contains('could not be matched'));
        expect(find.byKey(const ValueKey('lyrics-timed')), findsNothing);
        row['reopened'] = 'still refused';
        say('#$index refused, still refused after opening it again');
        await player.stop();
        continue;
      }
      fitted++;
      final timed = lyrics.timedOf(shown);
      row['starts'] = {
        'fitted': [for (final l in timed.lines) l.startMs],
        'gap': [for (final l in shown.lines) l.isGap],
      };
      expect(timed.timed, isTrue);
      expect(credit(), contains('timed by fitting to this recording'));
      expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics-offset')), findsOneWidget);

      // A click on a fitted line ahead jumps to its fitted start (paused,
      // so only the jump can bring it there).
      await playback.playOrPause();
      await tester.pump(const Duration(milliseconds: 500));
      final pausedAt = player.position.inMilliseconds;
      final ahead = [
        for (var i = 0; i < timed.lines.length; i++)
          if (!timed.lines[i].isGap &&
              timed.lines[i].startMs! > pausedAt + 15000)
            i,
      ];
      if (ahead.isNotEmpty) {
        final target = ahead.first;
        final line = find.byKey(ValueKey('lyrics-line-$target'));
        await tester.ensureVisible(line);
        await tester.pump(const Duration(milliseconds: 400));
        final targetMs = timed.lines[target].startMs!;
        await tester.tap(line);
        await waitUntil(
          tester,
          () => (player.position.inMilliseconds - targetMs).abs() <= 300,
          timeout: const Duration(seconds: 15),
          what: 'the seek to the fitted line',
        );
        row['click'] = {
          'line': target,
          'atMs': player.position.inMilliseconds,
          'fittedMs': targetMs,
        };
        say(
          '#$index clicked line $target: at ${player.position.inMilliseconds}'
          ' ms, fitted $targetMs',
        );
      }
      // Around the first verse break with room on both sides: paused in
      // the line before it, in the break, and in the line after it, the
      // lit row is the one the fitted starts say (the same lead as the
      // screen), and the break lights during its pause.
      final count = timed.lines.length;
      int? gap;
      for (var i = 1; i + 1 < count; i++) {
        final before = timed.lines[i - 1], after = timed.lines[i + 1];
        if (timed.lines[i].isGap &&
            !before.isGap &&
            !after.isGap &&
            !before.label &&
            !after.label &&
            timed.lines[i].startMs! - before.startMs! >= 1000 &&
            after.startMs! - timed.lines[i].startMs! >= 1000) {
          gap = i;
          break;
        }
      }
      if (gap != null) {
        final points = <String, int>{};
        for (final (name, line) in [
          ('before', gap - 1),
          ('break', gap),
          ('after', gap + 1),
        ]) {
          // Halfway into the row's own span, less the screen's lead.
          final start = timed.lines[line].startMs!;
          final end = timed.lines[line + 1 < count ? line + 1 : line].startMs!;
          final at = (start + end) ~/ 2 - lyricsLeadMs;
          final lit = await litAt(at, count);
          expect(lit, timed.lineAt(at + lyricsLeadMs), reason: '#$index $name');
          expect(lit, line, reason: '#$index $name the break');
          points[name] = at;
        }
        row['verseBreak'] = {'gap': gap, 'atMs': points};
        say('#$index verse break at row $gap: lit rows right');
      } else {
        row['verseBreak'] = 'none with 1 s on both sides';
        say('#$index has no verse break with 1 s on both sides');
      }
      await playback.playOrPause();

      // Opened again (another song, then this one): still fitted.
      final other = library.all.firstWhere(
        (t) => t.inLibrary && t.sourceKey != key,
      );
      await play(other);
      await showLyricsOf(other, 'other');
      await play(song);
      await showLyricsOf(song, index);
      expect(lyrics.isFitted((lyrics.state as LyricsShown).lyrics), isTrue);
      expect(credit(), contains('timed by fitting to this recording'));
      expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);

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
      expect(credit(), startsWith('Words only'));
      await player.stop();
    }

    File(p.join(copy.path, 'plain-live.json')).writeAsStringSync(
      jsonEncode({
        'fitLive': {'songs': rows},
      }),
    );
    say('fitted $fitted of ${rows.length}');
    expect(fitted, greaterThan(0), reason: 'at least one plain song fits');
    expect(tester.takeException(), isNull);
  });
}
