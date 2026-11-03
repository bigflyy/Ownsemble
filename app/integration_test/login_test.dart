// Login check: the real app, starting logged out on an empty data folder, the
// real login window (WebView2, off-screen) and real VK.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter test integration_test/login_test.dart \
//       -d windows \
//       --dart-define=OWNSEMBLE_DATA=<data dir> \
//       --dart-define=OWNSEMBLE_SESSION=<test account's session file> \
//       --dart-define=OWNSEMBLE_SHOT=<PNG of the login page>
//
// The app starts on an empty folder of its own ("<data dir>-login", replaced on
// every run); the data folder itself is never touched.
//
// The agent never types into a login page. So the first window is only
// looked at and closed; for the login itself the test account's cookies are
// put into the second window, and everything after that is the real path:
// the app sees the session, VK gives a token, the window closes, the session
// is saved encrypted, the library syncs and a song plays. Prints counts, never
// cookies or links.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/main.dart' as app;
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/vk_accounts.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_session.dart';
import 'package:path/path.dart' as p;

const dataDir = String.fromEnvironment('OWNSEMBLE_DATA');
const sessionFile = String.fromEnvironment('OWNSEMBLE_SESSION');
const shotFile = String.fromEnvironment('OWNSEMBLE_SHOT');

const window = MethodChannel('ownsemble/vk_login');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
    String what = 'condition',
  }) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > timeout) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  testWidgets('logging in from nothing, and out again', (tester) async {
    expect(dataDir, isNotEmpty, reason: 'pass --dart-define=OWNSEMBLE_DATA');
    final data = Directory('$dataDir-login');
    if (data.existsSync()) data.deleteSync(recursive: true);
    data.createSync(recursive: true);
    final seedFile = File(p.join(data.path, 'seed.json'));

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
    final VkAccounts account = screen.account!;
    await waitUntil(tester, () => player.isReady, what: 'player ready');

    // Logged out, empty: the list and the status bar both offer the login.
    expect(account.loggedIn, isFalse);
    expect(library.all, isEmpty);
    expect(find.text('Log in to VK and your songs come here.'), findsOneWidget);
    final logIn = find.byKey(const ValueKey('vk-log-in'));
    expect(logIn, findsNWidgets(2));
    expect(find.byKey(const ValueKey('sync-now')), findsNothing);
    expect(sync.canSync, isFalse);

    // The window opens and VK's own page really shows in it.
    await tester.tap(logIn.first);
    await tester.pump();
    await waitUntil(tester, () => account.loggingIn, what: 'window open');
    var location = '';
    await waitUntil(tester, () {
      unawaited(
        window
            .invokeMethod<String>('location')
            .then((value) => location = value ?? ''),
      );
      return location.contains('vk.');
    }, what: 'a VK page in the window');
    // The page paints a dark background first; a real page takes far more
    // than that in a PNG.
    if (shotFile.isNotEmpty) {
      final clock = Stopwatch()..start();
      var size = 0;
      while (size < 8000 && clock.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        await window.invokeMethod<bool>('capture', {'path': shotFile});
        size = File(shotFile).lengthSync();
      }
      // ignore: avoid_print
      print('login page painted: $size bytes in ${clock.elapsed.inSeconds} s');
      expect(size, greaterThanOrEqualTo(8000), reason: 'the page stayed blank');
      // What the user ends up with, once the spinner has gone.
      await Future<void>.delayed(const Duration(seconds: 7));
      await window.invokeMethod<bool>('capture', {'path': shotFile});
    }
    // ignore: avoid_print
    print('login page: $location');

    // Closing the window ends the login: nothing is saved, nothing changes.
    await window.invokeMethod<void>('close');
    await waitUntil(tester, () => !account.loggingIn, what: 'window closed');
    expect(account.loggedIn, isFalse);
    expect(Directory(p.join(data.path, 'sessions')).existsSync(), isFalse);
    expect(sync.canSync, isFalse);

    // The login itself, with the test account's cookies in the page.
    File(sessionFile).copySync(seedFile.path);
    await tester.tap(logIn.first);
    await tester.pump();
    await waitUntil(
      tester,
      () => account.loggedIn,
      timeout: const Duration(seconds: 60),
      what: 'the login to finish',
    );
    expect(account.loggingIn, isFalse, reason: 'the window closed itself');
    seedFile.deleteSync();

    // The session on disk is encrypted, and still a working session.
    final saved = File(
      p.join(data.path, 'sessions', '${account.sessions.single.account}.dpapi'),
    );
    expect(saved.existsSync(), isTrue);
    final onDisk = String.fromCharCodes(saved.readAsBytesSync());
    expect(onDisk, isNot(contains('remixsid')));
    final reloaded = ProtectedSessionFile(saved).load()!;
    final fromDisk = VkClient(reloaded);
    await fromDisk.ensureToken();
    expect(fromDisk.userId, greaterThan(0));
    fromDisk.close();
    expect(
      data.listSync(recursive: true).map((e) => p.basename(e.path)),
      isNot(contains('session.json')),
    );

    // The library fills from nothing, with no further step.
    await waitUntil(
      tester,
      () => library.all.isNotEmpty,
      timeout: const Duration(minutes: 3),
      what: 'the first sync after the login',
    );
    expect(sync.lastOutcome?.error, isNull);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('sync-now')), findsOneWidget);
    expect(logIn, findsNothing);
    // ignore: avoid_print
    print('after login: ${library.all.length} songs synced');

    // The first sync shows the songs at once; a second one, with no step from
    // the user, then brings the album titles VK leaves out of a song's reply.
    final namedBefore = library.all.where((t) => t.album != null).length;
    await waitUntil(
      tester,
      () => !sync.running,
      timeout: const Duration(minutes: 3),
      what: 'the sync for the album titles',
    );
    await tester.pump();
    final namedAfter = library.all.where((t) => t.album != null).length;
    // ignore: avoid_print
    print('album titles: $namedBefore songs named, then $namedAfter');
    expect(sync.lastOutcome?.error, isNull);
    expect(namedAfter, greaterThan(namedBefore));
    expect(library.all.where((t) => t.album == 'unnamed'), isEmpty);

    // A song streams with the new login. Withdrawn songs have no sound.
    var played = false;
    for (final track in library.all.take(10)) {
      final timing = await screen.playback.playFrom(
        library.all,
        library.all.indexOf(track),
      );
      if (timing?.ok ?? false) {
        played = true;
        // ignore: avoid_print
        print('played from the new login: sound in ${timing!.toSoundMs} ms');
        break;
      }
    }
    expect(played, isTrue);
    await player.playOrPause();

    // Logging out forgets the session and keeps the library.
    await tester.tap(find.byKey(const ValueKey('vk-accounts')));
    await tester.pumpAndSettle();
    final sourceId = sync.syncedSources.single.id;
    await tester.tap(find.byKey(ValueKey('account-menu-$sourceId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vk-log-out')));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('accounts-close')));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(account.loggedIn, isFalse);
    expect(saved.existsSync(), isFalse);
    expect(player.vk, isNull);
    expect(sync.canSync, isFalse);
    expect(library.all, isNotEmpty);
    expect(logIn, findsOneWidget);
  });
}
