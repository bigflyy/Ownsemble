// Real check of search place A's On VK part (plan 06, C3): the real app, real
// VK, muted, off-screen. TEST ACCOUNT ONLY: it adds one song to the account
// and removes it again in the same run.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/catalog_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-catalog", replaced on
// every run) with nothing stored. Steps: type a Cyrillic query; the own
// results show at once and the On VK part fills in under them; a found song
// that is not in the library plays with a click on its row (a stream,
// decoded: a sample rate and a moving position, mpv's length as VK lists
// it); + on its row adds it (the check, the note, one more song in the
// library and on VK); the next sync keeps one row for it; then the song is
// deleted on VK and marked removed, and one more sync leaves the library and
// the account as they were. Prints names, counts and times only: no link,
// key, token or id.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');

/// The words searched: Cyrillic, so the round trip to VK and back is
/// checked; VK finds many songs for them (tool/check_vk_catalog.dart).
const query = 'Наутилус Помпилиус';

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

  testWidgets('search VK, play a found song, add it, remove it', (
    tester,
  ) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    // A fresh copy of the library alone: no stored audio, so songs stream.
    final copy = Directory('$dataDir-catalog');
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

    // VK as the test account, apart from the app: counts before and after,
    // and the cleanup of anything this run added.
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
    // Whatever this run leaves on the account is removed at the end, even
    // when a step fails.
    var cleaned = false;
    addTearDown(() async {
      if (cleaned) return;
      final (_, keysNow) = await vkLibrary();
      for (final key in keysNow.difference(keysBefore)) {
        final ok = await deleteVkSong(client.call, key);
        say('cleanup: removed a copy left behind: $ok');
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
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.synced.timeout(const Duration(minutes: 3));
    await tester.pump();
    final listedBefore = library.all.length;
    final keysListed = {for (final t in library.all) t.sourceKey};
    say('library before: $listedBefore songs listed');
    expect(catalog.accounts, hasLength(1), reason: 'the test account only');
    final account = catalog.targets.single;

    // 1. The query: own results at once, the On VK part after the pause.
    var clock = Stopwatch()..start();
    library.searchText.text = query;
    await tester.pump();
    final ownMs = clock.elapsedMilliseconds;
    final own = library.visible.length;
    say('own results: $own songs in $ownMs ms (debug build)');
    expect(catalog.active, isTrue, reason: 'the On VK part is shown');
    expect(catalog.query, query, reason: 'Cyrillic kept as typed');
    expect(find.byKey(const ValueKey('catalog-header')), findsOneWidget);
    clock = Stopwatch()..start();
    await waitUntil(
      tester,
      () => !catalog.searching,
      timeout: const Duration(seconds: 30),
      what: 'the On VK part',
    );
    final partMs = clock.elapsedMilliseconds;
    expect(catalog.error, isNull, reason: 'VK answered');
    final found = catalog.songs;
    say(
      'On VK: ${found.length} songs of ${catalog.total} after $partMs ms '
      '(0.5 s pause included), more: ${catalog.hasMore}',
    );
    expect(found, isNotEmpty);
    expect(
      found.every((f) => f.song.artist.isNotEmpty && f.song.title.isNotEmpty),
      isTrue,
    );
    expect(
      found.any((f) => f.song.artist.toLowerCase().contains('наутилус')),
      isTrue,
      reason: 'Cyrillic names came back readable',
    );
    final inLibrary = found
        .where((f) => catalog.stateOf(f) == FoundState.inLibrary)
        .length;
    say('found songs already in the library (check, no +): $inLibrary');

    // 2. A found song outside the library plays with a click on its row.
    final pick = found.firstWhere(
      (f) =>
          catalog.stateOf(f) == FoundState.addable &&
          f.song.durationSec >= 60 &&
          !keysListed.contains(f.key),
    );
    final track = pick.track;
    say(
      'picked: ${pick.song.artist} - ${pick.song.title} '
      '(${pick.song.durationSec} s, row ${found.indexOf(pick) + 1})',
    );
    final row = find.byKey(ValueKey('found-${track.id}'));
    final scroll = library.scroll;
    while (row.evaluate().isEmpty &&
        scroll.offset < scroll.position.maxScrollExtent) {
      scroll.jumpTo(
        (scroll.offset + 300).clamp(0, scroll.position.maxScrollExtent),
      );
      await tester.pump();
    }
    await tester.ensureVisible(row);
    await tester.pump();
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('add-song')),
      ),
      findsOneWidget,
      reason: '+ on the row',
    );
    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    await tester.tap(row);
    await tester.pump();
    await waitUntil(
      tester,
      () => timings.isNotEmpty,
      timeout: const Duration(seconds: 60),
      what: 'the found song to sound',
    );
    final timing = timings.last;
    expect(timing.ok, isTrue, reason: 'error: ${timing.error}');
    expect(player.current?.id, track.id);
    expect(timing.cached, isFalse, reason: 'a found song streams');
    expect(timing.sampleRate, isNotNull, reason: 'mpv decoded the audio');
    final mpv = player.player.platform as NativePlayer;
    expect(await mpv.getProperty('mute'), 'yes', reason: 'agent runs muted');
    double? length;
    for (var i = 0; i < 30 && length == null; i++) {
      final value = double.tryParse(await mpv.getProperty('duration'));
      if (value != null && value > 0) length = value;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    await waitUntil(
      tester,
      () => player.position >= const Duration(seconds: 3),
      timeout: const Duration(seconds: 30),
      what: 'the found song to move past 3 s',
    );
    say(
      'played: sound in ${timing.toSoundMs} ms (network first chunk '
      '${timing.networkFirstChunkMs} ms), ${timing.sampleRate} Hz, mpv '
      'length ${length?.toStringAsFixed(1)} s of ${pick.song.durationSec} s, '
      'position ${player.position.inMilliseconds} ms',
    );
    expect(length, isNotNull);
    expect((length! - pick.song.durationSec).abs(), lessThan(1.5));
    expect(timing.sourceId, account.id, reason: 'through the test account');
    final adds = find.byKey(ValueKey('add-${track.id}'));
    say('+ buttons for the playing found song: ${adds.evaluate().length}');
    expect(adds.evaluate().length, 2, reason: '+ on the row and in the player');

    // 3. + on the row adds it: the check, the note, one more song.
    clock = Stopwatch()..start();
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('add-song')),
      ),
    );
    await tester.pump();
    await waitUntil(
      tester,
      () => catalog.stateOf(pick) == FoundState.inLibrary,
      timeout: const Duration(seconds: 30),
      what: 'VK to add the song',
    );
    final addMs = clock.elapsedMilliseconds;
    await waitUntil(
      tester,
      () => library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 10),
      what: 'the library to list the added song',
    );
    await tester.pump(const Duration(milliseconds: 400));
    say('added in $addMs ms; library ${library.all.length} songs listed');
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('song-added')),
      ),
      findsOneWidget,
      reason: 'the check on the row',
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('found-cloud')),
      ),
      findsOneWidget,
      reason: 'the globe turned into the cloud',
    );
    expect(
      find.textContaining('Added "${pick.song.title}" to ${account.name}'),
      findsOneWidget,
      reason: 'the note at the bottom',
    );
    final added = library.all
        .where((t) => !keysListed.contains(t.sourceKey))
        .toList();
    expect(added, hasLength(1));
    final newKey = added.single.sourceKey!;
    expect(newKey, isNot(pick.key), reason: "the account's own copy");
    expect(added.single.title, pick.song.title);
    final (vkAdded, keysAdded) = await vkLibrary();
    say('VK after +: $vkAdded songs');
    expect(vkAdded, vkBefore + 1);
    expect(keysAdded.difference(keysBefore), {newKey});

    // 4. The next sync matches the row instead of adding it twice.
    clock = Stopwatch()..start();
    final first = await sync.syncNow().timeout(const Duration(minutes: 3));
    await tester.pump();
    final result = first!.results.single;
    say(
      'sync after +: ${clock.elapsedMilliseconds} ms, VK listed '
      '${result.listed}, added ${result.added}, newly gone '
      '${result.newlyGone}; library ${library.all.length} songs listed',
    );
    expect(first.errors, isEmpty);
    expect(result.listed, vkBefore + 1);
    expect(result.added, 0, reason: 'the added row was matched');
    expect(library.all.length, listedBefore + 1);
    expect(
      library.all.where((t) => t.sourceKey == newKey),
      hasLength(1),
      reason: 'one row for the added song',
    );
    expect(
      library.all.where(
        (t) => t.title == pick.song.title && t.artist == pick.song.artist,
      ),
      hasLength(1),
    );

    // 5. Removed again: off VK, marked removed, and the sync agrees.
    await player.stop();
    final deleted = await deleteVkSong(client.call, newKey);
    expect(deleted, isTrue, reason: 'VK removed the copy');
    cleaned = true;
    expect(catalog.store.markRemoved(account.id, [newKey]), 1);
    catalog.onLibraryChanged(severalAccounts: false);
    await tester.pump();
    expect(library.all.length, listedBefore);
    final last = await sync.syncNow().timeout(const Duration(minutes: 3));
    await tester.pump();
    final lastResult = last!.results.single;
    final (vkAfter, _) = await vkLibrary();
    say(
      'after removal: VK $vkAfter songs, sync listed ${lastResult.listed}, '
      'added ${lastResult.added}; library ${library.all.length} songs listed',
    );
    expect(vkAfter, vkBefore);
    expect(lastResult.added, 0);
    expect(library.all.length, listedBefore);
    expect(library.all.where((t) => t.sourceKey == newKey), isEmpty);
    library.searchText.clear();
    await tester.pump();
    say('catalog check passed');
  });
}
