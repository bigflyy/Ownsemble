// Real check of the Playlists place (plan 08, B3): the real app, real VK,
// muted, off-screen. TEST ACCOUNT ONLY: it uses the playlist "Ownsemble
// test" (tool/make_test_playlist.dart; user 2026-11-17 "1 yes": made once
// and left there), adds one song to it and takes it out again, and adds one
// playlist song to the library and removes it again, in the same run.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/playlists_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-playlists", replaced on
// every run) with nothing stored and no playlists cache. Steps: the sync at
// start ends and the playlists are read; the page shows the made and the
// followed playlist; the test playlist opens with the library's own songs in
// place; an outside song and an own song play (streamed, decoded); + adds
// an outside song, Remove takes it out again (VK back to its count); Shuffle;
// the followed playlist of 749 songs opens from the cache; a song added to
// the playlist on VK shows after the next sync, and goes after it is taken
// out. Prints names, counts and times only: no link, key, token or id.

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_playlists.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');
const testTitle = 'Ownsemble test';

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

  testWidgets('Playlists: page, open, play, add, remove, shuffle, mirror', (
    tester,
  ) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(session, isNot(contains('session-2')), reason: 'test account');
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final copy = Directory('$dataDir-playlists');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    copied.close();

    final client = VkClient(SessionCookie.loadAll(File(session)));
    await client.ensureToken();
    final me = client.userId;
    Future<(int, Set<String>)> vkLibrary() async {
      final reply = await client.call('audio.get', {
        'owner_id': '$me',
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
    final onVk = await fetchVkPlaylists(client.call, me);
    final test = onVk.firstWhere(
      (list) => list.title == testTitle,
      orElse: () => fail('no "$testTitle": run tool/make_test_playlist.dart'),
    );
    final testSongs = await fetchVkPlaylistSongs(client.call, test);
    say(
      'VK before: $vkBefore songs; ${onVk.length} playlists; '
      '"$testTitle" ${testSongs.length} songs',
    );
    final playlistId = test.key.split('_').last;
    String? addedToPlaylist;
    addTearDown(() async {
      final (_, keysNow) = await vkLibrary();
      for (final key in keysNow.difference(keysBefore)) {
        final ok = await deleteVkSong(client.call, key);
        say('cleanup: removed a copy left behind: $ok');
      }
      if (addedToPlaylist case final key?) {
        await client.call('audio.removeFromPlaylist', {
          'owner_id': '$me',
          'playlist_id': playlistId,
          'audio_ids': key,
        });
        say('cleanup: took the added song out of the playlist');
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
    final playback = screen.playback;
    final sync = screen.sync!;
    final playlists = screen.playlists!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.idle.timeout(const Duration(minutes: 5));
    await tester.pump();
    final listedBefore = library.all.length;
    say('library before: $listedBefore songs listed');

    // 1. The sync ended: the playlists were read from VK.
    var clock = Stopwatch()..start();
    await waitUntil(
      tester,
      () => playlists.hasLists && !playlists.refreshing,
      timeout: const Duration(seconds: 90),
      what: 'the playlists after the sync',
    );
    say('playlists in after the sync (waited ${clock.elapsedMilliseconds} ms)');
    final perf = File(p.join(copy.path, 'perf.log')).readAsLinesSync();
    for (final line in perf.where((l) => l.contains('playlists '))) {
      say('perf: ${line.substring(line.indexOf(' ') + 1)}');
    }
    final shown = playlists.shown.single;
    say(
      'shown: ${shown.lists.map((l) => '${l.kind.name} "${l.title}" '
          '${playlists.songsOf(l.key).length}').join(', ')}',
    );
    expect(
      shown.lists.where((l) => l.kind == VkPlaylistKind.album),
      isEmpty,
      reason: 'albums are not shown',
    );
    final followed = shown.lists.firstWhere(
      (l) => l.kind == VkPlaylistKind.followed,
    );

    // 2. The page: the cards.
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pump();
    final pageMs = clock.elapsedMilliseconds;
    expect(find.byKey(ValueKey('list-card-$testTitle')), findsOneWidget);
    expect(find.byKey(ValueKey('list-card-${followed.title}')), findsOneWidget);
    expect(find.text('YOUR PLAYLISTS'), findsOneWidget);
    expect(find.text('PLAYLISTS YOU FOLLOW'), findsOneWidget);
    say('page: cards in $pageMs ms (debug build)');

    // 3. The test playlist: the library's own songs in place.
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(ValueKey('list-card-$testTitle')));
    await tester.pump();
    final openMs = clock.elapsedMilliseconds;
    expect(library.view.kind, ViewKind.vkList);
    final rows = library.visible;
    final own = rows.where((t) => t.inLibrary).toList();
    say(
      '"$testTitle": ${rows.length} rows in $openMs ms, ${own.length} the '
      'library\'s own: ${rows.map((t) => '${t.inLibrary ? 'own' : 'outside'} '
          '${t.artist} - ${t.title}').join('; ')}',
    );
    expect(rows, hasLength(testSongs.length));
    expect(own, hasLength(3), reason: 'made with 3 library songs');
    expect(find.text('Your playlist on VK. 3 in your library'), findsOneWidget);

    // 4. An outside song and an own song play (streamed, decoded).
    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    final outsideSong = rows.firstWhere((t) => !t.inLibrary);
    for (final pick in [outsideSong, own.first]) {
      final row = find.byKey(ValueKey('song-${pick.id}'));
      final before = timings.length;
      await tester.tap(row);
      await tester.pump();
      await waitUntil(
        tester,
        () => timings.length > before,
        timeout: const Duration(seconds: 60),
        what: 'a playlist song to sound',
      );
      final timing = timings.last;
      expect(timing.ok, isTrue, reason: 'error: ${timing.error}');
      expect(timing.sampleRate, isNotNull, reason: 'mpv decoded the audio');
      expect(player.current?.inLibrary, pick.inLibrary);
      await waitUntil(
        tester,
        () => player.position >= const Duration(seconds: 3),
        timeout: const Duration(seconds: 30),
        what: 'the song to move past 3 s',
      );
      say(
        'played ${pick.inLibrary ? 'own' : 'outside'} ${pick.artist} - '
        '${pick.title}: sound in ${timing.toSoundMs} ms (network first '
        'chunk ${timing.networkFirstChunkMs} ms), ${timing.sampleRate} Hz, '
        'queue ${playback.queue.context.length}',
      );
    }
    expect(
      find.byKey(const ValueKey('player-dislike')),
      findsNothing,
      reason: 'the thumb-down is for recommended songs',
    );

    // 5. + on an outside song, then Remove: VK back to its count.
    clock = Stopwatch()..start();
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('song-${outsideSong.id}')),
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
      (t) => t.inLibrary && t.title == outsideSong.title,
      orElse: () => fail('the playlist shows the library\'s copy'),
    );
    expect(library.visible.where((t) => t.inLibrary), hasLength(4));
    await tester.pump(const Duration(seconds: 7));
    final ownRow = find.byKey(ValueKey('song-${copyOf.id}'));
    await tester.tap(ownRow, buttons: kSecondaryMouseButton);
    await tester.pump();
    final remove = find.byKey(const ValueKey('menu-remove-from-library'));
    await waitUntil(
      tester,
      () => remove.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 5),
      what: 'the Remove menu item',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(remove);
    await tester.pump();
    await waitUntil(
      tester,
      () => library.all.length == listedBefore,
      timeout: const Duration(seconds: 30),
      what: 'VK to remove the song',
    );
    final (vkAfter, _) = await vkLibrary();
    say('removed: VK $vkAfter songs, library ${library.all.length}');
    expect(vkAfter, vkBefore);
    await tester.pump(const Duration(seconds: 7));

    // 6. Shuffle from the heading.
    final shuffleWas = playback.shuffle;
    final beforeShuffle = timings.length;
    await tester.tap(find.byKey(const ValueKey('list-shuffle')));
    await tester.pump();
    await waitUntil(
      tester,
      () => timings.length > beforeShuffle,
      timeout: const Duration(seconds: 60),
      what: 'Shuffle to sound',
    );
    expect(playback.shuffle, isTrue);
    expect(timings.last.ok, isTrue, reason: 'error: ${timings.last.error}');
    say(
      'Shuffle: on (was $shuffleWas), ${player.current?.title} plays, '
      'queue ${playback.queue.context.length}',
    );
    if (!shuffleWas) playback.toggleShuffle();

    // 6b. The page shows which playlist plays (user, 2026-11-18: "not very
    // clear which playlist is playing now"): its card is marked after
    // Shuffle, the other is not, and the side panel says where it plays
    // from.
    library.goBack();
    await tester.pump();
    expect(library.view.kind, ViewKind.playlists);
    expect(
      find.byKey(ValueKey('list-playing-$testTitle')),
      findsOneWidget,
      reason: 'the playing card is marked',
    );
    expect(
      find.byKey(ValueKey('list-playing-${followed.title}')),
      findsNothing,
    );
    final from = find.byKey(const ValueKey('player-from'));
    final panel = find.byType(NowPlayingPanel).evaluate().isNotEmpty;
    if (panel) {
      expect(
        find.descendant(of: from, matching: find.textContaining(testTitle)),
        findsOneWidget,
      );
    }
    say(
      'playing mark: on the "$testTitle" card after Shuffle; side panel '
      '${panel ? 'says Playing from "$testTitle"' : 'not shown (bottom bar)'}',
    );

    // 7. The followed playlist, from what the refresh read.
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(ValueKey('list-card-${followed.title}')));
    await tester.pump();
    final bigMs = clock.elapsedMilliseconds;
    final bigRows = library.visible;
    say(
      '"${followed.title}": ${bigRows.length} rows in $bigMs ms, '
      '${bigRows.where((t) => t.inLibrary).length} the library\'s own, '
      '${bigRows.where((t) => playlists.outside.restrictionOf(t.id) != null).length} '
      'VK gives no file for',
    );
    expect(bigRows.length, greaterThan(100));
    expect(find.textContaining('A playlist you follow on VK'), findsOneWidget);
    expect(bigMs, lessThan(1500), reason: 'debug build');

    // 8. Mirror: a song added to the playlist on VK shows after a sync,
    // and goes after it is taken out.
    final (_, keysNow) = await vkLibrary();
    final extra = keysNow.firstWhere(
      (key) => !testSongs.any((s) => s.key == key),
    );
    await client.call('audio.addToPlaylist', {
      'owner_id': '$me',
      'playlist_id': playlistId,
      'audio_ids': extra,
    });
    addedToPlaylist = extra;
    Future<int> afterSync() async {
      clock = Stopwatch()..start();
      await sync.syncNow();
      await sync.idle.timeout(const Duration(minutes: 5));
      await waitUntil(
        tester,
        () => !playlists.refreshing,
        timeout: const Duration(seconds: 60),
        what: 'the playlists refresh after the sync',
      );
      await tester.pump();
      return playlists.songsOf(test.key).length;
    }

    final grown = await afterSync();
    say(
      'added on VK: after the sync the playlist has $grown songs '
      '(${clock.elapsedMilliseconds} ms sync + refresh)',
    );
    expect(grown, testSongs.length + 1);
    await client.call('audio.removeFromPlaylist', {
      'owner_id': '$me',
      'playlist_id': playlistId,
      'audio_ids': extra,
    });
    addedToPlaylist = null;
    final refreshesBefore = File(p.join(copy.path, 'perf.log'))
        .readAsLinesSync()
        .where((l) => l.contains('playlists refresh'))
        .length;
    final back = await afterSync();
    say('taken out on VK: after the sync the playlist has $back songs');
    expect(back, testSongs.length);
    final reads = File(p.join(copy.path, 'perf.log'))
        .readAsLinesSync()
        .where((l) => l.contains('playlists refresh'))
        .skip(refreshesBefore)
        .toList();
    for (final line in reads) {
      say('refresh: ${line.substring(line.indexOf(' ') + 1)}');
    }
    expect(reads, hasLength(1), reason: 'one refresh per sync');
    expect(reads.single, contains('1 of'), reason: 'only the changed one read');

    final cache = File(p.join(copy.path, 'playlists.json'));
    expect(cache.readAsStringSync(), isNot(contains('"url"')));

    player.player.pause();
    await tester.pump(const Duration(seconds: 1));
    say('PASSED');
  });
}
