// Times VK's audio.search the way the versions place asks it. Default: one
// call per song, no retry, so slow or empty answers show as they are. With
// --full: the app's whole search (findVkVersions: a stalled request sent
// again, then each upload's file measured) with its perf.log figures.
// Titles go to the console only. Read-only; prints no link or key.
//
// Run from app/:
//   dart run tool/probe_search_pace.dart --data-dir DIR --vk-session FILE
//     [--songs N] [--track-id N --times N] [--full]

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_versions.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  final songs = int.tryParse(valueOf('--songs') ?? '') ?? 8;
  final only = int.tryParse(valueOf('--track-id') ?? '');
  final times = int.tryParse(valueOf('--times') ?? '') ?? 1;
  final full = args.contains('--full');
  if (dataDir == null || sessionPath == null) {
    stderr.writeln('--data-dir and --vk-session are required');
    exitCode = 2;
    return;
  }
  final store = LibraryStore.open(p.join(dataDir, 'library.db'));
  final tracks = store.loadAll().where((t) => t.inLibrary).toList()
    ..shuffle(Random(7));
  final client = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final picked = only == null
      ? tracks.take(songs)
      : List.filled(times, tracks.firstWhere((t) => t.id == only));
  for (final track in picked) {
    final clock = Stopwatch()..start();
    String outcome;
    if (full) {
      final stats = VersionSearchStats();
      try {
        await findVkVersions(
          client,
          VersionQuery(
            artist: track.artist,
            title: track.title,
            vkTrackId: store.vkTrackIdOf(track.id),
            ownKeys: {for (final copy in track.allCopies) ?copy.sourceKey},
          ),
          stats: stats,
        );
        print('#${track.id}: $stats');
      } on Object catch (error) {
        print('#${track.id}: FAILED $stats: $error');
      }
      continue;
    }
    try {
      final reply = await client.call('audio.search', {
        'q': '${track.artist} ${track.title}',
        'count': '$versionSearchCount',
      });
      final items = reply is Map<String, dynamic> && reply['items'] is List
          ? (reply['items'] as List).length
          : -1;
      outcome = '$items items';
    } on VkException catch (error) {
      outcome = 'VK error (transient ${error.transient}): ${error.message}';
    } on Object catch (error) {
      outcome = 'failed: ${error.runtimeType}';
    }
    print(
      '#${track.id} ${track.artist} - ${track.title}: '
      '${clock.elapsedMilliseconds} ms, $outcome',
    );
  }
  client.close();
  store.close();
}
