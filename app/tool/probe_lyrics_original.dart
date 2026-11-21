// Read-only: songs whose library copy gives plain lyrics; do other uploads
// of the same recording (same VK track_id, or same name and length) give
// timed lyrics? Prints counts only, never words, keys or tokens.
//
//   dart run tool/probe_lyrics_original.dart --vk-session FILE [--songs 10]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final wanted = int.parse(valueOf('--songs') ?? '10');
  Future<void> pause() =>
      Future<void>.delayed(const Duration(milliseconds: 500));
  Future<String> kind(String id) async {
    await pause();
    try {
      final answer = await client.call('audio.getLyrics', {'audio_id': id});
      final lyrics = answer is Map ? answer['lyrics'] : null;
      if (lyrics is! Map) return 'none';
      return lyrics['timestamps'] is List ? 'timed' : 'plain';
    } on VkException catch (error) {
      return error.code == 104 ? 'none' : 'error ${error.code}';
    }
  }

  try {
    final reply = await client.call('audio.get', {'count': '200'}) as Map;
    final songs = (reply['items'] as List).cast<Map<String, dynamic>>();
    var tried = 0, helped = 0;
    for (final song in songs.where((s) => s['has_lyrics'] == true)) {
      if (tried >= wanted) break;
      final own = '${song['owner_id']}_${song['id']}';
      if (await kind(own) != 'plain') continue;
      tried++;
      await pause();
      final found = await client.call('audio.search', {
        'q': '${song['artist']} ${song['title']}',
        'count': '30',
      }) as Map;
      final items = (found['items'] as List).cast<Map<String, dynamic>>();
      final length = song['duration'] as int? ?? 0;
      final trackId = song['track_id'];
      final same = items
          .where((item) {
            final other = '${item['owner_id']}_${item['id']}';
            if (other == own) return false;
            final sameTrack = trackId != null && item['track_id'] == trackId;
            final sameLength =
                ((item['duration'] as int? ?? -99) - length).abs() <= 2;
            return sameTrack || sameLength;
          })
          .take(4)
          .toList();
      final kinds = <String>[];
      for (final item in same) {
        final official =
            item['is_official'] == true || item['track_code'] != null;
        kinds.add(
          '${await kind('${item['owner_id']}_${item['id']}')}'
          '${item['track_id'] == trackId && trackId != null ? ' (same track id)' : ''}'
          '${official ? ' (official)' : ''}',
        );
      }
      if (kinds.any((k) => k.startsWith('timed'))) helped++;
      print(
        'plain song $tried (track id ${trackId == null ? 'none' : 'yes'}): '
        '${same.length} other uploads: ${kinds.join('; ')}',
      );
    }
    print('plain songs with a timed other upload: $helped of $tried');
  } on Object catch (error) {
    print(
      'failed: ${error.runtimeType} ${error is VkException ? error.code : ''}',
    );
  } finally {
    client.close();
  }
}
