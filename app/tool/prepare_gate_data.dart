// Prepares the speed-gate data folder: syncs the VK library from a saved test
// session, caches a few of its songs as local MP3 files and adds generated
// songs up to the requested total. Prints only counts and timings: no titles,
// tokens or links.
//
// Run from app/:
//   dart run tool/prepare_gate_data.dart --data-dir DIR --vk-session FILE
//       [--songs 10000] [--cache 3]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_generator.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  if (dataDir == null) {
    stderr.writeln('--data-dir is required');
    exit(64);
  }
  final sessionPath = valueOf('--vk-session');
  final generatedCount = int.parse(valueOf('--songs') ?? '10000');
  final cacheCount = int.parse(valueOf('--cache') ?? '3');

  Directory(p.join(dataDir, 'cache')).createSync(recursive: true);
  final store = LibraryStore.open(p.join(dataDir, 'library.db'));
  final cachedFiles = <String>[];

  if (sessionPath != null) {
    final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
    try {
      final clock = Stopwatch()..start();
      await vk.ensureToken();
      final library = await fetchVkLibrary(vk.call, vk.userId);
      final sourceId = store.ensureSource(
        TrackSource.vk,
        account: '${vk.userId}',
        name: 'VK',
      );
      final ids = store.upsertAll(sourceId, library.items.map(vkItemToTrack));
      store.recordSync(sourceId);
      print(
        'VK sync: ${library.items.length}/${library.declaredCount} songs in '
        '${library.pages} page(s), ${clock.elapsedMilliseconds} ms.',
      );

      // Cache the first songs that have a stream, as the "cached song" case.
      for (var i = 0; i < library.items.length; i++) {
        if (cachedFiles.length >= cacheCount) break;
        final url = library.items[i]['url'] as String? ?? '';
        if (url.isEmpty) continue;
        // Stored relative to the data folder, which the app resolves against.
        final relative = p.join(
          'cache',
          'vk_${vkSourceKey(library.items[i])}.mp3',
        );
        final file = File(p.join(dataDir, relative));
        if (!file.existsSync()) await _download(url, file);
        store.saveAudioFile(ids[i], relative, file.lengthSync());
        cachedFiles.add(relative);
      }
      print('Cached ${cachedFiles.length} VK songs as local files.');
    } finally {
      vk.close();
    }
  }

  if (generatedCount > 0) {
    _addGenerated(store, dataDir, generatedCount, cachedFiles);
  }
  final generatedPlayable = store.loadAll().where(
    (t) => t.source == TrackSource.generated && t.isCached,
  );
  print('Generated songs with audio: ${generatedPlayable.length}.');
  store.close();
}

/// Adds [count] generated filler songs that borrow [cachedFiles]' audio.
void _addGenerated(
  LibraryStore store,
  String dataDir,
  int count,
  List<String> cachedFiles,
) {
  final clock = Stopwatch()..start();
  final generatedSource = store.ensureSource(
    TrackSource.generated,
    account: 'generator',
    name: 'Generated songs',
  );
  final generatedIds = store.upsertAll(generatedSource, generateSongs(count));
  // Filler songs borrow the cached files. They are pinned so the cache limit
  // never deletes audio that filler songs point at.
  if (cachedFiles.isNotEmpty) {
    for (var i = 0; i < generatedIds.length; i++) {
      final path = cachedFiles[i % cachedFiles.length];
      final bytes = File(p.join(dataDir, path)).lengthSync();
      store.saveAudioFile(generatedIds[i], path, bytes, pinned: true);
    }
  }
  print(
    'Generated songs: $count in ${clock.elapsedMilliseconds} ms '
    '(play the ${cachedFiles.length} cached files). '
    'Library total: ${store.count()}.',
  );
}

/// Downloads [url] into [target] through a temporary file.
Future<void> _download(String url, File target) async {
  final http = HttpClient();
  try {
    final response = await (await http.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      throw HttpException('download failed: HTTP ${response.statusCode}');
    }
    final partial = File('${target.path}.part');
    await response.pipe(partial.openWrite());
    partial.renameSync(target.path);
  } finally {
    http.close(force: true);
  }
}
