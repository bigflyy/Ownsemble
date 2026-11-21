// Read-only: which stored fields of the library's VK songs differ from what
// VK gives now, field by field, the way a sync compares them (covers by
// path and query, as the sync's own rule). Finds the song a "Sync now" right
// after another one counts as updated (acceptance-34b). TEST ACCOUNT ONLY.
//
//   dart run tool/check_sync_drift.dart --db <library.db> --vk-session <file>
//       [--rounds N] [--every-s S]
//
// Prints row ids, field names and counts only: no title, link, key or token.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart' show NewTrack;
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final at = args.indexOf(name);
    return at < 0 || at + 1 >= args.length ? null : args[at + 1];
  }

  final dbPath = valueOf('--db')!;
  final session = valueOf('--vk-session')!;
  if (session.toLowerCase().contains('session-2')) {
    throw StateError('test account only');
  }
  final rounds = int.parse(valueOf('--rounds') ?? '1');
  final everyS = int.parse(valueOf('--every-s') ?? '60');

  final client = VkClient(SessionCookie.loadAll(File(session)));
  await client.ensureToken();
  // Read-only: opening the store could migrate an old file.
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  final albumTitles = {
    for (final row in db.select('SELECT album_key, title FROM vk_album_titles'))
      row['album_key'] as String: row['title'] as String,
  };
  final stored = {
    for (final row in db.select(
      'SELECT * FROM tracks WHERE gone_at_ms IS NULL AND source_id = 1',
    ))
      row['source_key'] as String: row,
  };
  db.close();
  print('stored: ${stored.length} listed songs');

  bool sameImage(Object? a, String? b) {
    if (a == null || b == null) return a == b;
    final x = Uri.tryParse(a as String);
    final y = Uri.tryParse(b);
    return x != null && y != null && x.path == y.path && x.query == y.query;
  }

  for (var round = 1; round <= rounds; round++) {
    final library = await fetchVkLibrary(client.call, client.userId);
    final fieldCounts = <String, int>{};
    final rows = <String>[];
    var missing = 0;
    for (final item in library.items) {
      final fresh = vkItemToTrack(item, albumTitles: albumTitles);
      final row = stored[fresh.sourceKey];
      if (row == null) {
        missing++;
        continue;
      }
      final differs = <String>[
        if (row['access_key'] != fresh.accessKey) 'access_key',
        if (row['artist'] != fresh.artist) 'artist',
        if (row['title'] != fresh.title) 'title',
        if (row['album'] != fresh.album) 'album',
        if (row['duration_sec'] != fresh.durationSec) 'duration_sec',
        if (row['added_at'] != fresh.addedAt) 'added_at',
        if (!sameImage(row['cover_url'], fresh.coverUrl)) 'cover_url',
        if (!sameImage(row['cover_large_url'], fresh.coverLargeUrl))
          'cover_large_url',
        if (!sameImage(row['cover_mid_url'], fresh.coverMidUrl))
          'cover_mid_url',
        if (!sameImage(row['cover_full_url'], fresh.coverFullUrl))
          'cover_full_url',
        if (row['tint'] != fresh.tint) 'tint',
      ];
      for (final field in differs) {
        fieldCounts[field] = (fieldCounts[field] ?? 0) + 1;
      }
      if (differs.isNotEmpty) {
        final detail = [
          for (final field in differs)
            if (field == 'added_at' || field == 'duration_sec')
              '$field ${row[field]} -> '
                  '${field == 'added_at' ? fresh.addedAt : fresh.durationSec}'
            else if (field == 'tint')
              'tint ${row['tint']} -> ${fresh.tint}'
            else if (field.startsWith('cover'))
              '$field ${row[field] == null ? 'none' : 'set'} -> '
                  '${_cover(fresh, field) == null ? 'none' : 'set'}'
            else
              field,
        ];
        rows.add('row ${row['id']}: ${detail.join(', ')}');
      }
    }
    print(
      'round $round at ${DateTime.now().toIso8601String()}: VK '
      '${library.items.length} songs, $missing not stored, '
      '${rows.length} differ $fieldCounts',
    );
    rows.forEach(print);
    // Songs with an album link and no album name: what VK's reply and the
    // album itself say (kinds only).
    for (final item in library.items) {
      final row = stored[vkSourceKey(item)];
      final album = item['album'];
      if (row == null || album is! Map<String, dynamic>) continue;
      if (row['album'] != null) continue;
      final title = (album['title'] as String?)?.trim() ?? '';
      String kind(String text) => switch (text) {
        '' => 'empty',
        'unnamed' => '"unnamed"',
        _ => 'a name',
      };
      var own = 'not asked';
      try {
        final reply = await client.call('audio.getPlaylistById', {
          'owner_id': '${album['owner_id']}',
          'playlist_id': '${album['id']}',
          if (album['access_key'] case final String accessKey)
            'access_key': accessKey,
        }) as Map<String, dynamic>;
        own = kind((reply['title'] as String?)?.trim() ?? '');
      } on Object catch (error) {
        own = 'failed (${error.runtimeType})';
      }
      print(
        'row ${row['id']}: reply album title ${kind(title)}, '
        'the album itself: $own',
      );
    }
    if (round < rounds) await Future<void>.delayed(Duration(seconds: everyS));
  }
}

String? _cover(NewTrack track, String field) => switch (field) {
  'cover_url' => track.coverUrl,
  'cover_large_url' => track.coverLargeUrl,
  'cover_mid_url' => track.coverMidUrl,
  _ => track.coverFullUrl,
};
