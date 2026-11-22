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
import 'package:ownsemble/lyrics/lyrics_sources.dart';
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

  testWidgets('Lyrics: timed follows and seeks, outside sources, stored, '
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
    // The copy "<data dir>-lyrics" is deleted on every run: it must be a
    // folder inside .local/v2-test too, never v2-test itself (Codex review).
    expect(
      p.basename(p.dirname(p.normalize(dataDir))),
      'v2-test',
      reason: 'a data folder directly inside .local/v2-test',
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
    // answers error 9 to many calls in a row), and for the songs VK has no
    // timed lyrics for, LRCLIB (then NetEase and QQ for a "none anywhere"
    // song) through the app's own readers.
    final client = VkClient(SessionCookie.loadAll(File(session)));
    // login.vk.ru refused connections now and then (lyrics-36a).
    await retryTransient(client.ensureToken);
    final outside = outsideLyricsSources(httpGetJson());
    Track? timedSong, upgradeSong, outsideSong, noneSong, wordsSong, spareSong;
    Lyrics? timedLyrics;
    var asked = 0;
    final songs = library.all
        .where((t) => t.source == TrackSource.vk && t.inLibrary)
        .toList();
    SongNames namesOf(Track track) => SongNames(
      artist: track.artist,
      title: track.title,
      album: track.album,
      seconds: track.durationSec,
    );
    for (final track in songs) {
      final needed =
          timedSong == null ||
          upgradeSong == null ||
          outsideSong == null ||
          spareSong == null;
      if (!needed && noneSong != null && wordsSong != null) break;
      // The optional ones are looked for a while longer, not forever.
      if (!needed && asked >= 90) break;
      if (asked >= 126) break;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      asked++;
      final answer = await fetchVkLyrics(
        client.call,
        sourceKey: track.sourceKey!,
        accessKey: track.accessKey,
      );
      final vkTimed = answer is VkLyricsFound && answer.lyrics.timed;
      if (vkTimed) {
        if (timedSong == null && answer.lyrics.lines.length >= 8) {
          timedSong = track;
          timedLyrics = answer.lyrics;
        }
        continue;
      }
      final vkWords = answer is VkLyricsFound;
      LyricsCandidate? lrclib;
      try {
        lrclib = await outside.first.find(namesOf(track));
      } on LyricsSourceException {
        continue;
      }
      final lrclibTimed = lrclib != null && lrclib.lyrics.timed;
      if (lrclibTimed && vkWords) {
        upgradeSong ??= track;
      } else if (lrclibTimed && outsideSong == null) {
        outsideSong = track;
      } else if (lrclibTimed) {
        spareSong ??= track;
      } else if (lrclib == null && (noneSong == null || wordsSong == null)) {
        // Nothing at LRCLIB: what do NetEase and QQ say?
        try {
          final others = [
            for (final source in outside.skip(1))
              await source.find(namesOf(track)),
          ];
          if (others.every((found) => found == null)) {
            if (vkWords) {
              wordsSong ??= track;
            } else {
              noneSong ??= track;
            }
          }
        } on LyricsSourceException {
          continue;
        }
      }
    }
    client.close();
    say(
      'asked about $asked songs: VK timed "${timedSong?.title}", VK words + '
      'LRCLIB timed "${upgradeSong?.title}", only LRCLIB timed '
      '"${outsideSong?.title}", none anywhere "${noneSong?.title}", VK words '
      'only "${wordsSong?.title}", spare "${spareSong?.title}"',
    );
    expect(timedSong, isNotNull, reason: 'a library song with timed lyrics');
    expect(upgradeSong, isNotNull, reason: 'VK words, LRCLIB timed');
    expect(outsideSong, isNotNull, reason: 'no VK lyrics, LRCLIB timed');

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

    /// Waits until the place shows [track]'s final pick (the walk over the
    /// sources is done) and says how long it took after the song sounded.
    Future<Lyrics> finalPick(Track track, String what) async {
      final clock = Stopwatch()..start();
      await waitUntil(
        tester,
        () =>
            lyrics.track?.id == track.id &&
            lyrics.state is LyricsShown &&
            !(lyrics.state as LyricsShown).refreshing,
        timeout: const Duration(seconds: 30),
        what: what,
      );
      await tester.pump();
      final picked = (lyrics.state as LyricsShown).lyrics;
      say(
        '$what: ${picked.source} ${picked.timed ? 'timed' : 'words'}, '
        '${picked.lines.length} lines, ${clock.elapsedMilliseconds} ms after '
        'the sound',
      );
      return picked;
    }

    String credit() =>
        tester.widget<Text>(find.byKey(const ValueKey('lyrics-credit'))).data!;

    // 4. VK has only words: LRCLIB's timed lines show (the user's "timed
    // first"), and they follow the song.
    await playAndSound(upgradeSong!, 'VK-words song');
    final upgraded = await finalPick(upgradeSong, 'VK words + LRCLIB timed');
    expect(upgraded.source, 'lrclib');
    expect(upgraded.timed, isTrue);
    expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);
    expect(credit(), 'From LRCLIB');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final upgradedAt = player.position.inMilliseconds;
    final upgradedLit = litLine();
    final upgradedExpected = upgraded.lineAt(upgradedAt + 120);
    expect(
      (upgradedLit - upgradedExpected).abs() <= 1,
      isTrue,
      reason: 'lit $upgradedLit at $upgradedAt ms, expected $upgradedExpected',
    );

    // 5. VK has nothing: LRCLIB's lyrics show.
    await playAndSound(outsideSong!, 'song without VK lyrics');
    final fromOutside = await finalPick(outsideSong, 'only LRCLIB timed');
    expect(fromOutside.source, 'lrclib');
    expect(fromOutside.timed, isTrue);
    expect(credit(), 'From LRCLIB');

    // 6. No source at all says so; VK's words alone show as words.
    final none = noneSong;
    if (none != null) {
      await playAndSound(none, 'song without lyrics anywhere');
      await waitUntil(
        tester,
        () => lyrics.track?.id == none.id && lyrics.state is LyricsMissing,
        timeout: const Duration(seconds: 30),
        what: 'the word that no source has lyrics',
      );
      await tester.pump();
      expect(find.text('No lyrics found for this song.'), findsOneWidget);
      say('none anywhere: "No lyrics found" shown');
    } else {
      say('NOT CHECKED: no song without lyrics anywhere among those asked');
    }
    final words = wordsSong;
    if (words != null) {
      await playAndSound(words, 'VK-words-only song');
      final picked = await finalPick(words, 'VK words only');
      expect(picked.source, 'vk');
      expect(picked.timed, isFalse);
      expect(find.byKey(const ValueKey('lyrics-plain')), findsOneWidget);
      expect(credit(), startsWith('Words only, from VK'));
    } else {
      say('NOT CHECKED: no song with VK words and nothing outside');
    }

    // 7. Every source's answer is stored.
    Map<String, int> storedRows(String source) {
      final db = sqlite3.open(
        p.join(copy.path, 'library.db'),
        mode: OpenMode.readOnly,
      );
      try {
        return {
          for (final row in db.select(
            'SELECT ref, found FROM lyrics WHERE source = ?',
            [source],
          ))
            row['ref'] as String: row['found'] as int,
        };
      } finally {
        db.close();
      }
    }

    final vkRows = storedRows('vk');
    final lrclibRows = storedRows('lrclib');
    expect(vkRows[timedSong.sourceKey], 1);
    expect(vkRows[upgradeSong.sourceKey], 1, reason: "VK's words kept too");
    expect(vkRows[outsideSong.sourceKey], 0);
    expect(lrclibRows[upgradeSong.sourceKey], 1);
    expect(lrclibRows[outsideSong.sourceKey], 1);
    expect(
      lrclibRows.containsKey(timedSong.sourceKey),
      isFalse,
      reason: 'VK timed: LRCLIB never asked',
    );
    if (none != null) {
      for (final source in ['vk', 'lrclib', 'netease', 'qq']) {
        expect(storedRows(source)[none.sourceKey], 0, reason: source);
      }
    }
    say(
      'stored: vk ${vkRows.length} rows, lrclib ${lrclibRows.length}, '
      'netease ${storedRows('netease').length}, qq ${storedRows('qq').length}',
    );

    // 7b. A download keeps a song's outside lyrics (never shown before).
    final spare = spareSong;
    expect(spare, isNotNull, reason: 'another LRCLIB song to download');
    if (spare != null) {
      expect(storedRows('lrclib').containsKey(spare.sourceKey), isFalse);
      clock = Stopwatch()..start();
      final error = await playback.download(spare);
      expect(error, isNull, reason: 'download of "${spare.title}"');
      await waitUntil(
        tester,
        () => storedRows('lrclib')[spare.sourceKey] == 1,
        timeout: const Duration(seconds: 30),
        what: 'the downloaded song\'s lyrics to be stored',
      );
      say(
        'download "${spare.title}": audio and LRCLIB lyrics kept in '
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
