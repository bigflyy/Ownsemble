// Read-only: does using VK the way the app does make the account show as
// online to others (user, 2026-11-21: "does it make me appear online on VK
// using this app?"), and does account.setOffline hide it again.
//
// The second account (session-2.json, read-only use allowed: user,
// 2026-11-21 "2 yes") watches the test account with users.get (online,
// last_seen); nothing is changed on either account.
//
//   dart run tool/probe_online.dart --vk-session <session.json>
//       --watcher-session <session-2.json>
//
// Steps: the test account's web token (as the app's start); wait until it
// shows offline; one audio.get (as a sync or a list); watch; then
// account.setOffline; watch. Prints flags, platforms and seconds only: no
// name, id, link or token.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String valueOf(String name) => args[args.indexOf(name) + 1];
  final test = VkClient(SessionCookie.loadAll(File(valueOf('--vk-session'))));
  final watcher = VkClient(
    SessionCookie.loadAll(File(valueOf('--watcher-session'))),
  );
  final clock = Stopwatch()..start();
  String t() => '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(0)} s';

  await watcher.ensureToken();
  await test.ensureToken();
  print('${t()}: test account token taken (as the app does at start)');
  final testId = test.userId;
  if (testId == watcher.userId) throw StateError('same account');

  /// The test account as the second account sees it.
  Future<({bool online, int? seenAgoS, String platform})> look() async {
    final reply = await watcher.call('users.get', {
      'user_ids': '$testId',
      'fields': 'online,last_seen',
    });
    final user = (reply! as List).first as Map;
    final seen = user['last_seen'] as Map?;
    final time = seen?['time'] as int?;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const platforms = {
      1: 'mobile web',
      2: 'iPhone',
      3: 'iPad',
      4: 'Android',
      5: 'Windows Phone',
      6: 'Windows app',
      7: 'website',
    };
    return (
      online: user['online'] == 1,
      seenAgoS: time == null ? null : now - time,
      platform: platforms[seen?['platform']] ?? '${seen?['platform']}',
    );
  }

  Future<bool> report(String when) async {
    final s = await look();
    print(
      '${t()}: $when: online ${s.online}, last seen '
      '${s.seenAgoS == null ? 'hidden' : '${s.seenAgoS} s ago'} '
      '(${s.platform})',
    );
    return s.online;
  }

  Future<void> watch(String after, List<int> atS) async {
    final start = clock.elapsed;
    for (final at in atS) {
      final wait = Duration(seconds: at) - (clock.elapsed - start);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      await report('$at s after $after');
    }
  }

  await watch('the token', [3, 30]);
  // Wait for offline (VK keeps a web visit online for about 5 minutes).
  var offline = false;
  for (var i = 0; i < 20 && !offline; i++) {
    offline = !await report('waiting for offline');
    if (!offline) await Future<void>.delayed(const Duration(seconds: 60));
  }
  if (!offline) {
    print('never offline in 20 min: stop');
    return;
  }

  await test.call('audio.get', {'owner_id': '$testId', 'count': '1'});
  print('${t()}: test account: one audio.get');
  await watch('audio.get', [3, 30, 90]);

  await test.call('account.setOffline', {});
  print('${t()}: test account: account.setOffline');
  await watch('setOffline', [3, 30]);
  exit(0);
}
