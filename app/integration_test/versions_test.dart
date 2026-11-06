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
// the mark on the row, the song's versions as a list that opens at once,
// another upload played from its row, a pick of VK's own file, the stored
// copy of the other recording thrown away, and a reset back to the
// suggestion. The second account is read-only: only reads and muted
// streaming. Its songs stay out of the public repo, so this file and its
// output name the song by its library id and lengths only, never a title.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
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

  /// Saves what the window shows now as versions-<name>.png next to the
  /// data folder (local only: it may show the second account's songs).
  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 500));
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & view.size);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(p.join(p.dirname(dataDir), 'versions-$name.png'))
      ..writeAsBytesSync(png!.buffer.asUint8List());
    say('screenshot ${file.path}');
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
    // of choices and found versions of earlier runs.
    LibraryStore.open(p.join(copy.path, 'library.db')).close();
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    copied.execute('DELETE FROM song_versions');
    copied.execute('DELETE FROM found_versions');
    copied.close();

    await app.main([
      '--data-dir',
      copy.path,
      '--vk-session',
      firstSession,
      if (secondSession.isNotEmpty) ...['--vk-session', secondSession],
      '--muted',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    final library = screen.library;
    final player = screen.player;
    final playback = screen.playback;
    final versions = player.versions!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    // The sync itself; the file check after it (Stage M2) goes on in the
    // background and may find the swap before the first play does.
    await screen.sync!.synced.timeout(const Duration(minutes: 3));
    await tester.pump();
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
    final foundByCheck = versions.choiceFor(track) != null;
    var before = timings.length;
    unawaited(playback.playFrom([track], 0));
    final first = await nextTiming(before, 'the first play');
    expect(first.ok, isTrue, reason: 'error: ${first.error}');
    final firstLength = await loadedLength();
    say('first play: ${describe(first, firstLength)}');
    say(
      foundByCheck
          ? 'the background file check found the swap before the play'
          : 'the play found the swap: ${first.versionNews != null}',
    );
    if (!foundByCheck && first.versionNews == null) {
      expect(
        versions.choiceFor(track),
        isNotNull,
        reason: 'the swap was found by the play or by the check meanwhile',
      );
    }
    expect(first.version, VersionState.suggested);
    expect((first.fileSeconds! - track.durationSec).abs(), lessThan(1.0));
    expect((firstLength! - track.durationSec).abs(), lessThan(1.5));
    final suggested = versions.choiceFor(track)!;
    say(
      'choice: ${suggested.state.name}, own file '
      '${suggested.ownSeconds.toStringAsFixed(1)} s (${suggested.ownBytes} '
      'bytes), suggested file ${suggested.fileSeconds?.toStringAsFixed(1)} s',
    );
    expect((suggested.ownSeconds - track.durationSec).abs(), greaterThan(3));
    // Mpv plays it for a while, so its save can finish.
    await waitUntil(
      tester,
      () => player.storage!.stateOf(track).path != null,
      timeout: const Duration(seconds: 60),
      what: 'the suggested version saved',
    );
    say('suggested version saved');

    // 2. The mark shows on the row and in the player; it opens the song's
    // versions as a list (plan 03), at once: the first play's search kept
    // what it found.
    await tester.pump(const Duration(milliseconds: 300));
    final tags = find.byKey(ValueKey('version-tag-$trackId'));
    expect(tags, findsWidgets, reason: 'the song is marked');
    say('marks found: ${tags.evaluate().length}');
    await tester.tap(tags.first);
    final openClock = Stopwatch()..start();
    await tester.pump();
    final openMs = openClock.elapsedMilliseconds;
    expect(library.view.kind, ViewKind.versions);
    expect(find.text('Versions of ${track.title}'), findsOneWidget);
    final list = library.versionList!;
    say(
      'versions open after $openMs ms: ${library.visible.length} rows, '
      'searching ${list.searching}',
    );
    expect(library.visible.length, greaterThanOrEqualTo(2));
    expect(list.searching, isFalse, reason: 'the stored list shows');
    final shown = [for (final row in library.visible) library.versionOf(row)!];
    await shot(tester, 'open');
    expect(shown.first.isCurrentFile, isTrue);
    expect(shown[1].key, suggested.fileKey, reason: 'the one in use second');
    say(
      'rows: ${[for (final v in shown.take(6)) '${v.isCurrentFile ? 'vk-file' : 'upload'} '
            '${v.file?.seconds.toStringAsFixed(1) ?? '-'} s${v.official ? ' official' : ''}'].join('; ')}',
    );
    Finder rowOf(SongVersion version) => find.byKey(
      ValueKey('song-${versions.versionTrack(track, version).id}'),
    );
    expect(
      find.descendant(
        of: rowOf(shown[1]),
        matching: find.byKey(const ValueKey('version-tag-in use')),
      ),
      findsOneWidget,
    );

    // 3. A click on another upload's row plays it, like any song, and the
    // row shows the playing mark (the old dialog's play button showed
    // nothing, user 2026-11-06).
    final listen = shown
        .take(6)
        .skip(2)
        .firstWhere((v) => v.file != null, orElse: () => shown[1]);
    before = timings.length;
    await tester.tap(rowOf(listen));
    await tester.pump(const Duration(milliseconds: 300));
    final heard = await nextTiming(before, 'the play of a version');
    final heardLength = await loadedLength();
    say('listened to an upload: ${describe(heard, heardLength)}');
    expect(heard.ok, isTrue, reason: 'error: ${heard.error}');
    expect(player.current?.id, versions.versionTrack(track, listen).id);
    expect((heardLength! - listen.file!.seconds).abs(), lessThan(1.5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(
        of: rowOf(listen),
        matching: find.byIcon(Icons.graphic_eq),
      ),
      findsOneWidget,
      reason: 'the playing mark on its row',
    );
    await shot(tester, 'listening');

    // 4. The user picks VK's own file from its row's menu: the song plays
    // it (another length), and the stored suggested file is thrown away
    // first, since it no longer fits.
    await tester.tap(rowOf(shown.first), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('menu-use-version')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(versions.choiceFor(track)!.state, VersionState.picked);
    final stored = LibraryStore.open(p.join(copy.path, 'library.db'));
    expect(stored.versionChoices()[trackId]?.state, VersionState.picked);
    stored.close();
    await player.stop();
    before = timings.length;
    unawaited(player.play(track));
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

    // 5. Back to automatic from the menu: the next play finds the swap
    // again.
    await tester.tap(rowOf(shown[1]), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('menu-versions-reset')));
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

    // 6. The album opens from a row of the versions place (user,
    // 2026-11-06: "album is not clickable at Versions view"), listed by VK
    // through the song's account, read-only: VK's file row shows the song's
    // own album, an upload its own when VK's search names one (few do).
    final named = shown
        .where((v) => !v.isCurrentFile && (v.album ?? '').isNotEmpty)
        .toList();
    say(
      'uploads with a named album: ${named.length} of ${shown.length - 1}, '
      'of them with a link: ${named.where((v) => v.albumKey != null).length}',
    );
    Future<void> openAlbumFrom(SongVersion version) async {
      final where = version.isCurrentFile ? 'vk-file' : 'upload';
      // Only rows on screen are built; long lists scroll to it first.
      final scroll = library.scroll;
      scroll.jumpTo(0);
      await tester.pump();
      while (rowOf(version).evaluate().isEmpty &&
          scroll.offset < scroll.position.maxScrollExtent) {
        scroll.jumpTo(
          (scroll.offset + 200).clamp(0, scroll.position.maxScrollExtent),
        );
        await tester.pump();
      }
      await tester.ensureVisible(rowOf(version));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: rowOf(version),
          matching: find.text(version.album!),
        ),
      );
      final albumClock = Stopwatch()..start();
      await tester.pump();
      expect(library.view.kind, ViewKind.album, reason: '$where album');
      expect(library.view.album?.link, isNotNull);
      await waitUntil(
        tester,
        () => library.albumStatus?.load != AlbumLoad.loading,
        what: 'the $where album',
      );
      final albumStatus = library.albumStatus!;
      say(
        '$where row album opened: ${albumStatus.load.name} after '
        '${albumClock.elapsedMilliseconds} ms, ${library.visible.length} '
        'songs${albumStatus.reason == null ? '' : ', ${albumStatus.reason}'}',
      );
      expect(albumStatus.load, AlbumLoad.loaded, reason: albumStatus.reason);
      expect(library.visible, isNotEmpty);
      await shot(tester, 'album-$where');
    }

    if ((shown.first.album ?? '').isNotEmpty) {
      await openAlbumFrom(shown.first);
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await tester.pumpAndSettle();
      expect(library.view.kind, ViewKind.versions);
    }
    final linked = named.where((v) => v.albumKey != null).firstOrNull;
    if (linked != null) await openAlbumFrom(linked);
    say('versions check passed');
  });
}

/// How far two measurements of one file may differ.
const otherRecordingAllowance = 0.5;
