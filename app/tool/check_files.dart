// Real check of Stage M2: the background check of every song's VK file after
// a sync. Copies a library, forgets its stored prints and version choices
// (so every song is checked as on the first run), syncs it through the real
// background sync, runs the real file check twice and reports counts and
// timings, then the swapped songs it found.
//
//   dart run tool/check_files.dart --data-dir DIR --work-dir DIR2 \
//       --vk-session FILE [--vk-session-2 FILE2]
//
// Read-only on VK: sync, small range reads and searches. DIR is not written;
// DIR2 is replaced. Prints row ids and numbers only: no titles (the second
// account's songs stay private) and no links.
import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/sync/background_sync.dart';
import 'package:ownsemble/sync/file_check.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final workDir = valueOf('--work-dir');
  final first = valueOf('--vk-session');
  final second = valueOf('--vk-session-2');
  if (dataDir == null || workDir == null || first == null) {
    stderr.writeln('--data-dir, --work-dir and --vk-session are required');
    exitCode = 64;
    return;
  }
  Directory(workDir).createSync(recursive: true);
  final dbPath = p.join(workDir, 'library.db');
  for (final suffix in ['', '-wal', '-shm']) {
    final target = File('$dbPath$suffix');
    if (target.existsSync()) target.deleteSync();
    final source = File(p.join(dataDir, 'library.db$suffix'));
    if (source.existsSync()) source.copySync(target.path);
  }
  // As on the first run of a library: nothing checked, nothing chosen.
  LibraryStore.open(dbPath).close();
  final db = sqlite3.open(dbPath);
  db.execute('DELETE FROM vk_file_prints');
  db.execute('DELETE FROM song_versions');
  db.close();

  final sessions = [
    for (final path in [first, ?second])
      VkSyncSession(null, SessionCookie.loadAll(File(path))),
  ];
  var clock = Stopwatch()..start();
  final outcome = await syncVkInBackground(
    dbPath: dbPath,
    sessions: sessions,
    onProgress: (_) {},
  );
  stdout.writeln(
    'sync: ${clock.elapsedMilliseconds} ms, errors ${outcome.errors.length}, '
    'printed ${outcome.printed} merge candidates in ${outcome.printMs} ms',
  );
  for (final error in outcome.errors) {
    stdout.writeln('  error: $error');
  }

  for (final round in [1, 2]) {
    clock = Stopwatch()..start();
    var reports = 0;
    final check = await checkVkFilesInBackground(
      dbPath: dbPath,
      sessions: sessions,
      onProgress: (_) => reports++,
    );
    stdout.writeln(
      'check $round: ${clock.elapsedMilliseconds} ms; read ${check.checked} '
      'files in ${check.readMs} ms; swapped ${check.swapped}, decided '
      '${check.decided}, failed ${check.failed}, fixed by VK '
      '${check.forgotten}; searches ${check.searchMs} ms; $reports progress '
      'reports',
    );
  }

  final store = LibraryStore.open(dbPath);
  try {
    final listed = store.loadAll().where((t) => t.inLibrary).length;
    final left = store.filesToCheck().length;
    stdout.writeln('listed songs $listed, still to check $left');
    final noFile = sqlite3.open(dbPath)
      ..execute('PRAGMA query_only = 1');
    final counts = noFile.select('''
      SELECT count(*) AS printed,
             sum(bytes IS NULL) AS no_file,
             sum(seconds IS NULL AND bytes IS NOT NULL) AS no_length
      FROM vk_file_prints
    ''').first;
    noFile.close();
    stdout.writeln(
      'prints ${counts['printed']}, no file ${counts['no_file']}, '
      'length unread ${counts['no_length']}',
    );
    for (final choice in store.versionChoices().values) {
      stdout.writeln(
        '  row ${choice.trackId}: ${choice.state.name}, listed '
        '${choice.listedSec} s, VK file ${choice.ownSeconds.toStringAsFixed(1)}'
        ' s, plays ${choice.expectSeconds.toStringAsFixed(1)} s',
      );
    }
  } finally {
    store.close();
  }
}
