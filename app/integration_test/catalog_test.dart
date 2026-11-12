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
// the account as they were. Then the same + in an album's place (C4: + on
// one song the library lacks, "Add the other N" for the rest, the album then
// lists them as own songs, a sync adds nothing) and in a song's Versions (+ on
// another upload, none on VK's own file), each removed again the same way.
// Between them (C4b, changes nothing): a found song plays, the album name on
// its row opens its album from VK, whose row of it keeps the playing mark;
// then your own songs in search fold to their header and unfold (C4d); then
// songs VK has with question-mark names show under their real names (the
// names of VK's own release of each).
// Prints names, counts and times only: no link, key, token or id.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/stat_text.dart';
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
    addTearDown(() async {
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
    library.searchText.clear();
    await tester.pump();

    /// Deletes every copy this run added from VK, marks them removed, and
    /// syncs: the account and the library are as at the start.
    Future<void> removeAdded(String what) async {
      final keys = [
        for (final t in library.all)
          if (!keysListed.contains(t.sourceKey)) t.sourceKey!,
      ];
      for (final key in keys) {
        expect(
          await deleteVkSong(client.call, key),
          isTrue,
          reason: 'VK removed the copy',
        );
      }
      expect(catalog.store.markRemoved(account.id, keys), keys.length);
      catalog.onLibraryChanged(severalAccounts: false);
      await tester.pump();
      expect(library.all.length, listedBefore);
      final last = await sync.syncNow().timeout(const Duration(minutes: 3));
      await tester.pump();
      final lastResult = last!.results.single;
      final (vkAfter, _) = await vkLibrary();
      say(
        '$what removed (${keys.length}): VK $vkAfter songs, sync listed '
        '${lastResult.listed}, added ${lastResult.added}; library '
        '${library.all.length} songs listed',
      );
      expect(vkAfter, vkBefore);
      expect(lastResult.added, 0);
      expect(library.all.length, listedBefore);
      expect(
        library.all.where((t) => !keysListed.contains(t.sourceKey)),
        isEmpty,
      );
    }

    await removeAdded('found song');

    // 5b. A found song's album opens from search (C4b): the found song
    // plays, a click on the album name on its row opens the album's place,
    // VK lists the album through the link on the found song, and the
    // album's row of the playing song keeps the playing mark. Changes
    // nothing on VK.
    library.searchText.text = query;
    await tester.pump();
    await waitUntil(
      tester,
      () => !catalog.searching,
      timeout: const Duration(seconds: 30),
      what: 'the On VK part again',
    );
    final withAlbum = [
      for (final f in catalog.songs)
        if (library.albumOf(f.track) != null &&
            catalog.stateOf(f) == FoundState.addable &&
            f.song.durationSec >= 60)
          f,
    ];
    say(
      'found songs with an album to open: ${withAlbum.length} of '
      '${catalog.songs.length}',
    );
    expect(withAlbum, isNotEmpty);
    var albumChecked = false;
    for (final f in withAlbum.take(3)) {
      final foundRow = find.byKey(ValueKey('found-${f.track.id}'));
      while (foundRow.evaluate().isEmpty &&
          scroll.offset < scroll.position.maxScrollExtent) {
        scroll.jumpTo(
          (scroll.offset + 300).clamp(0, scroll.position.maxScrollExtent),
        );
        await tester.pump();
      }
      await tester.ensureVisible(foundRow);
      await tester.pump();
      final foundTimings = <PlayTiming>[];
      final foundListening = player.timings.listen(foundTimings.add);
      await tester.tap(foundRow);
      await tester.pump();
      await waitUntil(
        tester,
        () => foundTimings.isNotEmpty,
        timeout: const Duration(seconds: 60),
        what: 'the found song to sound',
      );
      await foundListening.cancel();
      expect(foundTimings.last.ok, isTrue);
      expect(player.current?.id, f.track.id);
      final albumName = find.descendant(
        of: foundRow,
        matching: find.text(f.song.album!),
      );
      expect(albumName, findsOneWidget, reason: 'the album name on the row');
      clock = Stopwatch()..start();
      await tester.tap(albumName);
      await tester.pump();
      expect(library.view.kind, ViewKind.album, reason: 'the album opened');
      await waitUntil(
        tester,
        () => library.albumStatus?.load != AlbumLoad.loading,
        timeout: const Duration(seconds: 30),
        what: "the found song's album from VK",
      );
      final openMs = clock.elapsedMilliseconds;
      final loaded = library.albumStatus?.load;
      final songs = library.visible;
      // The album's own file, or (mostly) the album's song of which the
      // found song is an upload: the same VK recording.
      final recording = f.song.vkTrackId;
      final same = songs
          .where(
            (t) =>
                t.sourceKey == f.key ||
                recording != null && library.albumVkTrackIdOf(t) == recording,
          )
          .toList();
      say(
        'album "${f.song.album}" of "${f.song.title}": $loaded after '
        '$openMs ms, ${songs.length} songs, ${songs.where((t) => t.inLibrary).length} '
        'own, the found song listed: ${same.isNotEmpty} (same file: '
        '${same.any((t) => t.sourceKey == f.key)}, VK track id known: '
        '${recording != null})',
      );
      expect(loaded, AlbumLoad.loaded, reason: 'VK listed the album');
      expect(songs, isNotEmpty);
      if (same.isNotEmpty) {
        final albumRow = find.byKey(ValueKey('song-${same.first.id}'));
        // The list builds the rows on screen only: scroll to it first.
        final at = library.visible.indexOf(same.first);
        scroll.jumpTo(
          (at * rowHeight).clamp(0, scroll.position.maxScrollExtent),
        );
        await tester.pump();
        await tester.ensureVisible(albumRow);
        await tester.pump();
        expect(
          find.descendant(
            of: albumRow,
            matching: find.byKey(const ValueKey('playing-bars')),
          ),
          findsOneWidget,
          reason: "the playing mark on the album's row of the found song",
        );
        say('playing mark on its album row: yes');
        albumChecked = true;
      }
      // Back: the search with its words.
      library.goBack();
      await tester.pump();
      expect(library.view.kind, ViewKind.songs);
      expect(library.searchText.text, query);
      if (albumChecked) break;
    }
    expect(albumChecked, isTrue, reason: 'an album listed its found song');
    await player.stop();
    library.searchText.clear();
    await tester.pump();

    // 5c. Your own songs in search fold to their header (C4d): an artist
    // the test account has, so own songs and the On VK part both show.
    library.searchText.text = 'дайте танк';
    await tester.pump();
    await waitUntil(
      tester,
      () => !catalog.searching,
      timeout: const Duration(seconds: 30),
      what: 'the On VK part for the artist',
    );
    final ownMatches = library.visible.length;
    expect(ownMatches, greaterThan(0), reason: 'the test account has them');
    expect(find.byKey(const ValueKey('own-header')), findsOneWidget);
    final firstOwn = find.byKey(ValueKey('song-${library.visible.first.id}'));
    expect(firstOwn, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    expect(firstOwn, findsNothing, reason: 'folded');
    expect(find.byKey(const ValueKey('catalog-header')), findsOneWidget);
    expect(catalog.store.readSetting(catalogOwnFoldedSetting), 'folded');
    // With your own songs folded, the On VK rows are on screen: a found song
    // the library has shows that copy's Last played and Added, not empty
    // cells (user 2026-11-12: "added is not listed ... on songs that are ON
    // VK in search, that i already have added").
    final filters = library.filters!;
    final haveIndex = catalog.songs
        .take(6)
        .toList()
        .indexWhere((f) => catalog.stateOf(f) == FoundState.inLibrary);
    expect(haveIndex, isNot(-1), reason: 'VK finds a song the account has');
    final have = catalog.songs[haveIndex];
    final haveCopy = catalog.libraryCopyOf(have.track.id)!;
    Finder inFoundRow(String text) => find.descendant(
      of: find.byKey(ValueKey('found-${have.track.id}')),
      matching: find.text(text),
    );
    final lastPlayed = lastPlayedText(
      filters.allTimePlays(haveCopy.id)?.lastMs,
      filters.now,
    );
    expect(inFoundRow(lastPlayed), findsOneWidget, reason: 'Last played');
    final addedShown = inFoundRow(dayText(haveCopy.addedAt))
        .evaluate()
        .isNotEmpty;
    say(
      'found song you have: row ${haveIndex + 1} shows Last played '
      '"$lastPlayed"${addedShown ? ' and Added ${dayText(haveCopy.addedAt)}' : ' (window too narrow for Added)'}',
    );
    // A new search keeps it folded.
    library.searchText.text = 'дайте';
    await tester.pump();
    expect(catalog.ownFolded, isTrue);
    expect(find.byKey(const ValueKey('own-header')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('own-header')));
    await tester.pump();
    expect(
      find.byKey(ValueKey('song-${library.visible.first.id}')),
      findsOneWidget,
      reason: 'unfolded again',
    );
    expect(catalog.store.readSetting(catalogOwnFoldedSetting), isNull);
    say('own songs header: $ownMatches songs, folded and unfolded, kept');
    library.searchText.clear();
    await tester.pump();

    // 5d. Songs VK has with question-mark names (old zaycev.net uploads,
    // "?4??4??1?") show as VK's own release of the song, with its real
    // names. VK's raw first page for the same words is read alongside: it
    // must hold such songs, or this step proves nothing.
    const brokenQuery = 'zaycev.net';
    final raw = await client.call('audio.search', {
      'q': brokenQuery,
      'count': '$vkSearchPageSize',
      'offset': '0',
    }) as Map<String, dynamic>;
    bool rawBroken(Map<String, dynamic> item) =>
        isQuestionMarkName(item['artist'] as String? ?? '') ||
        isQuestionMarkName(item['title'] as String? ?? '');
    final rawItems = (raw['items'] as List).cast<Map<String, dynamic>>();
    final brokenTracks = {
      for (final item in rawItems)
        if (rawBroken(item) && item['track_id'] is int) item['track_id'] as int,
    };
    final rawBrokenCount = rawItems.where(rawBroken).length;
    expect(rawBrokenCount, greaterThan(0), reason: 'VK still has such songs');
    clock = Stopwatch()..start();
    library.searchText.text = brokenQuery;
    await tester.pump();
    await waitUntil(
      tester,
      () => !catalog.searching,
      timeout: const Duration(seconds: 30),
      what: 'the On VK part for $brokenQuery',
    );
    expect(catalog.error, isNull, reason: 'VK answered');
    final shown = catalog.songs;
    bool shownBroken(FoundSong f) =>
        isQuestionMarkName(f.song.artist) || isQuestionMarkName(f.song.title);
    final stillBroken = shown.where(shownBroken).length;
    final renamed = shown
        .where(
          (f) => !shownBroken(f) && brokenTracks.contains(f.song.vkTrackId),
        )
        .length;
    // Any song VK gave no release for sits at the end.
    final firstBroken = shown.indexWhere(shownBroken);
    if (firstBroken >= 0) {
      expect(
        shown.skip(firstBroken).every(shownBroken),
        isTrue,
        reason: 'question-mark songs only at the end',
      );
    }
    expect(renamed, greaterThan(0), reason: 'shown with their real names');
    expect(stillBroken, lessThan(rawBrokenCount));
    // The rows draw the real names (when the first such row is on screen:
    // the list builds only the rows in view).
    final firstRenamed = shown.indexWhere(
      (f) => !shownBroken(f) && brokenTracks.contains(f.song.vkTrackId),
    );
    if (firstRenamed < 6) {
      expect(
        find.textContaining(shown[firstRenamed].song.title),
        findsWidgets,
        reason: 'the row shows the release title',
      );
    }
    say(
      'question-mark names: VK page has $rawBrokenCount, the app shows '
      '$renamed under their real names and $stillBroken as VK has them '
      '(${shown.length} songs, ${clock.elapsedMilliseconds} ms with the '
      '0.5 s pause)',
    );
    library.searchText.clear();
    await tester.pump();

    // 6. An album's place (C4): + on a song the library lacks, then "Add
    // the other N" for the rest; the album then lists them as own songs.
    final albumSong = library.all.firstWhere((t) => t.album == 'Человеко-часы');
    library.openAlbum(albumSong);
    await tester.pump();
    await waitUntil(
      tester,
      () => library.albumStatus?.load != AlbumLoad.loading,
      what: 'the album from VK',
    );
    expect(library.albumStatus?.load, AlbumLoad.loaded);
    final albumSize = library.visible.length;
    final lacking = library.visible.where((t) => !t.inLibrary).toList();
    say(
      'album "Человеко-часы": $albumSize songs, ${lacking.length} not in the '
      'library',
    );
    expect(lacking.length, greaterThanOrEqualTo(2));
    final firstLacking = lacking.first;
    final albumRow = find.byKey(ValueKey('song-${firstLacking.id}'));
    await tester.ensureVisible(albumRow);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('album-add-all')),
      findsOneWidget,
      reason: 'Add the other N',
    );
    expect(find.text('Add the other ${lacking.length}'), findsOneWidget);
    // The song plays first (user, 2026-11-12: "when i add the song that i
    // listened to in the album its playing animation disappeared").
    final albumTimings = <PlayTiming>[];
    final albumListening = player.timings.listen(albumTimings.add);
    addTearDown(albumListening.cancel);
    await tester.tap(albumRow);
    await tester.pump();
    await waitUntil(
      tester,
      () => albumTimings.isNotEmpty,
      timeout: const Duration(seconds: 60),
      what: 'the album song to sound',
    );
    expect(albumTimings.last.ok, isTrue, reason: '${albumTimings.last.error}');
    expect(albumTimings.last.sampleRate, isNotNull);
    await waitUntil(
      tester,
      () => player.position >= const Duration(seconds: 2),
      timeout: const Duration(seconds: 30),
      what: 'the album song to move past 2 s',
    );
    Finder barsIn(Finder row) => find.descendant(
      of: row,
      matching: find.byKey(const ValueKey('playing-bars')),
    );
    expect(barsIn(albumRow), findsOneWidget, reason: 'marked while it plays');
    final playedBefore = player.position;
    clock = Stopwatch()..start();
    await tester.tap(
      find.descendant(
        of: albumRow,
        matching: find.byKey(const ValueKey('add-song')),
      ),
    );
    await tester.pump();
    await waitUntil(
      tester,
      () =>
          library.visible.any(
            (t) => t.inLibrary && t.title == firstLacking.title,
          ) &&
          library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 30),
      what: 'the album to list the added song as its own',
    );
    say(
      'album +: "${firstLacking.title}" added and listed as own after '
      '${clock.elapsedMilliseconds} ms',
    );
    expect(library.visible.length, albumSize, reason: 'no row twice');
    await tester.pump(const Duration(milliseconds: 600));
    final ownCopy = library.visible.firstWhere(
      (t) => t.inLibrary && t.title == firstLacking.title,
    );
    final ownRow = find.byKey(ValueKey('song-${ownCopy.id}'));
    await tester.ensureVisible(ownRow);
    await tester.pump();
    final markKept = barsIn(ownRow).evaluate().length;
    final positionAfter = player.position;
    say(
      'album + while playing: player has the library copy '
      '${player.current?.id == ownCopy.id}, mark on its row $markKept, '
      'position ${playedBefore.inMilliseconds} -> '
      '${positionAfter.inMilliseconds} ms, playing ${player.playing.value}',
    );
    expect(player.current?.id, ownCopy.id);
    expect(markKept, 1, reason: 'the playing mark stays on the row');
    expect(player.playing.value, isTrue, reason: 'the sound goes on');
    expect(positionAfter, greaterThan(playedBefore), reason: 'not restarted');
    await player.stop();
    await tester.pump();
    final rest = lacking.length - 1;
    expect(find.text('Add the other $rest'), findsOneWidget);
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('album-add-all')));
    await tester.pump();
    await waitUntil(
      tester,
      () =>
          library.visible.every((t) => t.inLibrary) &&
          library.all.length == listedBefore + lacking.length,
      timeout: const Duration(seconds: 60),
      what: 'Add the other $rest',
    );
    await tester.pump(const Duration(milliseconds: 600));
    say(
      'album Add the other $rest: all listed as own after '
      '${clock.elapsedMilliseconds} ms',
    );
    expect(library.visible.length, albumSize, reason: 'no row twice');
    expect(find.byKey(const ValueKey('album-add-all')), findsNothing);
    expect(find.text('Added $rest songs to ${account.name}'), findsOneWidget);
    final (vkAlbum, _) = await vkLibrary();
    expect(vkAlbum, vkBefore + lacking.length);
    final albumSync = await sync.syncNow().timeout(const Duration(minutes: 3));
    await tester.pump();
    say(
      'sync after the album: listed ${albumSync!.results.single.listed}, '
      'added ${albumSync.results.single.added}; album '
      '${library.visible.length} rows, all own: '
      '${library.visible.every((t) => t.inLibrary)}',
    );
    expect(albumSync.results.single.added, 0);
    expect(library.all.length, listedBefore + lacking.length);
    expect(library.visible.length, albumSize);
    expect(library.visible.every((t) => t.inLibrary), isTrue);
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pump();
    await removeAdded('album songs');

    // 7. A song's Versions (C4): + on another upload, none on VK's own file.
    final versionsOf = library.all.firstWhere(
      (t) => t.title == 'Way Down We Go',
    );
    library.openVersions(
      versionsOf,
      player.ownRoutesFor(versionsOf).firstOrNull,
    );
    await tester.pump();
    final list = library.versionList!;
    await waitUntil(
      tester,
      () => !list.searching,
      timeout: const Duration(seconds: 60),
      what: 'the versions from VK',
    );
    await tester.pump();
    final rows = library.visible;
    final current = rows.firstWhere((t) => library.versionOf(t)!.isCurrentFile);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('song-${current.id}')),
        matching: find.byKey(const ValueKey('add-song')),
      ),
      findsNothing,
      reason: "no + on VK's own file",
    );
    final withAdd = [
      for (final t in rows)
        if (find
            .descendant(
              of: find.byKey(ValueKey('song-${t.id}')),
              matching: find.byKey(const ValueKey('add-song')),
            )
            .evaluate()
            .isNotEmpty)
          t,
    ];
    say(
      'versions of "${versionsOf.title}": ${rows.length} rows, + on '
      '${withAdd.length} shown',
    );
    expect(withAdd, isNotEmpty);
    final chosen = withAdd.first;
    final chosenVersion = library.versionOf(chosen)!;
    clock = Stopwatch()..start();
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('song-${chosen.id}')),
        matching: find.byKey(const ValueKey('add-song')),
      ),
    );
    await tester.pump();
    await waitUntil(
      tester,
      () =>
          find
              .descendant(
                of: find.byKey(ValueKey('song-${chosen.id}')),
                matching: find.byKey(const ValueKey('song-added')),
              )
              .evaluate()
              .isNotEmpty &&
          library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 30),
      what: 'the upload added',
    );
    await tester.pump(const Duration(milliseconds: 600));
    say(
      'versions +: upload of ${chosenVersion.listedSec} s added after '
      '${clock.elapsedMilliseconds} ms; still on Versions: '
      '${library.view.kind == ViewKind.versions}',
    );
    expect(library.view.kind, ViewKind.versions);
    final (vkVersion, _) = await vkLibrary();
    expect(vkVersion, vkBefore + 1);
    final versionSync = await sync.syncNow().timeout(
      const Duration(minutes: 3),
    );
    await tester.pump();
    expect(versionSync!.results.single.added, 0);
    expect(library.all.length, listedBefore + 1);
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pump();
    await removeAdded('upload');
    say('catalog check passed');
  });
}
