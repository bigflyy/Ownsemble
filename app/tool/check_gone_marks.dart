// Checks the "gone from VK" rule against the real test account, on a copy of
// a data folder's library (the folder itself is never written).
//
// Into the copy go two songs the account's library does not have: one with a
// key that does not exist on VK and one real VK song found by search. A sync
// must mark exactly those two gone, both when VK pages its reply (and hides
// blocked songs, so missing songs are looked up with audio.getById) and when
// it lists everything in one page. Prints counts only: no titles, tokens or
// links.
//
// Run from app/:
//   dart run tool/check_gone_marks.dart --data-dir DIR --vk-session FILE

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  if (dataDir == null || sessionPath == null) {
    stderr.writeln('--data-dir and --vk-session are required');
    exit(64);
  }

  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final temp = Directory.systemTemp.createTempSync('ownsemble_gone_check');
  var failures = 0;
  void check(bool ok, String what) {
    print('${ok ? 'ok  ' : 'FAIL'} $what');
    if (!ok) failures++;
  }

  try {
    await vk.ensureToken();
    for (final pageSize in [50, 200]) {
      final copy = p.join(temp.path, 'library-$pageSize.db');
      final source = sqlite3.open(
        p.join(dataDir, 'library.db'),
        mode: OpenMode.readOnly,
      );
      source.execute('VACUUM INTO ?', [copy]);
      source.close();

      final store = LibraryStore.open(copy);
      try {
        final sourceId = store.ensureSource(
          TrackSource.vk,
          account: '${vk.userId}',
          name: 'VK',
        );
        final libraryKeys = store.trackKeys(sourceId).keys.toSet();
        final search = await vk.call('audio.search', {
          'q': 'metallica',
          'count': '20',
        }) as Map<String, dynamic>;
        final elsewhere = (search['items'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((item) => !libraryKeys.contains(vkSourceKey(item)));
        final fakeKey = '${vk.userId}_999999999';
        store.upsertAll(sourceId, [
          NewTrack(
            sourceKey: fakeKey,
            artist: 'Проверка',
            title: 'Несуществующая песня',
            durationSec: 1,
            addedAt: 0,
          ),
          vkItemToTrack(elsewhere),
        ]);

        final result = await syncVkSource(
          call: vk.call,
          userId: vk.userId,
          store: store,
          pageSize: pageSize,
        );
        final gone = store
            .loadAll()
            .where((t) => t.isGone)
            .map((t) => t.sourceKey)
            .toSet();
        final hidden = result.declared - result.listed;
        print(
          'page size $pageSize: VK listed ${result.listed} of '
          '${result.declared} (hidden $hidden), newly gone '
          '${result.newlyGone}, added ${result.added}, '
          'updated ${result.updated}',
        );
        check(
          gone.length == 2 &&
              gone.contains(fakeKey) &&
              gone.contains(vkSourceKey(elsewhere)),
          'page size $pageSize: exactly the 2 injected songs are gone',
        );
        check(
          store.sources().firstWhere((s) => s.id == sourceId).lastSyncError ==
              null,
          'page size $pageSize: sync recorded without error',
        );
        if (pageSize == 50) {
          check(hidden > 0, 'page size 50: VK hid blocked songs');
        }
      } finally {
        store.close();
      }
    }
  } finally {
    vk.close();
    temp.deleteSync(recursive: true);
  }
  print(failures == 0 ? 'All checks passed.' : '$failures check(s) failed.');
  exit(failures == 0 ? 0 : 1);
}
