// Real check of the Lyrics place (plan 10, D1): the real app, real VK,
// muted, off-screen. TEST ACCOUNT ONLY, read-only on VK: nothing is added,
// removed or changed there.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/lyrics_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-lyrics", replaced on
// every run) with no stored audio and no stored lyrics. The test first asks
// VK itself which library songs have timed lyrics, plain lyrics or none
// (a few calls, spaced out). Steps: a timed song plays (decoded); the mic
// button opens Lyrics, which shows its timed lines; a click on a later line
// seeks there; the lit line follows the song and stays in sight; the next
// song with plain lyrics shows them; a song without lyrics says so; what VK
// answered is stored; a download keeps a song's lyrics in the library; the
// mic button closes the place. Prints titles, counts and times only: no
// lyrics, link, key, token or id.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_lyrics.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');

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

  testWidgets('Lyrics: timed follows and seeks, plain, none, stored, '
      'download keeps them', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(
      session.toLowerCase().contains('session-2'),
      isFalse,
      reason: 'test account',
    );
    expect(
      p.split(p.normalize(dataDir)).contains('v2-test'),
      isTrue,
      reason: 'a data folder inside .local/v2-test only',
    );

    final copy = Directory('$dataDir-lyrics');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    final hasLyrics = copied
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'lyrics'",
        )
        .isNotEmpty;
    if (hasLyrics) copied.execute('DELETE FROM lyrics');
    copied.close();

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
    final sync = screen.sync!;
    final lyrics = screen.lyrics!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.idle.timeout(const Duration(minutes: 5));
    await tester.pump();
    expect(sync.lastOutcome?.error, isNull, reason: 'the start sync worked');

    // Which songs have what: asked by the test itself, spaced out (VK
    // answers error 9 to many calls in a row).
    final client = VkClient(SessionCookie.loadAll(File(session)));
    // login.vk.ru refused connections now and then (lyrics-36a).
    await retryTransient(client.ensureToken);
    Track? timedSong, plainSong, noneSong, spareSong;
    Lyrics? timedLyrics;
    var asked = 0;
    final songs = library.all
        .where((t) => t.source == TrackSource.vk && t.inLibrary)
        .toList();
    for (final track in songs) {
      if (timedSong != null &&
          plainSong != null &&
          noneSong != null &&
          spareSong != null) {
        break;
      }
      if (asked >= 45) break;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      asked++;
      final answer = await fetchVkLyrics(
        client.call,
        sourceKey: track.sourceKey!,
        accessKey: track.accessKey,
      );
      switch (answer) {
        case VkLyricsFound(:final lyrics) when lyrics.timed:
          if (timedSong == null && lyrics.lines.length >= 8) {
            timedSong = track;
            timedLyrics = lyrics;
          } else {
            spareSong ??= track;
          }
        case VkLyricsFound():
          if (plainSong == null) {
            plainSong = track;
          } else {
            spareSong ??= track;
          }
        case VkLyricsNone():
          noneSong ??= track;
      }
    }
    client.close();
    say(
      'asked VK about $asked songs: timed "${timedSong?.title}", plain '
      '"${plainSong?.title}", none "${noneSong?.title}", spare '
      '"${spareSong?.title}"',
    );
    expect(timedSong, isNotNull, reason: 'a library song with timed lyrics');
    expect(plainSong, isNotNull, reason: 'a library song with plain lyrics');
    expect(noneSong, isNotNull, reason: 'a library song without lyrics');

    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    Future<void> playAndSound(Track track, String what) async {
      final before = timings.length;
      await playback.playFrom([track], 0);
      await waitUntil(
        tester,
        () => timings.length > before,
        what: '$what to sound',
      );
      final timing = timings.last;
      expect(timing.ok, isTrue, reason: '$what: error ${timing.error}');
      expect(timing.sampleRate, isNotNull, reason: 'mpv decoded $what');
      say(
        '$what "${track.title}": sound in ${timing.toSoundMs} ms, '
        '${timing.sampleRate} Hz',
      );
    }

    /// The index of the lit (bold) timed line on screen, or -1.
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

    // 1. A timed song plays; the mic button opens its lyrics.
    await playAndSound(timedSong!, 'timed song');
    var clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('lyrics')).first);
    await tester.pump();
    expect(library.view.kind, ViewKind.lyrics);
    await waitUntil(
      tester,
      () => lyrics.state is LyricsShown,
      timeout: const Duration(seconds: 20),
      what: 'the timed lyrics',
    );
    final shownMs = clock.elapsedMilliseconds;
    final shown = (lyrics.state as LyricsShown).lyrics;
    expect(shown.timed, isTrue);
    expect(shown, timedLyrics, reason: 'the same lyrics VK gave the test');
    await tester.pump();
    expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);
    say(
      'timed lyrics shown $shownMs ms after the click (first ask): '
      '${shown.lines.length} lines',
    );

    // 2. A click on a later line seeks there.
    final target = [
      for (var i = 0; i < shown.lines.length; i++)
        if (!shown.lines[i].isGap && shown.lines[i].startMs! > 25000) i,
    ].first;
    final targetLine = find.byKey(ValueKey('lyrics-line-$target'));
    await tester.ensureVisible(targetLine);
    await tester.pump(const Duration(milliseconds: 400));
    final startMs = shown.lines[target].startMs!;
    await tester.tap(targetLine);
    await waitUntil(
      tester,
      () =>
          player.position.inMilliseconds >= startMs - 500 &&
          player.position.inMilliseconds <= startMs + 4000,
      timeout: const Duration(seconds: 15),
      what: 'the seek to the clicked line',
    );
    say(
      'clicked line $target ($startMs ms): playing at '
      '${player.position.inMilliseconds} ms',
    );

    // 3. The lit line follows the song and stays in sight.
    final page = tester.getRect(find.byKey(const ValueKey('lyrics-timed')));
    final checks = <String>[];
    for (var round = 0; round < 4; round++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final at = player.position.inMilliseconds;
      final expected = shown.lineAt(at + 120);
      final lit = litLine();
      checks.add('$at ms: lit $lit, expected $expected');
      expect(
        (lit - expected).abs() <= 1,
        isTrue,
        reason: 'lit line $lit at $at ms, expected about $expected',
      );
      final rect = tester.getRect(find.byKey(ValueKey('lyrics-line-$lit')));
      expect(
        rect.top >= page.top && rect.bottom <= page.bottom,
        isTrue,
        reason: 'the lit line is in sight',
      );
    }
    say('following: ${checks.join('; ')}');

    // 4. A song with plain lyrics: the place follows the playing song.
    await playAndSound(plainSong!, 'plain song');
    await waitUntil(
      tester,
      () =>
          lyrics.track?.id == plainSong!.id &&
          lyrics.state is LyricsShown &&
          !(lyrics.state as LyricsShown).lyrics.timed,
      timeout: const Duration(seconds: 20),
      what: 'the plain lyrics',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('lyrics-plain')), findsOneWidget);
    say(
      'plain lyrics: '
      '${(lyrics.state as LyricsShown).lyrics.lines.length} lines',
    );

    // 5. A song without lyrics says so.
    await playAndSound(noneSong!, 'song without lyrics');
    await waitUntil(
      tester,
      () => lyrics.track?.id == noneSong!.id && lyrics.state is LyricsMissing,
      timeout: const Duration(seconds: 20),
      what: 'the word that VK has none',
    );
    await tester.pump();
    expect(find.text('VK has no lyrics for this song.'), findsOneWidget);

    // 6. What VK answered is stored.
    Map<String, int> storedRows() {
      final db = sqlite3.open(
        p.join(copy.path, 'library.db'),
        mode: OpenMode.readOnly,
      );
      try {
        return {
          for (final row in db.select(
            'SELECT ref, found FROM lyrics WHERE source = ?',
            ['vk'],
          ))
            row['ref'] as String: row['found'] as int,
        };
      } finally {
        db.close();
      }
    }

    final rows = storedRows();
    expect(rows[timedSong.sourceKey], 1);
    expect(rows[plainSong.sourceKey], 1);
    expect(rows[noneSong.sourceKey], 0);
    say(
      'stored: ${rows.length} rows (${rows.values.where((f) => f == 1).length} with lyrics)',
    );

    // 7. A download keeps a song's lyrics (never shown before).
    final spare = spareSong;
    if (spare == null) {
      say('download: no spare song with lyrics found: NOT CHECKED');
    } else {
      expect(rows.containsKey(spare.sourceKey), isFalse);
      clock = Stopwatch()..start();
      final error = await playback.download(spare);
      expect(error, isNull, reason: 'download of "${spare.title}"');
      await waitUntil(
        tester,
        () => storedRows()[spare.sourceKey] == 1,
        timeout: const Duration(seconds: 30),
        what: 'the downloaded song\'s lyrics to be stored',
      );
      say(
        'download "${spare.title}": audio and lyrics kept in '
        '${clock.elapsedMilliseconds} ms',
      );
      playback.removeDownload(spare);
    }

    // 8. The mic button closes the place.
    await tester.tap(find.byKey(const ValueKey('lyrics')).first);
    await tester.pump();
    expect(library.view.kind, isNot(ViewKind.lyrics));
    final perf = File(p.join(copy.path, 'perf.log')).readAsLinesSync();
    for (final line in perf.where((l) => l.contains(' lyrics '))) {
      say('perf: ${line.substring(line.indexOf(' ') + 1)}');
    }
    say('LYRICS CHECK PASSED');
  });
}
