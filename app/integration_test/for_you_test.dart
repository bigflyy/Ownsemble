// Real check of the For you place (plan 07, D1): the real app, real VK,
// muted, off-screen. TEST ACCOUNT ONLY: it adds one recommended song to the
// account and removes it again, and puts VK's dislike on one VK Mix song
// and takes it back, in the same run.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/for_you_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-foryou", replaced on
// every run) with nothing stored and no For you cache. Steps: open For you
// (a cold load from VK: the seven lists and a Similar to shelf); open the
// For you list from its card (the library's own songs in it show as the
// library's rows); play two recommended songs the library lacks (streams,
// decoded); + one; Remove it in the app and Undo, then Remove again (VK and
// the library back to their counts); Similar songs from a library song's
// menu; VK Mix plays and the thumb-down skips, VK marks the song disliked,
// and the dislike is taken back; the place opened again comes from the
// cache. Prints names, counts and times only: no link, key, token or id.

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';
import 'package:ownsemble/vk/vk_sync.dart';
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

  testWidgets('For you: lists, play, add, remove, similar, VK Mix', (
    tester,
  ) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final copy = Directory('$dataDir-foryou');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    LibraryStore.open(p.join(copy.path, 'library.db')).close();
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    copied.close();

    final client = VkClient(SessionCookie.loadAll(File(session)));
    await client.ensureToken();
    Future<(int, Set<String>)> vkLibrary() async {
      final reply = await client.call('audio.get', {
        'owner_id': '${client.userId}',
        'count': '1000',
      }) as Map<String, dynamic>;
      return (
        reply['count'] as int,
        {
          for (final item in (reply['items'] as List))
            vkSourceKey(item as Map<String, dynamic>),
        },
      );
    }

    final (vkBefore, keysBefore) = await vkLibrary();
    say('VK before: $vkBefore songs');
    final disliked = <String>{};
    addTearDown(() async {
      final (_, keysNow) = await vkLibrary();
      for (final key in keysNow.difference(keysBefore)) {
        final ok = await deleteVkSong(client.call, key);
        say('cleanup: removed a copy left behind: $ok');
      }
      for (final key in disliked) {
        await undislikeVkSong(client.call, key);
        say('cleanup: took back a dislike');
      }
    });

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
    final sync = screen.sync!;
    final catalog = screen.catalog!;
    final forYou = screen.forYou!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.synced.timeout(const Duration(minutes: 3));
    await tester.pump();
    final listedBefore = library.all.length;
    say('library before: $listedBefore songs listed');
    expect(catalog.accounts, hasLength(1), reason: 'the test account only');

    // 1. A cold open: VK's music page and the seven lists.
    var clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('nav-forYou')));
    await tester.pump();
    await waitUntil(
      tester,
      () => forYou.hasLists && !forYou.refreshing,
      timeout: const Duration(seconds: 60),
      what: 'VK\'s lists',
    );
    final coldMs = clock.elapsedMilliseconds;
    expect(forYou.error, isNull, reason: 'VK answered');
    say(
      'cold open: ${forYou.lists.length} lists '
      '(${forYou.lists.map((l) => '${l.title} ${forYou.songsOf(l.key).length}').join(', ')}), '
      '${forYou.similar.length} similar shelves, mix ${forYou.hasMix}, '
      'in $coldMs ms',
    );
    expect(forYou.lists.length, greaterThanOrEqualTo(7));
    expect(forYou.lists.first.title, 'For you');
    expect(forYou.songsOf(forYou.lists.first.key), isNotEmpty);
    expect(find.byKey(const ValueKey('list-card-For you')), findsOneWidget);

    // 2. The For you list from its card: rows at once from the cache.
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('list-card-For you')));
    await tester.pump();
    final listMs = clock.elapsedMilliseconds;
    expect(library.view.kind, ViewKind.vkList);
    final rows = library.visible;
    final own = rows.where((t) => t.inLibrary).length;
    final restricted = rows
        .where((t) => forYou.restrictionOf(t.id) != null)
        .length;
    say(
      'For you list: ${rows.length} rows in $listMs ms, $own of them the '
      'library\'s own songs, $restricted VK gives no file for',
    );
    expect(rows, isNotEmpty);
    expect(listMs, lessThan(1000), reason: 'debug build; C4 target 300 ms');

    // 3. Two recommended songs the library lacks play (streamed, decoded).
    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    final picks = rows
        .where(
          (t) =>
              !t.inLibrary &&
              forYou.restrictionOf(t.id) == null &&
              t.durationSec >= 60,
        )
        .take(2)
        .toList();
    expect(picks, hasLength(2));
    for (final pick in picks) {
      final row = find.byKey(ValueKey('song-${pick.id}'));
      await tester.ensureVisible(row);
      await tester.pump();
      final before = timings.length;
      await tester.tap(row);
      await tester.pump();
      await waitUntil(
        tester,
        () => timings.length > before,
        timeout: const Duration(seconds: 60),
        what: 'a recommended song to sound',
      );
      final timing = timings.last;
      expect(timing.ok, isTrue, reason: 'error: ${timing.error}');
      expect(timing.cached, isFalse);
      expect(timing.sampleRate, isNotNull, reason: 'mpv decoded the audio');
      await waitUntil(
        tester,
        () => player.position >= const Duration(seconds: 3),
        timeout: const Duration(seconds: 30),
        what: 'the song to move past 3 s',
      );
      say(
        'played ${pick.artist} - ${pick.title}: sound in '
        '${timing.toSoundMs} ms (network first chunk '
        '${timing.networkFirstChunkMs} ms), ${timing.sampleRate} Hz',
      );
    }
    expect(find.byKey(const ValueKey('player-dislike')), findsOneWidget);

    // 4. + on the playing one adds it to the library and to VK.
    final added = picks.last;
    clock = Stopwatch()..start();
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('song-${added.id}')),
        matching: find.byKey(const ValueKey('add-song')),
      ),
    );
    await tester.pump();
    await waitUntil(
      tester,
      () => library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 30),
      what: 'the library to list the added song',
    );
    final (vkAdded, _) = await vkLibrary();
    say('added in ${clock.elapsedMilliseconds} ms; VK $vkAdded songs');
    expect(vkAdded, vkBefore + 1);
    await tester.pump(const Duration(milliseconds: 500));
    final copyOf = library.visible.firstWhere(
      (t) => t.inLibrary && t.title == added.title,
      orElse: () => fail('the list shows the library\'s copy'),
    );
    say('the list row is now the library\'s song: ${copyOf.inLibrary}');
    // The "Added" note goes first, so the Remove note's Undo is on top.
    await tester.pump(const Duration(seconds: 7));

    // 5. Remove in the app, Undo, Remove again.
    Future<void> chooseInMenu(Finder row, String key) async {
      await tester.tap(row, buttons: kSecondaryMouseButton);
      await tester.pump();
      final item = find.byKey(ValueKey(key));
      await waitUntil(
        tester,
        () => item.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 5),
        what: 'the menu item $key',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(item);
      await tester.pump();
    }

    final ownRow = find.byKey(ValueKey('song-${copyOf.id}'));
    await tester.ensureVisible(ownRow);
    await tester.pump();
    await chooseInMenu(ownRow, 'menu-remove-from-library');
    await waitUntil(
      tester,
      () => library.all.length == listedBefore,
      timeout: const Duration(seconds: 30),
      what: 'VK to remove the song',
    );
    expect((await vkLibrary()).$1, vkBefore);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('note-undo')));
    await tester.pump();
    await waitUntil(
      tester,
      () => library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 30),
      what: 'Undo to bring the song back',
    );
    expect((await vkLibrary()).$1, vkBefore + 1);
    say('Remove and Undo from the list: VK back to ${vkBefore + 1}');
    await tester.pump(const Duration(seconds: 7));
    await tester.ensureVisible(ownRow);
    await tester.pump();
    await chooseInMenu(ownRow, 'menu-remove-from-library');
    await waitUntil(
      tester,
      () => library.all.length == listedBefore,
      timeout: const Duration(seconds: 30),
      what: 'VK to remove the song again',
    );
    final (vkAfter, _) = await vkLibrary();
    say('removed again: VK $vkAfter songs, library ${library.all.length}');
    expect(vkAfter, vkBefore);
    await tester.pump(const Duration(seconds: 7));

    // 6. Similar songs from a library song's menu.
    library.showView(LibraryView.songs);
    await tester.pump();
    final seed = library.visible.firstWhere(
      (t) => t.source == TrackSource.vk && !t.isGone,
    );
    await chooseInMenu(find.byKey(ValueKey('song-${seed.id}')), 'menu-similar');
    await waitUntil(
      tester,
      () => library.view.kind == ViewKind.vkList,
      timeout: const Duration(seconds: 30),
      what: 'the similar songs',
    );
    await tester.pump();
    say(
      'similar to ${seed.artist} - ${seed.title}: '
      '${library.visible.length} songs, '
      '${library.visible.where((t) => t.inLibrary).length} the library has',
    );
    expect(library.visible, isNotEmpty);

    // 7. VK Mix plays; the thumb-down skips and VK marks the song.
    await tester.tap(find.byKey(const ValueKey('nav-forYou')));
    await tester.pump();
    await tester.pump();
    final beforeMix = timings.length;
    await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
    await tester.pump();
    await waitUntil(
      tester,
      () => timings.length > beforeMix,
      timeout: const Duration(seconds: 60),
      what: 'VK Mix to sound',
    );
    expect(timings.last.ok, isTrue, reason: 'error: ${timings.last.error}');
    expect(timings.last.sampleRate, isNotNull);
    final mixSong = player.current!;
    say(
      'VK Mix: ${forYou.mixSongs.length} songs lined up, sound in '
      '${timings.last.toSoundMs} ms',
    );
    final beforeSkip = timings.length;
    disliked.add(mixSong.sourceKey!);
    await tester.tap(find.byKey(const ValueKey('player-dislike')));
    await tester.pump();
    await waitUntil(
      tester,
      () => timings.length > beforeSkip,
      timeout: const Duration(seconds: 60),
      what: 'the next mix song after the thumb-down',
    );
    expect(player.current?.id, isNot(mixSong.id), reason: 'skipped');
    final marked = await client.call('audio.getById', {
      'audios': '${mixSong.sourceKey}_${mixSong.accessKey}',
    }) as List;
    final flag = (marked.first as Map)['dislike'];
    say('thumb-down: skipped; VK dislike flag $flag');
    expect(flag, isTrue);
    await undislikeVkSong(client.call, mixSong.sourceKey!);
    disliked.clear();
    final dislikes = File(p.join(copy.path, 'dislikes.jsonl'));
    expect(dislikes.readAsLinesSync(), hasLength(1), reason: 'local record');

    // 8. Opened again: from the cache, no wait.
    library.showView(LibraryView.songs);
    await tester.pump();
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('nav-forYou')));
    await tester.pump();
    final warmMs = clock.elapsedMilliseconds;
    expect(find.byKey(const ValueKey('list-card-For you')), findsOneWidget);
    expect(forYou.refreshing, isFalse, reason: 'fresh cache: VK not asked');
    say('warm open: cards in $warmMs ms (debug build)');
    final cache = File(p.join(copy.path, 'for-you.json'));
    expect(cache.readAsStringSync(), isNot(contains('"url"')));

    player.player.pause();
    await tester.pump(const Duration(seconds: 1));
    say('PASSED');
  });
}
