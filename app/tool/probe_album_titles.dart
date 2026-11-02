// Shows what VK knows about the albums of "unnamed" songs: whether a batched
// audio.getById on the songs' release keys names the album, and what
// audio.getPlaylistById says for each album. For deciding how a sync should
// get real album titles.
//
// Prints only named fields: titles, kinds and counts. Never a link, a key or
// any other part of a raw reply: VK's replies hold signed stream links.
//
// Run from app/:
//   dart run tool/probe_album_titles.dart --vk-session FILE

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  final at = args.indexOf('--vk-session');
  if (at < 0 || at + 1 >= args.length) {
    stderr.writeln('--vk-session is required');
    exit(64);
  }
  final vk = VkClient(SessionCookie.loadAll(File(args[at + 1])));
  await vk.ensureToken();
  final userId = vk.userId;

  final page =
      await vk.call('audio.get', {'owner_id': '$userId', 'count': '200'})
          as Map<String, dynamic>;
  final items = (page['items'] as List).cast<Map<String, dynamic>>();

  final kinds = <String, int>{};
  final unnamed = <Map<String, dynamic>>[];
  for (final item in items) {
    final album = item['album'];
    final String kind;
    if (album is! Map<String, dynamic>) {
      kind = 'no album object';
    } else {
      final title = (album['title'] as String?) ?? '';
      kind = title.isEmpty
          ? 'empty title'
          : title == 'unnamed'
          ? 'unnamed'
          : 'named';
      if (kind == 'unnamed') unnamed.add(item);
    }
    kinds[kind] = (kinds[kind] ?? 0) + 1;
  }
  print('${items.length} songs: $kinds');

  // One call: the songs' release copies.
  final releaseKeys = [
    for (final item in unnamed)
      if (item['release_audio_id'] is String) item['release_audio_id'] as String,
  ];
  print('${releaseKeys.length} of ${unnamed.length} have a release key');
  final byRelease = <String, String?>{};
  if (releaseKeys.isNotEmpty) {
    final reply =
        await vk.call('audio.getById', {
              'audios': releaseKeys.take(50).join(','),
            })
            as List;
    for (final item in reply.cast<Map<String, dynamic>>()) {
      final album = item['album'];
      byRelease['${item['owner_id']}_${item['id']}'] =
          album is Map<String, dynamic> ? album['title'] as String? : null;
    }
    print(
      'audio.getById on release keys: ${reply.length} replies, titles: '
      '${byRelease.values.toSet()}',
    );
  }

  // One call per album.
  final albums = <String, String>{};
  final seen = <String>{};
  for (final item in unnamed) {
    final album = item['album'] as Map<String, dynamic>;
    final key = '${album['owner_id']}_${album['id']}';
    if (!seen.add(key)) continue;
    final clock = Stopwatch()..start();
    try {
      final reply =
          await vk.call('audio.getPlaylistById', {
                'owner_id': '${album['owner_id']}',
                'playlist_id': '${album['id']}',
                if (album['access_key'] != null)
                  'access_key': album['access_key'] as String,
              })
              as Map<String, dynamic>;
      albums[key] = reply['title'] as String? ?? '';
      print(
        '"${item['title']}": album "${albums[key]}", '
        '${clock.elapsedMilliseconds} ms',
      );
    } on VkException catch (error) {
      // A message may carry a link, so it is scrubbed like the status bar's.
      final reason = error.message.replaceAll(
        RegExp(r'https?://\S+'),
        '<link>',
      );
      print('"${item['title']}": failed: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  print('${seen.length} albums for ${unnamed.length} songs');
  vk.close();
}
