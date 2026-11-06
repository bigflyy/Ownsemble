/// The background check of every song's VK file after a sync (Stage M2,
/// user 2026-11-06: "lets just check ahead of time").
///
/// VK sometimes swaps the file behind a song for another recording (Stage
/// K). The player used to find that only when the song played, so the first
/// play waited for VK's search and the song's tag appeared only then. This
/// check reads a print of every listed song's file (its real length among
/// it) once a week, and for songs more than 3 s off their listed length runs
/// the version search and stores the choice, before anyone plays them.
///
/// Read-only on VK: `audio.getById`, small range reads of each file and
/// `audio.search`. Nothing on any account changes, and no link is kept or
/// logged.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../library/file_print.dart';
import '../library/library_store.dart';
import '../library/song_version.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_file_print.dart';
import '../vk/vk_versions.dart';
import 'background_sync.dart';

/// How many songs are printed between two progress reports and saves, so
/// a check cut short by closing the app keeps what it read.
const _printBatch = 120;

/// The pause between two version searches. Real VK 2026-11-06: after about
/// 25 searches in quick succession VK wanted a captcha for every search, the
/// user's own search from a song's Versions too. The check is in no hurry,
/// so it searches one song at a time and leaves VK's allowance to the user.
const fileCheckSearchGap = Duration(seconds: 4);

/// How far the check is: files read, then versions searched.
class FileCheckProgress {
  const FileCheckProgress({
    required this.done,
    required this.total,
    this.searching = false,
  });

  final int done;
  final int total;

  /// False while files are read, true while versions are searched.
  final bool searching;

  /// Share finished, 0 to 1: reading the files is most of the time.
  double get fraction {
    final part = total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
    return searching ? 0.9 + 0.1 * part : 0.9 * part;
  }
}

/// What one check did.
class FileCheckOutcome {
  const FileCheckOutcome({
    this.checked = 0,
    this.swapped = 0,
    this.decided = 0,
    this.failed = 0,
    this.forgotten = 0,
    this.readMs = 0,
    this.searchMs = 0,
  });

  /// Files read.
  final int checked;

  /// Songs found swapped that had no version chosen, and how many of them
  /// got one stored; the [failed] searches are tried on the next sync.
  final int swapped;
  final int decided;
  final int failed;

  /// Automatic choices dropped because VK gave the listed file back.
  final int forgotten;

  final int readMs;
  final int searchMs;

  /// Whether stored version choices changed, so the app reloads them.
  bool get changedChoices => decided > 0 || forgotten > 0;
}

/// Runs one check and reports progress; how the app starts it.
typedef FileCheckRunner = Future<FileCheckOutcome> Function(
  void Function(FileCheckProgress) onProgress,
);

/// Reads the prints of [rows] of account [sourceId], by row id. A row left
/// out could not be read now and is tried on the next sync.
typedef ReadPrints = Future<Map<int, FilePrint>> Function(
  int sourceId,
  List<PrintRequest> rows,
);

/// Finds the uploads of [song] on VK through its own account. Throws as VK
/// does.
typedef FindSongVersions = Future<List<SongVersion>> Function(SwappedSong song);

/// The check itself, without the network: reads the prints of the songs
/// [LibraryStore.filesToCheck] names whose account is [reachable], forgets
/// choices VK fixed, then decides a version for each swapped song.
Future<FileCheckOutcome> checkFiles({
  required LibraryStore store,
  required Set<int> reachable,
  required ReadPrints readPrints,
  required FindSongVersions findVersions,
  void Function(FileCheckProgress)? onProgress,
  Duration searchGap = fileCheckSearchGap,
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  final reading = Stopwatch()..start();
  final wanted = [
    for (final row in store.filesToCheck(nowMs: clock()))
      if (reachable.contains(row.sourceId)) row,
  ];
  var checked = 0;
  onProgress?.call(FileCheckProgress(done: 0, total: wanted.length));
  for (var start = 0; start < wanted.length; start += _printBatch) {
    final batch = wanted.skip(start).take(_printBatch).toList();
    final bySource = <int, List<PrintRequest>>{};
    for (final row in batch) {
      (bySource[row.sourceId] ??= []).add(row);
    }
    for (final MapEntry(key: sourceId, value: rows) in bySource.entries) {
      final prints = await readPrints(sourceId, rows);
      store.savePrints(prints, atMs: clock());
      checked += prints.length;
    }
    onProgress?.call(
      FileCheckProgress(done: start + batch.length, total: wanted.length),
    );
  }
  reading.stop();
  final forgotten = store.forgetFixedChoices();

  final searching = Stopwatch()..start();
  final swapped = [
    for (final song in store.swappedToDecide())
      if (reachable.contains(song.sourceId)) song,
  ];
  var decided = 0;
  var failed = 0;
  onProgress?.call(
    FileCheckProgress(done: 0, total: swapped.length, searching: true),
  );
  for (final (index, song) in swapped.indexed) {
    if (index > 0) await Future<void>.delayed(searchGap);
    try {
      final found = await findVersions(song);
      // Kept, so the song's versions open at once (plan 03).
      store.saveFoundVersions(song.trackId, found, atMs: clock());
      store.saveVersionChoice(
        decideVersion(
          trackId: song.trackId,
          listedSec: song.listedSec,
          ownSeconds: song.ownSeconds,
          ownBytes: song.ownBytes,
          found: found,
          nowMs: clock(),
        ),
      );
      decided++;
    } on Object catch (error) {
      if (error is VkException && error.slowDown) {
        // VK wants a captcha: more searches only make it last. The rest
        // wait for the next sync, and the user's own searches get
        // through sooner.
        failed += swapped.length - index;
        break;
      }
      failed++;
    }
    onProgress?.call(
      FileCheckProgress(
        done: decided + failed,
        total: swapped.length,
        searching: true,
      ),
    );
  }
  searching.stop();
  return FileCheckOutcome(
    checked: checked,
    swapped: swapped.length,
    decided: decided,
    failed: failed,
    forgotten: forgotten,
    readMs: reading.elapsedMilliseconds,
    searchMs: searching.elapsedMilliseconds,
  );
}

/// Checks the files of the library at [dbPath] through the VK accounts of
/// [sessions], in a background isolate with its own database connection,
/// so neither the list nor playback ever waits for it. An account that
/// does not connect leaves its songs for the next sync.
Future<FileCheckOutcome> checkVkFilesInBackground({
  required String dbPath,
  required List<VkSyncSession> sessions,
  required void Function(FileCheckProgress) onProgress,
}) async {
  final progress = ReceivePort();
  progress.listen((message) => onProgress(message as FileCheckProgress));
  try {
    return await _runInIsolate(dbPath, sessions, progress.sendPort);
  } finally {
    progress.close();
  }
}

// A separate function so the isolate's closure captures only these values.
Future<FileCheckOutcome> _runInIsolate(
  String dbPath,
  List<VkSyncSession> sessions,
  SendPort progress,
) => Isolate.run(() => _checkAll(dbPath, sessions, progress));

Future<FileCheckOutcome> _checkAll(
  String dbPath,
  List<VkSyncSession> sessions,
  SendPort progress,
) async {
  final store = LibraryStore.open(dbPath);
  final clients = <int, VkClient>{};
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    for (final session in sessions) {
      final client = VkClient(
        session.cookies,
        requestTimeout: const Duration(minutes: 1),
        silenceTimeout: const Duration(seconds: 30),
      );
      try {
        await retryTransient(client.ensureToken);
      } on Object {
        client.close();
        continue;
      }
      final source = store
          .sources()
          .where(
            (s) => s.kind == TrackSource.vk && s.account == '${client.userId}',
          )
          .firstOrNull;
      if (source == null) {
        client.close();
        continue;
      }
      clients[source.id] = client;
    }
    return await checkFiles(
      store: store,
      reachable: clients.keys.toSet(),
      readPrints: (sourceId, rows) async {
        final byKey = await printVkFiles(clients[sourceId]!, [
          for (final row in rows)
            (key: row.sourceKey, accessKey: row.accessKey),
        ], http: http);
        return {for (final row in rows) row.trackId: ?byKey[row.sourceKey]};
      },
      findVersions: (song) => findVkVersions(
        clients[song.sourceId]!,
        VersionQuery(
          artist: song.artist,
          title: song.title,
          vkTrackId: song.vkTrackId,
          ownKeys: song.ownKeys,
        ),
        http: http,
      ),
      onProgress: progress.send,
    );
  } finally {
    http.close(force: true);
    for (final client in clients.values) {
      client.close();
    }
    store.close();
  }
}
