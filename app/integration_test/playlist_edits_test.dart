// Real check of editing VK playlists from the app (plan 08, C6): the real
// app, real VK, muted, off-screen. TEST ACCOUNT ONLY. It makes its own
// playlist "Ownsemble edit check" and deletes it at the end (the tear-down
// deletes it too if a step failed); the followed playlist is unfollowed and
// taken back with Undo, so it stays. VK's own state is read back after each
// step and compared with what the app shows.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test \
//       integration_test/playlist_edits_test.dart -d windows \
//       --dart-define=OWNSEMBLE_DATA=<absolute path>/.local/v2-test/feel \
//       --dart-define=OWNSEMBLE_SESSION=<absolute path>/.local/v2-test/session.json
//
// The app runs on a copy of the library ("<data dir>-edits", replaced on
// every run) with nothing stored and no playlists cache. Steps: New playlist
// on the page; two library songs and one song of the followed playlist (not
// in the library: VK makes a copy) go in from the row menu, each on top;
// the menu says "already in" for a song in it; the last row dragged to the
// top; Remove + Undo leaves VK alone, Remove lets it go; Rename; a song of
// it streams and decodes; Unfollow + Undo on the followed playlist; Delete.
// Prints titles, counts and times only: no link, key, token or id.

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/playlist_actions.dart' show playlistUndoTime;
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_playlists.dart';
import 'package:ownsemble/vk/vk_sync.dart' show vkSourceKey;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const session = String.fromEnvironment('OWNSEMBLE_SESSION');
const checkTitle = 'Ownsemble edit check';
const renamedTitle = 'Ownsemble edit check, renamed';

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

  /// Real time with frames: menus open, bars run out.
  Future<void> wait(WidgetTester tester, Duration time) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < time) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  testWidgets('Playlist edits: create, add, already in, drag, remove + '
      'Undo, rename, play, unfollow + Undo, delete', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(session, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION');
    expect(session, isNot(contains('session-2')), reason: 'test account');
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final copy = Directory('$dataDir-edits');
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
    Future<Set<String>> vkLibrary() async {
      final reply = await client.call('audio.get', {
        'owner_id': '$me',
        'count': '1000',
      }) as Map<String, dynamic>;
      return {
        for (final item in (reply['items'] as List))
          vkSourceKey(item as Map<String, dynamic>),
      };
    }

    final keysBefore = await vkLibrary();
    final listsBefore = await fetchVkPlaylists(client.call, me);
    expect(
      listsBefore.where((l) => l.title.startsWith(checkTitle)),
      isEmpty,
      reason: 'a check playlist left from an earlier run: delete it first',
    );
    say(
      'VK before: ${keysBefore.length} songs; ${listsBefore.length} '
      'playlists',
    );
    // The check's playlist, once made: deleted at the end in any case.
    String? madeKey;
    addTearDown(() async {
      final lists = await fetchVkPlaylists(client.call, me);
      for (final list in lists) {
        if (list.key == madeKey || list.title.startsWith(checkTitle)) {
          await client.call('audio.deletePlaylist', {
            'owner_id': '$me',
            'playlist_id': list.key.split('_').last,
          });
          say('cleanup: deleted the check playlist left behind');
        }
      }
      final keysNow = await vkLibrary();
      expect(
        keysNow.difference(keysBefore),
        isEmpty,
        reason: 'the library is never touched by playlist edits',
      );
    });

    /// VK's songs of the check playlist, in VK's order.
    Future<(VkPlaylist?, List<String>)> onVk() async {
      final lists = await fetchVkPlaylists(client.call, me);
      final list = lists.where((l) => l.key == madeKey).firstOrNull;
      if (list == null) return (null, const <String>[]);
      final songs = await fetchVkPlaylistSongs(client.call, list);
      return (list, [for (final song in songs) song.key]);
    }

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
    final playlists = screen.playlists!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    await sync.idle.timeout(const Duration(minutes: 5));
    await waitUntil(
      tester,
      () => playlists.hasLists && !playlists.refreshing,
      timeout: const Duration(seconds: 90),
      what: 'the playlists after the sync',
    );
    final followed = playlists.shown.single.lists.firstWhere(
      (l) => l.kind == VkPlaylistKind.followed,
    );
    say('library ${library.all.length} songs; followed "${followed.title}"');

    Finder rowOf(int index) => find.byKey(
      ValueKey(
        library.entryIdAt(index) == null
            ? 'song-${library.visible[index].id}'
            : 'entry-${library.entryIdAt(index)}',
      ),
    );

    Future<void> openMenu(int index) async {
      // A row far down a long list is scrolled to first: only rows on
      // screen are built.
      final position = library.scroll.position;
      final top = (index - 2) * rowHeight;
      if (top > position.pixels + 6 * rowHeight || top < position.pixels) {
        position.jumpTo(top.clamp(0, position.maxScrollExtent));
        await wait(tester, const Duration(milliseconds: 200));
      }
      await tester.tap(rowOf(index), buttons: kSecondaryMouseButton);
      await wait(tester, const Duration(milliseconds: 400));
    }

    Future<void> closeMenu() async {
      await tester.tapAt(const Offset(4, 4));
      await wait(tester, const Duration(milliseconds: 400));
    }

    Future<void> openPage() async {
      await tester.tap(find.byKey(const ValueKey('nav-playlists')));
      await wait(tester, const Duration(milliseconds: 300));
    }

    Future<void> openCard(String title) async {
      await tester.tap(find.byKey(ValueKey('list-card-$title')));
      await waitUntil(
        tester,
        () => library.view.kind == ViewKind.vkList,
        what: 'the playlist "$title" to open',
      );
      await wait(tester, const Duration(milliseconds: 300));
    }

    /// Waits until VK's order of the check playlist is [keys] and the app
    /// shows the same order.
    Future<List<String>> vkHas(
      List<String> keys,
      String what, {
      Duration timeout = const Duration(seconds: 30),
    }) async {
      final clock = Stopwatch()..start();
      var (_, now) = await onVk();
      while (now.join(',') != keys.join(',')) {
        if (clock.elapsed > timeout) {
          fail(
            'VK has ${now.length} songs, not the ${keys.length} after $what',
          );
        }
        await wait(tester, const Duration(milliseconds: 500));
        (_, now) = await onVk();
      }
      await waitUntil(
        tester,
        () =>
            playlists.songsOf(madeKey!).map((s) => s.key).join(',') ==
            keys.join(','),
        what: 'the app to keep VK\'s order after $what',
      );
      return now;
    }

    // 1. New playlist on the page.
    var clock = Stopwatch()..start();
    await openPage();
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('playlists-new-'),
      ),
    );
    await wait(tester, const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      checkTitle,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-name-ok')));
    await waitUntil(
      tester,
      () =>
          library.view.kind == ViewKind.vkList &&
          playlists.playlistOf(library.view.album!) != null,
      what: 'the new playlist to open',
    );
    madeKey = playlists.playlistOf(library.view.album!)!.key;
    final (made, madeSongs) = await onVk();
    expect(made?.title, checkTitle);
    expect(madeSongs, isEmpty);
    say('made "$checkTitle" in ${clock.elapsedMilliseconds} ms; VK lists it');

    // 2. Two library songs from the Songs list, each on top.
    await tester.tap(find.byKey(const ValueKey('nav-songs')));
    await wait(tester, const Duration(milliseconds: 400));
    final ownSongs = [
      for (final track in library.visible.take(30))
        if (track.source == TrackSource.vk && !track.isGone) track,
    ].take(2).toList();
    expect(ownSongs, hasLength(2));
    final addedKeys = <String>[];
    for (final track in ownSongs) {
      clock = Stopwatch()..start();
      await openMenu(library.visible.indexOf(track));
      await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
      await wait(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byKey(ValueKey('add-to-playlist-$madeKey')));
      await waitUntil(
        tester,
        () => playlists.songsOf(madeKey!).length == addedKeys.length + 1,
        what: 'the add to be read back',
      );
      addedKeys.insert(0, playlists.songsOf(madeKey).first.key);
      await vkHas(addedKeys, 'adding a library song');
      say(
        'added library song ${track.artist} - ${track.title} in '
        '${clock.elapsedMilliseconds} ms: on top on VK',
      );
    }

    // 3. "already in" for the song just added.
    await openMenu(library.visible.indexOf(ownSongs.last));
    await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
    await wait(tester, const Duration(milliseconds: 400));
    final item = tester.widget<PopupMenuItem<Object?>>(
      find.byKey(ValueKey('add-to-playlist-$madeKey')),
    );
    expect(item.enabled, isFalse, reason: 'already in');
    expect(find.text('already in'), findsOneWidget);
    await closeMenu();
    say('"already in" shown, greyed, for the song in it');

    // 4. A song of the followed playlist the library lacks: VK makes a copy.
    await openPage();
    await openCard(followed.title);
    final outsideIndex = library.visible.indexWhere(
      (t) => !t.inLibrary && playlists.outside.restrictionOf(t.id) == null,
    );
    expect(outsideIndex, isNonNegative);
    final outsideSong = library.visible[outsideIndex];
    clock = Stopwatch()..start();
    await openMenu(outsideIndex);
    expect(
      find.byKey(const ValueKey('menu-remove-from-playlist')),
      findsNothing,
      reason: 'a followed playlist takes no edits',
    );
    await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
    await wait(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byKey(ValueKey('add-to-playlist-$madeKey')));
    await waitUntil(
      tester,
      () => playlists.songsOf(madeKey!).length == 3,
      what: 'the outside song to be read back',
    );
    addedKeys.insert(0, playlists.songsOf(madeKey).first.key);
    await vkHas(addedKeys, 'adding an outside song');
    say(
      'added outside song ${outsideSong.artist} - ${outsideSong.title} in '
      '${clock.elapsedMilliseconds} ms: on top on VK, as a copy',
    );

    // 5. Drag the last row to the top.
    await openPage();
    await openCard(checkTitle);
    expect(library.visible, hasLength(3));
    final shownBefore = [for (final t in library.visible) t.title];
    final handle = find.byKey(ValueKey('drag-entry-${library.entryIdAt(2)}'));
    expect(handle, findsOneWidget);
    clock = Stopwatch()..start();
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -rowHeight * 2.3 / 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    // The list names the drop once the row has settled into its place.
    await wait(tester, const Duration(milliseconds: 600));
    final shownAfter = [for (final t in library.visible) t.title];
    expect(shownAfter, [shownBefore[2], shownBefore[0], shownBefore[1]]);
    final dropMs = clock.elapsedMilliseconds;
    final dragged = [addedKeys[2], addedKeys[0], addedKeys[1]];
    await vkHas(dragged, 'the drag');
    say(
      'drag: the last row went to the top at once (drop $dropMs ms after '
      'the grab), VK has the new order after ${clock.elapsedMilliseconds} ms',
    );

    // 6. Remove + Undo: VK keeps the song. Remove alone: it goes.
    await openMenu(0);
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-playlist')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(library.visible, hasLength(2), reason: 'the row goes at once');
    await tester.tap(find.byKey(const ValueKey('playlist-undo')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(library.visible, hasLength(3), reason: 'Undo brings it back');
    await wait(tester, playlistUndoTime + const Duration(seconds: 2));
    await vkHas(dragged, 'Remove + Undo');
    say('Remove + Undo: the row came back, VK still has all 3');

    clock = Stopwatch()..start();
    await openMenu(0);
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-playlist')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(library.visible, hasLength(2));
    final left = dragged.skip(1).toList();
    await vkHas(
      left,
      'Remove',
      timeout: playlistUndoTime + const Duration(seconds: 30),
    );
    say(
      'Remove: taken out on VK when the bar closed '
      '(${clock.elapsedMilliseconds} ms after the click)',
    );

    // 7. Rename from the heading.
    clock = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await wait(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('playlist-rename')));
    await wait(tester, const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name')),
      renamedTitle,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-name-ok')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.text(renamedTitle), findsWidgets, reason: 'the heading');
    var (renamed, _) = await onVk();
    while (renamed?.title != renamedTitle) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('not renamed');
      await wait(tester, const Duration(milliseconds: 500));
      (renamed, _) = await onVk();
    }
    say('renamed in ${clock.elapsedMilliseconds} ms: VK has the new title');

    // 8. A song of it streams and decodes (muted).
    final timings = <PlayTiming>[];
    final listening = player.timings.listen(timings.add);
    addTearDown(listening.cancel);
    for (var index = 0; index < library.visible.length; index++) {
      final pick = library.visible[index];
      final before = timings.length;
      await tester.tap(rowOf(index));
      await tester.pump();
      await waitUntil(
        tester,
        () => timings.length > before,
        what: 'a playlist song to sound',
      );
      final timing = timings.last;
      expect(timing.ok, isTrue, reason: 'error: ${timing.error}');
      expect(timing.sampleRate, isNotNull, reason: 'mpv decoded the audio');
      await waitUntil(
        tester,
        () => player.position >= const Duration(seconds: 2),
        timeout: const Duration(seconds: 30),
        what: 'the song to move past 2 s',
      );
      say(
        'played ${pick.inLibrary ? 'own' : 'outside'} ${pick.artist} - '
        '${pick.title}: sound in ${timing.toSoundMs} ms (network first '
        'chunk ${timing.networkFirstChunkMs} ms), ${timing.sampleRate} Hz',
      );
    }
    player.player.pause();

    // 9. Unfollow + Undo on the followed playlist: it stays on VK.
    await openPage();
    await openCard(followed.title);
    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await wait(tester, const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('playlist-rename')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-unfollow')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(library.view.kind, ViewKind.playlists, reason: 'back on the page');
    expect(find.byKey(ValueKey('list-card-${followed.title}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-undo')));
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.byKey(ValueKey('list-card-${followed.title}')), findsOneWidget);
    await wait(tester, playlistUndoTime + const Duration(seconds: 2));
    final listsNow = await fetchVkPlaylists(client.call, me);
    expect(listsNow.map((l) => l.key), contains(followed.key));
    say('Unfollow + Undo: the card came back, VK still lists it');

    // 10. Delete from the heading: asks, goes back, gone on VK.
    clock = Stopwatch()..start();
    await openCard(renamedTitle);
    await tester.tap(find.byKey(const ValueKey('playlist-menu')));
    await wait(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('playlist-delete')));
    await wait(tester, const Duration(milliseconds: 400));
    expect(find.text('Delete $renamedTitle?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-delete-yes')));
    await waitUntil(
      tester,
      () => library.view.kind == ViewKind.playlists,
      what: 'back on the page after Delete',
    );
    final deletedMs = clock.elapsedMilliseconds;
    // VK may list a deleted playlist for a moment (its songs then answer
    // error 201): only the list is read here.
    Future<bool> listed() async =>
        (await fetchVkPlaylists(client.call, me)).any((l) => l.key == madeKey);
    while (await listed()) {
      if (clock.elapsed > const Duration(seconds: 60)) fail('not deleted');
      await wait(tester, const Duration(milliseconds: 500));
    }
    say(
      'VK stopped listing it ${clock.elapsedMilliseconds - deletedMs} ms '
      'after the app went back to the page',
    );
    expect(find.byKey(const ValueKey('list-card-$renamedTitle')), findsNothing);
    say('deleted in ${clock.elapsedMilliseconds} ms: VK no longer lists it');

    final cache = File(p.join(copy.path, 'playlists.json'));
    expect(cache.readAsStringSync(), isNot(contains('"url"')));
    say('PASSED');
  });
}
