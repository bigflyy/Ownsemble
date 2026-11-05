// Real check of Stage L: merging two accounts' songs only when VK gives them
// the same file. Copies a library with two accounts, syncs both through the
// real background sync (which now prints the candidates' files), and reports
// counts and timings. Then switches the likely rule on and off on the copy.
//
//   dart run tool/check_merges.dart --data-dir DIR --work-dir DIR2 \
//       --vk-session FILE --vk-session-2 FILE2
//
// Read-only on VK: sync and small range reads. DIR is not written; DIR2 is
// replaced. Prints row ids and numbers only: no titles (the second account's
// songs stay private) and no links.
import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/same_song.dart';
import 'package:ownsemble/sync/background_sync.dart';
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
  if (dataDir == null || workDir == null || first == null || second == null) {
    stderr.writeln(
      '--data-dir, --work-dir, --vk-session and --vk-session-2 are required',
    );
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

  final before = _counts(dbPath);
  stdout.writeln('before: $before');
  final sessions = [
    for (final path in [first, second])
      VkSyncSession(null, SessionCookie.loadAll(File(path))),
  ];

  for (final round in [1, 2]) {
    final clock = Stopwatch()..start();
    final outcome = await syncVkInBackground(
      dbPath: dbPath,
      sessions: sessions,
      onProgress: (_) {},
    );
    final merge = outcome.merge;
    stdout.writeln(
      'sync $round: ${clock.elapsedMilliseconds} ms, errors '
      '${outcome.errors.length}, printed ${outcome.printed} files in '
      '${outcome.printMs} ms; merged ${merge?.merged ?? 0}, undone '
      '${merge?.unmerged ?? 0}, marks changed ${merge?.marked ?? 0}',
    );
    for (final error in outcome.errors) {
      stdout.writeln('  error: $error');
    }
    stdout.writeln('after sync $round: ${_counts(dbPath)}');
  }

  _describePairs(dbPath);
  final store = LibraryStore.open(dbPath);
  try {
    store.writeSetting(LibraryStore.mergeLikelySetting, 'on');
    var clock = Stopwatch()..start();
    var merge = store.mergeSameSongs();
    stdout.writeln(
      'likely on: ${clock.elapsedMilliseconds} ms, merged ${merge.merged}, '
      'undone ${merge.unmerged}, marks changed ${merge.marked}; '
      'listed rows marked likely: '
      '${store.loadAll().where((t) => t.mergedLikely).length}',
    );
    store.writeSetting(LibraryStore.mergeLikelySetting, null);
    clock = Stopwatch()..start();
    merge = store.mergeSameSongs();
    stdout.writeln(
      'likely off: ${clock.elapsedMilliseconds} ms, merged ${merge.merged}, '
      'undone ${merge.unmerged}, marks changed ${merge.marked}',
    );
  } finally {
    store.close();
  }
  stdout.writeln('end: ${_counts(dbPath)}');
}

/// Rows, copies and prints in the library at [dbPath].
String _counts(String dbPath) {
  final store = LibraryStore.open(dbPath);
  try {
    final tracks = store.loadAll();
    final copies = tracks.fold<int>(0, (sum, t) => sum + t.copies.length);
    return '${tracks.length} listed rows, $copies copies merged in';
  } finally {
    store.close();
  }
}

/// For each candidate pair of two accounts: whether VK gives them the same
/// file, files within 1 s (the likely rule), other files, or not both read.
/// Ids and numbers only.
void _describePairs(String dbPath) {
  final db = sqlite3.open(dbPath);
  try {
    final rows = db.select('''
      SELECT t.id, t.source_id, t.source_key, t.artist, t.title,
             t.duration_sec, t.vk_track_id, t.same_as,
             p.listed_sec, p.bytes, p.sample, p.seconds
      FROM tracks t
      JOIN sources s ON s.id = t.source_id
      LEFT JOIN vk_file_prints p ON p.track_id = t.id
      WHERE s.kind = 'vk' AND s.removed_at_ms IS NULL
      ORDER BY t.id
    ''');
    final songs = [
      for (final row in rows)
        SongRow(
          id: row['id'] as int,
          sourceId: row['source_id'] as int,
          sourceKey: row['source_key'] as String,
          text: songMatchText(row['artist'] as String, row['title'] as String),
          seconds: row['duration_sec'] as int,
          vkTrackId: row['vk_track_id'] as int?,
        ),
    ];
    final byId = {for (final row in rows) row['id'] as int: row};
    final withFile = rows.where((row) => row['bytes'] != null).length;
    final printed = rows.where((row) => row['listed_sec'] != null).length;
    stdout.writeln(
      'prints: $printed rows, $withFile with a file, '
      '${printed - withFile} without',
    );
    final counts = <String, int>{};
    final byTrack = <Object, List<SongRow>>{};
    // Candidates share a track_id or a text (see isSameSong); a pair that
    // shares both is looked at once.
    for (final song in songs) {
      if (song.vkTrackId case final id?) (byTrack[id] ??= []).add(song);
      if (song.text.isNotEmpty) (byTrack[song.text] ??= []).add(song);
    }
    final seen = <(int, int)>{};
    for (final group in byTrack.values) {
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          final (a, b) = (group[i], group[j]);
          if (a.sourceId == b.sourceId ||
              a.sourceKey == b.sourceKey ||
              !isSameSong(a, b) ||
              !seen.add((a.id, b.id))) {
            continue;
          }
          final (ra, rb) = (byId[a.id]!, byId[b.id]!);
          final (sa, sb) = (
            (ra['seconds'] as num?)?.toDouble(),
            (rb['seconds'] as num?)?.toDouble(),
          );
          final kind = ra['listed_sec'] == null || rb['listed_sec'] == null
              ? 'not both read'
              : ra['bytes'] == null || rb['bytes'] == null
              ? 'a copy without a file'
              : ra['bytes'] == rb['bytes'] && ra['sample'] == rb['sample']
              ? 'same file'
              : sa != null && sb != null && (sa - sb).abs() <= 1.0
              ? 'other files within 1 s'
              : 'other files, lengths apart';
          counts[kind] = (counts[kind] ?? 0) + 1;
          if (kind == 'same file') continue;
          stdout.writeln(
            '  #${a.id} / #${b.id}: $kind; listed ${a.seconds} / '
            '${b.seconds} s, files ${sa?.toStringAsFixed(1)} / '
            '${sb?.toStringAsFixed(1)} s, ${ra['bytes']} / ${rb['bytes']} '
            'bytes, merged now: ${ra['same_as'] == b.id || rb['same_as'] == a.id}',
          );
        }
      }
    }
    stdout.writeln('candidate pairs: $counts');
  } finally {
    db.close();
  }
}
