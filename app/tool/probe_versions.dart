// Runs the app's own version search (Stage K) for one library row against
// real VK and prints what the version dialog would list: the row's current
// VK file and every upload found, ranked, with listed and real lengths and
// the suggested match. Read-only; prints no link or key. Titles go to the
// console only (second account: keep them out of the repo).
//
// Run from app/:
//   dart run tool/probe_versions.dart --data-dir DIR --vk-session FILE
//     --track-id N

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_versions.dart';
import 'package:path/path.dart' as p;

/// "m:ss.s" of [seconds].
String clock(double seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toStringAsFixed(1).padLeft(4, '0')}';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  final trackId = int.tryParse(valueOf('--track-id') ?? '');
  if (dataDir == null || sessionPath == null || trackId == null) {
    stderr.writeln('--data-dir, --vk-session and --track-id are required');
    exitCode = 2;
    return;
  }
  // Read through the store, but nothing is written: persist is off.
  final store = LibraryStore.open(p.join(dataDir, 'library.db'));
  final track = store.loadAll().firstWhere((t) => t.id == trackId);
  final client = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final clock0 = Stopwatch()..start();
  // What VersionBook.versionsOf does, without Flutter: the row's current
  // file and the uploads the search finds, ranked.
  final (found, own) = await (
    findVkVersions(
      client,
      VersionQuery(
        artist: track.artist,
        title: track.title,
        vkTrackId: store.vkTrackIdOf(track.id),
        ownKeys: {for (final copy in track.allCopies) ?copy.sourceKey},
      ),
    ),
    measureVkFile(client, track.sourceKey!, track.accessKey),
  ).wait;
  final versions = rankVersions(track.durationSec, [
    SongVersion(
      key: track.sourceKey!,
      artist: track.artist,
      title: track.title,
      album: track.album,
      listedSec: track.durationSec,
      file: own,
      isCurrentFile: true,
    ),
    ...found,
  ]);
  final searchMs = clock0.elapsedMilliseconds;
  print(
    'song #${track.id}: ${track.artist} - ${track.title}, listed '
    '${track.durationSec} s, VK track_id ${store.vkTrackIdOf(track.id)}',
  );
  final suggested = suggestedVersion(track.durationSec, versions);
  for (final version in versions) {
    final file = version.file;
    final marks = [
      if (version.isCurrentFile) "VK's current file",
      if (identical(version, suggested)) 'SUGGESTED',
      if (version.matches(track.durationSec)) 'match',
      if (version.official) 'official',
    ].join(', ');
    print(
      '  ${version.artist} - ${version.title} | listed '
      '${version.listedSec} s | file '
      '${file == null ? 'unknown' : '${clock(file.seconds)} (${file.bytes} bytes)'}'
      ' | album ${version.album ?? '-'}${marks.isEmpty ? '' : ' | $marks'}',
    );
  }
  print(
    '${versions.length} versions in $searchMs ms; '
    '${suggested == null ? 'no match within 1 s' : 'suggested ${clock(suggested.file!.seconds)}'}',
  );
  client.close();
  store.close();
}
