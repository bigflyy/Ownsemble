// Real check of the Artists place and an artist's page (plan 09, E1): the
// real app, real VK, muted, off-screen. TEST ACCOUNT ONLY: it adds one
// Popular song to the library and removes it again in the same run (the
// library ends at the count it started with).
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/artists_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-artists", replaced on
// every run) with no stored audio and no artist photos. Steps: the sync at
// start ends (it fills in the artist credits); the Artists place opens and
// VK's photos arrive for the tiles; an artist's page opens from its tile
// with VK's part (Popular, Releases, You may like); Play plays a library
// song (decoded); a Popular song the library lacks streams (decoded); + adds
// it and the page shows it as the library's at once; Remove takes it out
// (VK back to its count); a release opens as an album place; a similar
// artist's page opens by its address name; an artist name in a song row
// opens that artist's page. Prints names, counts and times only: no link,
// key, token or id (failures compare ids in memory).

import 'dart:io';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/artist_page.dart' show artistPopularShown, vkRefOf;
import 'package:ownsemble/ui/artists.dart';
import 'package:ownsemble/ui/card_play.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';
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

  testWidgets('Artists: place, photos, page, play, stream, add, remove, '
      'release, similar, name link', (tester) async {
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
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final copy = Directory('$dataDir-artists');
    if (copy.existsSync()) copy.deleteSync(recursive: true);
    copy.createSync(recursive: true);
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm']) {
      final file = File(p.join(dataDir, name));
      if (file.existsSync()) file.copySync(p.join(copy.path, name));
    }
    final copied = sqlite3.open(p.join(copy.path, 'library.db'));
    copied.execute('DELETE FROM audio_files');
    // No stored photos: the place must ask VK for them. (An old library
    // has no such table yet: the app makes it.)
    final hasPhotos = copied
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'artist_photos'",
        )
        .isNotEmpty;
    if (hasPhotos) copied.execute('DELETE FROM artist_photos');
    copied.close();

    final client = VkClient(SessionCookie.loadAll(File(session)));
    await client.ensureToken();
    final me = client.userId;
    // The test's own reads of the account: VK is sometimes silent for 15 s
    // (artists-34c), so one more try before the run fails on it.
    Future<(int, Set<String>)> vkLibrary() async {
      Future<Object?> read() =>
          client.call('audio.get', {'owner_id': '$me', 'count': '1000'});
      Object? answer;
      try {
        answer = await read();
      } on VkException catch (error) {
        say('VK read of the account failed once (${error.runtimeType}): again');
        answer = await read();
      }
      final reply = answer! as Map<String, dynamic>;
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
    // The copy + makes: the only song cleanup may delete.
    String? addedKey;
    addTearDown(() async {
      final key = addedKey;
      if (key == null) return;
      final (_, keysNow) = await vkLibrary();
      if (!keysNow.contains(key)) return;
      final ok = await deleteVkSong(client.call, key);
      say('cleanup: removed the copy left behind: $ok');
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
    final artists = screen.artists!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.idle.timeout(const Duration(minutes: 5));
    await tester.pump();
    expect(sync.lastOutcome?.error, isNull, reason: 'the start sync worked');
    final listedBefore = library.all.length;
    say('library before: $listedBefore songs listed');

    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);

    /// Waits for a play after [before] timings to sound and checks it was
    /// decoded.
    Future<PlayTiming> sounded(String what, int before) async {
      await waitUntil(
        tester,
        () => timings.length > before,
        timeout: const Duration(seconds: 60),
        what: '$what to sound',
      );
      final timing = timings.last;
      expect(timing.ok, isTrue, reason: '$what: error ${timing.error}');
      expect(timing.sampleRate, isNotNull, reason: 'mpv decoded $what');
      await waitUntil(
        tester,
        () => player.position >= const Duration(seconds: 3),
        timeout: const Duration(seconds: 30),
        what: '$what to move past 3 s',
      );
      return timing;
    }

    Finder scrollableOf(Finder view) =>
        find.descendant(of: view, matching: find.byType(Scrollable)).first;

    // 1. The place: the grid, then VK's photos for the tiles.
    var clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('nav-artists')));
    await tester.pump();
    final placeMs = clock.elapsedMilliseconds;
    expect(library.view.kind, ViewKind.artists);
    final grid = find.byKey(const ValueKey('artists-grid'));
    expect(grid, findsOneWidget);
    final shown = artists.shown('');
    final withId = shown.where((a) => !a.nameOnly).toList();
    say(
      'place: ${shown.length} artists (${withId.length} with a VK id) in '
      '$placeMs ms (debug build); first: '
      '${shown.take(5).map((a) => '${a.name} ${a.songs.length}').join(', ')}',
    );
    expect(withId, isNotEmpty);
    clock = Stopwatch()..start();
    int drawn() => find
        .descendant(of: grid, matching: find.byType(RawImage))
        .evaluate()
        .where((e) => (e.widget as RawImage).image != null)
        .length;
    await waitUntil(
      tester,
      () => drawn() > 0,
      timeout: const Duration(seconds: 60),
      what: 'the grid to draw a photo',
    );
    final firstPhotoMs = clock.elapsedMilliseconds;
    Iterable<Artist> tilesInSight() => shown.where(
      (a) => find.byKey(ValueKey('artist-${a.key}')).evaluate().isNotEmpty,
    );
    int inSight() => tilesInSight().length;
    int inSightWithPhoto() =>
        tilesInSight().where((a) => artists.photoOf(a)?.large != null).length;
    // The ones the place asks for while it is open (the tiles in sight
    // first, then the rest), and how many of those in sight are drawn.
    final timeline = <String>[];
    for (var second = 1; second <= 20; second++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      timeline.add('${drawn()}/${inSightWithPhoto()}');
    }
    say('photos drawn / in sight with one, each second: ${timeline.join(' ')}');
    expect(
      drawn() >= inSightWithPhoto(),
      isTrue,
      reason: 'every tile in sight with a photo draws it within 20 s',
    );
    final asked = withId.where((a) => artists.photoOf(a) != null).toList();
    final found = asked.where((a) => artists.photoOf(a)!.large != null);
    say(
      'photos: first drawn in $firstPhotoMs ms; after 5 s more '
      '${asked.length} of ${withId.length} asked, ${found.length} with a '
      'photo, ${drawn()} drawn of ${inSightWithPhoto()} tiles in sight that '
      'have one (${inSight()} tiles in sight)',
    );
    expect(found, isNotEmpty, reason: 'VK gives photos for some artists');

    // 2. An artist's page from its tile: the first artist (grid order)
    // whose page has a Popular song the library lacks and similar artists.
    Artist? picked;
    var page = artists.vkOf('0').page;
    var sourceId = 0;
    var tried = 0;
    for (final candidate in withId.take(12)) {
      tried++;
      final tile = find.byKey(ValueKey('artist-${candidate.key}'));
      await tester.scrollUntilVisible(
        tile,
        300,
        scrollable: scrollableOf(grid),
      );
      clock = Stopwatch()..start();
      await tester.tap(tile);
      await tester.pump();
      expect(library.view.kind, ViewKind.artist);
      expect(library.view.artist == candidate.key, isTrue, reason: 'its page');
      expect(find.byKey(const ValueKey('artist-page-name')), findsOneWidget);
      final ref = vkRefOf(candidate.key, candidate)!;
      await waitUntil(
        tester,
        () => artists.vkOf(ref).load != ArtistVkLoad.loading,
        timeout: const Duration(seconds: 30),
        what: "VK's part of the page",
      );
      final vk = artists.vkOf(ref);
      expect(vk.load, ArtistVkLoad.loaded, reason: 'VK: ${vk.error}');
      final vkPage = vk.page!;
      final popular = artists.popularTracks(vkPage, vk.sourceId!);
      final outside = popular
          .take(artistPopularShown)
          .where((t) => library.byId(t.id) == null && !t.inLibrary)
          .where((t) => artists.outside.libraryCopyOf(t.id) == null)
          .length;
      say(
        'page "${candidate.name}" (${candidate.songs.length} own songs, '
        '${candidate.albums.length} albums): VK in '
        '${clock.elapsedMilliseconds} ms, ${popular.length} popular '
        '($outside shown the library lacks), ${vkPage.releases.length} '
        'releases, ${vkPage.similar.length} similar',
      );
      if (outside > 0 && vkPage.similar.isNotEmpty) {
        picked = candidate;
        page = vkPage;
        sourceId = vk.sourceId!;
        break;
      }
      library.goBack();
      await tester.pump();
      expect(library.view.kind, ViewKind.artists);
    }
    expect(picked, isNotNull, reason: 'no fitting artist in $tried tried');
    final artist = picked!;
    final pageView = find.byKey(ValueKey('artist-page-${artist.key}'));
    final pageScroll = scrollableOf(pageView);
    final perf = File(p.join(copy.path, 'perf.log')).readAsLinesSync();
    for (final line in perf.where((l) => l.contains('artist'))) {
      say('perf: ${line.substring(line.indexOf(' ') + 1)}');
    }

    // 3. Play: a library song of the artist, decoded.
    var before = timings.length;
    await tester.tap(find.byKey(const ValueKey('artist-play')));
    await tester.pump();
    var timing = await sounded('the artist\'s library song', before);
    expect(player.current?.inLibrary, isTrue);
    expect(
      artists.index.artistsOf(player.current!.id).map((a) => a.key),
      contains(artist.key),
    );
    say(
      'Play: ${player.current?.artist} - ${player.current?.title}: sound in '
      '${timing.toSoundMs} ms, ${timing.sampleRate} Hz',
    );

    // 3b. While the artist plays, Play shows Pause and pauses and resumes
    // the same song; Shuffle shows it is on and turns it off and on (user,
    // 2026-11-21: "play and shuffle are unresponsive").
    final play = find.byKey(const ValueKey('artist-play'));
    final shuffle = find.byKey(const ValueKey('artist-shuffle'));
    Finder labelled(Finder button, String text) =>
        find.descendant(of: button, matching: find.text(text));
    await tester.pump();
    expect(labelled(play, 'Pause'), findsOneWidget, reason: 'Pause shown');
    final playingSong = player.current;
    await tester.tap(play);
    await waitUntil(
      tester,
      () => !player.playing.value,
      timeout: const Duration(seconds: 5),
      what: 'Pause to pause',
    );
    expect(labelled(play, 'Play'), findsOneWidget, reason: 'Play again');
    final pausedAt = player.position;
    await tester.tap(play);
    await waitUntil(
      tester,
      () => player.playing.value,
      timeout: const Duration(seconds: 5),
      what: 'Play to resume',
    );
    expect(
      identical(player.current, playingSong) ||
          player.current?.id == playingSong?.id,
      isTrue,
      reason: 'same song',
    );
    expect(
      player.position >= pausedAt - const Duration(seconds: 1),
      isTrue,
      reason: 'resumed, not started over',
    );
    expect(labelled(play, 'Pause'), findsOneWidget);
    final shuffleWas = playback.shuffle;
    if (shuffleWas) playback.toggleShuffle();
    await tester.pump();
    await tester.tap(shuffle);
    await tester.pump();
    expect(playback.shuffle, isTrue);
    expect(labelled(shuffle, 'Shuffle on'), findsOneWidget);
    expect(
      player.current?.id == playingSong?.id,
      isTrue,
      reason: 'Shuffle on the playing artist keeps the song',
    );
    await tester.tap(shuffle);
    await tester.pump();
    expect(playback.shuffle, isFalse);
    expect(labelled(shuffle, 'Shuffle'), findsOneWidget);
    if (shuffleWas) playback.toggleShuffle();
    say('Play/Pause and Shuffle on/off on the playing artist: OK');

    // 4. A Popular song the library lacks streams.
    final song = artists
        .popularTracks(page!, sourceId)
        .take(artistPopularShown)
        .firstWhere(
          (t) => !t.inLibrary && artists.outside.libraryCopyOf(t.id) == null,
        );
    final row = find.byKey(ValueKey('page-song-${song.id}'));
    await tester.scrollUntilVisible(row, 200, scrollable: pageScroll);
    await tester.pump();
    before = timings.length;
    await tester.tap(row);
    await tester.pump();
    timing = await sounded('a Popular song', before);
    expect(player.current?.inLibrary, isFalse);
    expect(player.current?.id == song.id, isTrue, reason: 'the clicked song');
    expect(timing.cached, isFalse, reason: 'streamed');
    expect(timing.networkFirstChunkMs, isNotNull, reason: 'streamed');
    say(
      'Popular: ${song.artist} - ${song.title}: sound in ${timing.toSoundMs} '
      'ms (network first chunk ${timing.networkFirstChunkMs} ms), '
      '${timing.sampleRate} Hz',
    );

    // 5. + adds it: the page shows it as the library's at once (R3);
    // Remove takes it out again.
    final add = find.descendant(
      of: row,
      matching: find.byKey(const ValueKey('add-song')),
    );
    expect(add, findsOneWidget, reason: 'the Popular row has +');
    final ownBefore = artist.songs.length;
    final idsBefore = {for (final t in library.all) t.id};
    clock = Stopwatch()..start();
    await tester.tap(add);
    await tester.pump();
    await waitUntil(
      tester,
      () => library.all.length == listedBefore + 1,
      timeout: const Duration(seconds: 30),
      what: 'the library to list the added song',
    );
    final addMs = clock.elapsedMilliseconds;
    final (vkAdded, keysAdded) = await vkLibrary();
    expect(vkAdded, vkBefore + 1);
    final newKeys = keysAdded.difference(keysBefore);
    expect(newKeys.length, 1, reason: 'one copy on VK');
    addedKey = newKeys.single;
    await waitUntil(
      tester,
      () => (artists.artistOf(artist.key)?.songs.length ?? 0) == ownBefore + 1,
      timeout: const Duration(seconds: 10),
      what: 'the page to count the added song',
    );
    final added = library.all.firstWhere((t) => !idsBefore.contains(t.id));
    await tester.pump(const Duration(milliseconds: 500));
    // The Popular row now shows the library's copy with a check (R3).
    expect(
      find.descendant(
        of: find.byKey(ValueKey('page-song-${added.id}')),
        matching: find.byKey(ValueKey('have-${added.id}')),
      ),
      findsOneWidget,
      reason: 'the Popular row shows the copy as yours',
    );
    // The library part counts it and lists it first (newest added).
    final heading = find.text('IN YOUR LIBRARY (${ownBefore + 1})');
    await tester.scrollUntilVisible(heading, -300, scrollable: pageScroll);
    await tester.pump();
    final ownRows = find.byKey(ValueKey('page-song-${added.id}'));
    final check = find.byKey(ValueKey('have-${added.id}'));
    final libraryRows = ownRows.evaluate().where(
      (row) => find
          .descendant(
            of: find.byElementPredicate((e) => e == row),
            matching: check,
          )
          .evaluate()
          .isEmpty,
    );
    expect(
      libraryRows,
      hasLength(1),
      reason: 'the library part lists the copy',
    );
    final libraryRow = libraryRows.single;
    final ownRow = find.byElementPredicate((e) => e == libraryRow);
    say(
      '+ added in $addMs ms; VK $vkAdded songs; the page lists '
      '${ownBefore + 1} own songs, the Popular row has a check',
    );
    // The add's Undo-free settling time, as the other real checks wait.
    await tester.pump(const Duration(seconds: 7));
    await tester.ensureVisible(ownRow);
    await tester.pump();
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
    final (vkAfter, keysAfter) = await vkLibrary();
    say('removed: VK $vkAfter songs, library ${library.all.length}');
    expect(vkAfter, vkBefore);
    expect(
      keysAfter.length == keysBefore.length &&
          keysAfter.containsAll(keysBefore),
      isTrue,
      reason: 'Remove took out the added copy, nothing else',
    );
    await tester.pump(const Duration(seconds: 7));
    expect(artists.artistOf(artist.key)?.songs.length, ownBefore);

    // 6. A release opens as an album place with VK's songs.
    expect(page.releases, isNotEmpty, reason: 'the picked page has releases');
    {
      final release = page.releases.first;
      final card = find.byKey(ValueKey('artist-release-${release.key}'));
      await tester.scrollUntilVisible(card, 200, scrollable: pageScroll);
      await tester.pump();
      clock = Stopwatch()..start();
      await tester.tap(card);
      await tester.pump();
      expect(library.view.kind, ViewKind.album);
      expect(library.view.album?.title, release.title);
      await waitUntil(
        tester,
        () => library.albumStatus?.load != AlbumLoad.loading,
        timeout: const Duration(seconds: 30),
        what: 'the release songs',
      );
      expect(library.albumStatus?.load, AlbumLoad.loaded);
      say(
        'release "${release.title}": ${library.visible.length} songs in '
        '${clock.elapsedMilliseconds} ms, ${library.albumStatus?.inLibrary} '
        'in the library',
      );
      expect(library.visible, isNotEmpty);
      final releaseSongs = library.visible.length;
      library.goBack();
      await tester.pump();
      expect(library.view.kind, ViewKind.artist);
      expect(library.view.artist == artist.key, isTrue, reason: 'Back');

      // 6b. The card's Play (user pick A, 2026-11-21) shows on hover and
      // plays the whole release; the card then shows Pause.
      await tester.scrollUntilVisible(card, 200, scrollable: pageScroll);
      await tester.pump();
      final cardPlay = find.descendant(
        of: card,
        matching: find.byType(CardPlayButton),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(cardPlay));
      await tester.pump(const Duration(milliseconds: 300));
      before = timings.length;
      await tester.tap(cardPlay);
      await tester.pump();
      timing = await sounded('the release from its card', before);
      await mouse.removePointer();
      expect(playback.queue.from?.label, release.title);
      // Every song its place lists, less those VK gives no file for.
      expect(playback.queue.context.length, inInclusiveRange(1, releaseSongs));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(of: cardPlay, matching: find.byIcon(Icons.pause)),
        findsOneWidget,
        reason: 'the playing card keeps Pause without hover',
      );
      say(
        'release card Play: ${playback.queue.context.length} songs, sound in '
        '${timing.toSoundMs} ms (${timing.cached ? 'cached' : 'streamed'})',
      );
    }

    // 7. A similar artist's page, by its address name.
    final similar = page.similar.firstWhere(
      (s) => s.domain != null && s.domain!.isNotEmpty,
      orElse: () => fail('no similar artist with an address name'),
    );
    final similarCard = find.byKey(
      ValueKey('artist-similar-${similar.domain ?? similar.name}'),
    );
    await tester.scrollUntilVisible(similarCard, 200, scrollable: pageScroll);
    await tester.pump();
    clock = Stopwatch()..start();
    await tester.tap(similarCard);
    await tester.pump();
    expect(library.view.kind, ViewKind.artist);
    expect(
      library.view.artist == 'domain:${similar.domain}',
      isTrue,
      reason: 'the clicked similar artist',
    );
    final similarRef = vkRefOf(
      library.view.artist!,
      artists.artistOf(library.view.artist!),
    )!;
    await waitUntil(
      tester,
      () => artists.vkOf(similarRef).load != ArtistVkLoad.loading,
      timeout: const Duration(seconds: 30),
      what: "the similar artist's page",
    );
    final similarVk = artists.vkOf(similarRef);
    expect(similarVk.load, ArtistVkLoad.loaded, reason: '${similarVk.error}');
    expect(find.byKey(const ValueKey('artist-page-name')), findsOneWidget);
    say(
      'similar "${similar.name}": page in ${clock.elapsedMilliseconds} ms, '
      '${similarVk.page!.popular.songs.length} popular, '
      '${similarVk.page!.releases.length} releases',
    );
    library.goBack();
    await tester.pump();
    expect(library.view.artist == artist.key, isTrue, reason: 'Back');

    // 8. An artist name in a song row opens that artist's page.
    await tester.tap(find.byKey(const ValueKey('nav-songs')));
    await tester.pump();
    expect(library.view.kind, ViewKind.songs);
    final linked = library.visible
        .take(8)
        .firstWhere(
          (t) =>
              artists.index.artistsOf(t.id).length == 1 &&
              !artists.index.artistsOf(t.id).single.nameOnly &&
              find.byKey(ValueKey('artist-line-${t.id}')).evaluate().isNotEmpty,
          orElse: () => fail('no row with one VK artist in sight'),
        );
    final line = find.byKey(ValueKey('artist-line-${linked.id}'));
    final box = tester.getRect(line);
    clock = Stopwatch()..start();
    await tester.tapAt(Offset(box.left + 4, box.center.dy));
    await tester.pump();
    expect(library.view.kind, ViewKind.artist);
    expect(
      library.view.artist == artists.index.artistsOf(linked.id).single.key,
      isTrue,
      reason: "the row's artist",
    );
    say(
      'name link: "${linked.artist}" opened '
      '"${artists.artistOf(library.view.artist!)?.name}" in '
      '${clock.elapsedMilliseconds} ms',
    );
    library.goBack();
    await tester.pump();
    expect(library.view.kind, ViewKind.songs);

    final (vkEnd, keysEnd) = await vkLibrary();
    expect(vkEnd, vkBefore, reason: 'the account ends as it started');
    expect(
      keysEnd.length == keysBefore.length && keysEnd.containsAll(keysBefore),
      isTrue,
      reason: 'the account has the same songs',
    );
    expect(library.all.length, listedBefore);
    player.player.pause();
    await tester.pump(const Duration(seconds: 1));
    say('PASSED');
  });
}
