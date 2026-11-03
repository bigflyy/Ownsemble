// Several accounts check: the real app, an empty data folder, the real login
// window (off-screen) and two real VK accounts in one library.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/accounts_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<data dir> \
//       --dart-define=OWNSEMBLE_SESSION=<first test account's session file> \
//       --dart-define=OWNSEMBLE_SESSION_2=<second test account's session file>
//
// The app starts on an empty folder of its own ("<data dir>-accounts", replaced
// on every run); the data folder itself is never touched.
//
// The second account is read-only: this check syncs it and streams it muted,
// nothing else, and every VK call the app makes only reads. Its songs must stay
// out of the public repo, so this file and its output hold counts and ids of
// the library's own rows, never a title or an account's name.

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_session.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const firstSession = String.fromEnvironment('OWNSEMBLE_SESSION');
const secondSession = String.fromEnvironment('OWNSEMBLE_SESSION_2');

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

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('two VK accounts in one library', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    expect(secondSession, isNotEmpty, reason: 'pass OWNSEMBLE_SESSION_2');
    final data = Directory('$dataDir-accounts');
    if (data.existsSync()) data.deleteSync(recursive: true);
    data.createSync(recursive: true);
    final seedFile = File(p.join(data.path, 'seed.json'));
    addTearDown(() {
      if (seedFile.existsSync()) seedFile.deleteSync();
    });

    await app.main([
      '--data-dir',
      data.path,
      '--vk-login-seed',
      seedFile.path,
      '--muted',
    ]);
    await tester.pump();
    final screen = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    final library = screen.library;
    final player = screen.player;
    final sync = screen.sync!;
    final accounts = screen.account!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');
    say('player ready');

    /// Logs in through the real window with [session]'s cookies in the page.
    Future<void> logInWith(String session, String buttonKey) async {
      final before = accounts.logins;
      File(session).copySync(seedFile.path);
      await tester.tap(find.byKey(ValueKey(buttonKey)).first);
      await tester.pump();
      await waitUntil(
        tester,
        () => accounts.logins > before,
        timeout: const Duration(seconds: 90),
        what: 'the login',
      );
      seedFile.deleteSync();
      say('login done');
      expect(accounts.loggingIn, isFalse, reason: 'the window closed itself');
    }

    Future<void> syncSettled() => waitUntil(
      tester,
      () => !sync.running && sync.lastOutcome != null,
      timeout: const Duration(minutes: 12),
      what: 'the sync',
    );

    /// Streams up to [tries] of [candidates] (muted) until [want] have sound,
    /// and checks each went through the account [expected] names (a source id;
    /// null = the song's listed account). Says row ids and errors, never a
    /// title: the second account's songs stay out of the output.
    Future<void> streamSome(
      String what,
      Iterable<Track> candidates, {
      required int want,
      int? expected,
      int tries = 8,
    }) async {
      final picked = candidates.toList()..shuffle(Random(3));
      var ok = 0;
      final failed = <String>[];
      for (final track in picked.take(tries)) {
        final routes = player.routesFor(track).map((r) => r.sourceId).toList();
        final timing = await player.play(track);
        if (!timing.ok) {
          failed.add('row ${track.id}: ${timing.error}');
          continue;
        }
        ok++;
        expect(timing.sampleRate, greaterThan(0), reason: 'audio decoded');
        expect(timing.cached, isFalse);
        expect(timing.sourceId, expected ?? track.sourceId);
        say(
          '$what: row ${track.id} routes $routes, sound ${timing.toSoundMs} ms '
          '(link ${timing.resolveMs}), source ${timing.sourceId}, '
          'skipped ${timing.skippedAccounts}',
        );
        if (ok == want) break;
      }
      await player.stop();
      for (final line in failed) {
        say('$what, no sound: $line');
      }
      expect(ok, want, reason: '$what: $want with sound');
    }

    /// Songs that would stream, not play from disk.
    bool streams(Track t) =>
        player.storage!.stateOf(t).path == null && !t.isGone;

    int rows() => library.all.length;
    int copies() => library.all.fold(0, (n, t) => n + t.copies.length);
    int ownSongs() => sync.syncedSources.fold(0, (n, s) => n + s.songCount);

    // First account, the way the user logs in.
    await logInWith(firstSession, 'vk-log-in');
    await waitUntil(tester, () => sync.running, what: 'a sync to start');
    await syncSettled();
    expect(sync.lastOutcome?.error, isNull);
    final alone = sync.syncedSources.single;
    say('first account: ${alone.songCount} songs, ${rows()} rows');
    expect(rows(), alone.songCount);
    expect(
      alone.name,
      vkDefaultSourceName,
      reason: 'one account needs no name',
    );

    // Second account, added from the accounts list.
    await tapKey(tester, 'vk-accounts');
    await logInWith(secondSession, 'vk-add-account');
    final clock = Stopwatch()..start();
    await waitUntil(
      tester,
      () => sync.syncedSources.length == 2 && !sync.running,
      timeout: const Duration(minutes: 12),
      what: 'both accounts synced',
    );
    say(
      'second account synced in ${clock.elapsed.inSeconds} s, '
      'errors: ${sync.lastOutcome?.errors.length}',
    );
    expect(sync.lastOutcome?.errors, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(accounts.sessions, hasLength(2));

    // Each account has its own session, encrypted, and both still work.
    final sessionFiles = Directory(p.join(data.path, 'sessions'))
        .listSync()
        .whereType<File>()
        .toList();
    expect(sessionFiles, hasLength(2));
    final users = <int>{};
    for (final saved in ProtectedSessionFolder(data.path).load()) {
      final vk = VkClient(saved.cookies);
      await vk.ensureToken();
      expect('${vk.userId}', saved.account);
      users.add(vk.userId);
      vk.close();
    }
    expect(users, hasLength(2));
    for (final file in sessionFiles) {
      expect(
        String.fromCharCodes(file.readAsBytesSync()),
        isNot(contains('remixsid')),
      );
    }

    // The library: one list, shared songs once.
    final sources = sync.syncedSources;
    say(
      'songs per account: ${sources.map((s) => s.songCount).join(' + ')} = '
      '${ownSongs()}; rows ${rows()}; merged ${copies()}',
    );
    expect(rows() + copies(), ownSongs());
    expect(copies(), greaterThan(0), reason: 'the accounts share songs');
    expect(
      sources.map((s) => s.color).toSet(),
      hasLength(2),
      reason: 'each account has its own color',
    );
    expect(
      sources.map((s) => s.name).toSet(),
      hasLength(2),
      reason: 'each account has its own name',
    );
    expect(sources.every((s) => s.name != vkDefaultSourceName), isTrue);
    say('names and colors differ');

    // E3: each song streams through the account that has it.
    final firstId = sources.first.id;
    final secondId = sources.last.id;
    expect(firstId, alone.id);
    Iterable<Track> onlyIn(int source) => library.all.where(
      (t) => t.sourceId == source && t.copies.isEmpty && streams(t),
    );
    final merged = library.all.where((t) => t.copies.isNotEmpty && streams(t));
    for (final track in onlyIn(secondId)) {
      expect(player.routesFor(track).map((r) => r.sourceId), [secondId]);
    }
    for (final track in merged) {
      expect(player.routesFor(track).map((r) => r.sourceId).toSet(), {
        track.sourceId,
        ...track.copies.map((c) => c.sourceId),
      });
      expect(player.routesFor(track).first.sourceId, track.sourceId);
    }
    await streamSome('second account only', onlyIn(secondId), want: 3);
    await streamSome('first account only', onlyIn(firstId), want: 1);
    await streamSome('merged', merged, want: 2);
    // A download takes the same route.
    final toKeep = onlyIn(secondId)
        .firstWhere((t) => player.storage!.stateOf(t).path == null);
    expect(await screen.playback.download(toKeep), isNull);
    expect(player.storage!.stateOf(toKeep).path, isNotNull);
    say('downloaded row ${toKeep.id} through the second account');
    final perfLog = File(p.join(data.path, 'perf.log')).readAsStringSync();
    expect(perfLog, contains(', source $secondId'));
    expect(perfLog, contains(', source $firstId'));
    expect(perfLog, isNot(contains('http')), reason: 'no links in perf.log');

    // Where the key's count may differ from the rows: a second-account song
    // with a partner that stayed apart, because a song listed twice in one
    // account takes only one copy. Counts only.
    final db = sqlite3.open(
      p.join(data.path, 'library.db'),
      mode: OpenMode.readOnly,
    );
    final apart = db
        .select(
          '''
      SELECT count(*) AS n,
             sum(EXISTS (SELECT 1 FROM tracks c WHERE c.same_as = a.id)) AS taken
      FROM tracks b JOIN tracks a
        ON a.source_id != b.source_id AND a.vk_track_id = b.vk_track_id
       AND abs(a.duration_sec - b.duration_sec) <= 2
      WHERE b.same_as IS NULL AND a.same_as IS NULL AND b.source_id = ?
      ''',
          [sources.last.id],
        )
        .first;
    db.close();
    say(
      'same key, not merged: ${apart['n']}, '
      'of them partner already has a copy: ${apart['taken']}',
    );

    // A second sync finds nothing to merge and no song is lost.
    final rowsBefore = rows();
    await tester.tap(find.byKey(const ValueKey('accounts-close')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('sync-now')));
    await tester.pump();
    await waitUntil(tester, () => sync.running, what: 'Sync now to start');
    await syncSettled();
    final again = sync.lastOutcome!;
    expect(again.errors, isEmpty);
    expect(again.results, hasLength(2));
    for (final result in again.results) {
      say(
        'Sync now: added ${result.added}, updated ${result.updated}, '
        'newly gone ${result.newlyGone}',
      );
      expect(result.added, 0);
      expect(result.newlyGone, 0);
    }
    expect(rows(), rowsBefore);

    // E4: the chips filter the lists to one account, merged songs in both.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('source-filter')), findsOneWidget);
    expect(library.filterSources.map((s) => s.id), [firstId, secondId]);
    for (final source in [secondId, firstId]) {
      final clock = Stopwatch()..start();
      await tapKey(tester, 'source-filter-$source');
      final switchMs = clock.elapsedMilliseconds;
      final wanted = library.all.where((t) => t.isFrom(source)).toList();
      expect(library.sourceFilter, source);
      expect(
        library.visible.map((t) => t.id),
        wanted.map((t) => t.id),
        reason: 'the songs of source $source, in library order',
      );
      expect(library.visible.where((t) => t.copies.isNotEmpty), isNotEmpty);
      final firstRow = library.visible.first;
      expect(find.byKey(ValueKey('song-${firstRow.id}')), findsOneWidget);
      say(
        'filter source $source: ${library.visible.length} of ${rows()} rows, '
        '${library.visible.where((t) => t.copies.isNotEmpty).length} merged, '
        'tap to list $switchMs ms (two frames of 300 ms pumped)',
      );
    }
    final firstOnly = library.visible.length;
    // Back undoes the filter, Forward redoes it.
    library.goBack();
    await tester.pump(const Duration(milliseconds: 300));
    expect(library.sourceFilter, secondId);
    library.goForward();
    await tester.pump(const Duration(milliseconds: 300));
    expect(library.sourceFilter, firstId);
    // Searching inside a filter keeps both; a letter typed in the box.
    await tester.enterText(find.byType(TextField), 'а');
    await tester.pump(const Duration(milliseconds: 300));
    expect(library.visible.every((t) => t.isFrom(firstId)), isTrue);
    expect(library.visible.length, lessThanOrEqualTo(firstOnly));
    say('search "а" inside the filter: ${library.visible.length} rows');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 300));
    // A song played from the filtered list: its queue is that list, and going
    // to it from another filter comes back here.
    // The filter's own cost on this library, without the frames.
    final filterClock = Stopwatch()..start();
    library.showSource(null);
    final toAllUs = filterClock.elapsedMicroseconds;
    filterClock.reset();
    library.showSource(secondId);
    final toSecondUs = filterClock.elapsedMicroseconds;
    say(
      'filter call on ${rows()} rows: to all $toAllUs us, '
      'to source $secondId $toSecondUs us',
    );
    await tester.pump(const Duration(milliseconds: 300));
    final playedRow = library.visible.firstWhere(streams);
    final playedIndex = library.visible.indexOf(playedRow);
    say('playing row ${playedRow.id} from the filtered list, by a tap');
    await tester.tap(find.byKey(ValueKey('song-${playedRow.id}')));
    await waitUntil(
      tester,
      () => player.current?.id == playedRow.id,
      what: 'the tapped song to start',
    );
    expect(
      screen.playback.queue.context.map((t) => t.id),
      library.visible.map((t) => t.id),
    );
    await player.stop();
    await tapKey(tester, 'source-filter-all');
    library.goToSong(playedRow);
    await tester.pump(const Duration(milliseconds: 300));
    expect(library.sourceFilter, secondId);
    expect(library.jump.row, playedIndex);
    // The filter is saved for the next start; one stays chosen for the
    // log out and remove steps below.
    final settingsDb = sqlite3.open(
      p.join(data.path, 'library.db'),
      mode: OpenMode.readOnly,
    );
    expect(
      settingsDb
          .select("SELECT value FROM settings WHERE key = 'ui.source'")
          .first['value'],
      '$secondId',
    );
    settingsDb.close();
    say('filter: Back/Forward, play from it, go to song, saved: ok');

    // Rename and recolor, by hand.
    final second = sync.syncedSources.last;
    await tapKey(tester, 'vk-accounts');
    await tapKey(tester, 'account-menu-${second.id}');
    await tapKey(tester, 'account-rename');
    await tester.enterText(
      find.byKey(const ValueKey('account-name')),
      'Вторая',
    );
    await tapKey(tester, 'account-name-save');
    expect(sync.syncedSources.last.name, 'Вторая');
    await tapKey(tester, 'account-color-${second.id}');
    await tapKey(tester, 'account-color-${second.id}-5');
    expect(sync.syncedSources.last.color, 5);
    say('renamed and recolored');

    // Log out of one: its songs stay, the other account goes on syncing.
    await tapKey(tester, 'account-menu-${second.id}');
    await tapKey(tester, 'vk-log-out');
    expect(accounts.sessions, hasLength(1));
    expect(rows(), rowsBefore);
    await tapKey(tester, 'accounts-close');
    await tapKey(tester, 'sync-now');
    await waitUntil(tester, () => !sync.running, what: 'sync of one account');
    expect(sync.lastOutcome!.results, hasLength(1));
    expect(find.text('not logged in'), findsOneWidget);
    expect(rows(), rowsBefore);
    // Its songs stay in the library, so its chip and the filter stay too.
    expect(library.sourceFilter, second.id);
    expect(find.byKey(ValueKey('source-filter-${second.id}')), findsOneWidget);
    say('logged out of one: rows stay, the other syncs');
    // Its own songs have no account left to stream through: they fail at once
    // with a reason, and never go through the first account.
    final orphan = library.all
        .where((t) => t.sourceId == second.id && t.copies.isEmpty && streams(t))
        .first;
    expect(player.routesFor(orphan), isEmpty);
    final refused = await player.play(orphan);
    expect(refused.ok, isFalse);
    expect(refused.error, 'no logged-in VK account has this song');
    expect(refused.toSoundMs, lessThan(1000));
    expect(refused.sourceId, isNull);
    // A downloaded one still plays, from disk.
    final kept = library.byId(toKeep.id)!;
    final fromDisk = await player.play(kept);
    expect(fromDisk.ok, isTrue, reason: 'downloaded song: ${fromDisk.error}');
    expect(fromDisk.cached, isTrue);
    await player.stop();
    say(
      'logged out: own song refused in ${refused.toSoundMs} ms, '
      'downloaded one plays from disk',
    );

    // Back in: the same source, its name kept, nothing doubled.
    await tapKey(tester, 'vk-accounts');
    await logInWith(secondSession, 'vk-add-account');
    await waitUntil(
      tester,
      () => !sync.running && accounts.sessions.length == 2,
      timeout: const Duration(minutes: 3),
      what: 'the account back',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(sync.syncedSources, hasLength(2));
    expect(sync.syncedSources.last.id, second.id);
    expect(sync.syncedSources.last.name, 'Вторая');
    expect(rows(), rowsBefore);
    say('logged in again: same source, same rows');

    // The listed account logs out: a merged song goes through the other one.
    await tapKey(tester, 'account-menu-$firstId');
    await tapKey(tester, 'vk-log-out');
    expect(accounts.sessions, hasLength(1));
    final listedOut = library.all.where(
      (t) => t.sourceId == firstId && t.copies.isNotEmpty && streams(t),
    );
    expect(listedOut, isNotEmpty);
    for (final track in listedOut) {
      expect(player.routesFor(track).map((r) => r.sourceId), [second.id]);
    }
    await streamSome(
      'merged, listed account logged out',
      listedOut,
      want: 2,
      expected: second.id,
    );
    await logInWith(firstSession, 'vk-add-account');
    await waitUntil(
      tester,
      () => !sync.running && accounts.sessions.length == 2,
      timeout: const Duration(minutes: 3),
      what: 'the first account back',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(sync.syncedSources.map((s) => s.id), [firstId, second.id]);
    expect(rows(), rowsBefore);
    say('first account back in');

    // Remove: the songs that are only the second account's leave.
    await tapKey(tester, 'account-menu-${second.id}');
    await tapKey(tester, 'account-remove');
    expect(
      find.byKey(const ValueKey('account-remove-confirm')),
      findsOneWidget,
    );
    await tapKey(tester, 'account-remove-confirm');
    await waitUntil(
      tester,
      () => sync.syncedSources.length == 1,
      what: 'the account removed',
    );
    expect(accounts.sessions, hasLength(1));
    // Two of its songs stay, marked gone (E2's rule): the one downloaded
    // through it (stored) and the one played from the filtered list (in
    // History; the E3 steps play without recording, the tap records).
    final stayed = library.all.where((t) => t.sourceId != alone.id).toList();
    expect(stayed.map((t) => t.id).toSet(), {toKeep.id, playedRow.id});
    expect(stayed.every((t) => t.isGone), isTrue);
    expect(rows(), alone.songCount + 2);
    expect(copies(), 0);
    // Its filter went with it: one source leaves nothing to choose.
    expect(library.sourceFilter, isNull);
    expect(library.visible.length, rows());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('source-filter')), findsNothing);
    say(
      'removed: ${rows()} rows left, one source + the downloaded row '
      '${toKeep.id} + the played row ${playedRow.id}',
    );
    await tapKey(tester, 'accounts-close');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
