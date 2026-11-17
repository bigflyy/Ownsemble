// Makes one playlist on the TEST account for the real check of the
// Playlists place (plan 08, B3; user 2026-11-17: "1 yes", leave it there):
// 3 songs of the account's library and 3 songs it lacks (from a search),
// mixed. Does nothing when a playlist with the title is there already.
//
// Writes to VK: creates a playlist and adds songs to it. Only for the test
// account's session file, never the second account.
//
// Prints counts, yes/no and VK error codes only: never a link, key, token,
// id or whole reply.
//
// Run from app/:
//   dart run tool/make_test_playlist.dart --vk-session FILE
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

const testTitle = 'Ownsemble test';

String keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

Future<void> main(List<String> args) async {
  final at = args.indexOf('--vk-session');
  final path = at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  if (path == null || path.contains('session-2')) {
    print('give the TEST account: --vk-session ../.local/v2-test/session.json');
    exitCode = 2;
    return;
  }
  final client = VkClient(
    SessionCookie.loadAll(File(path)),
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
  );
  try {
    await client.ensureToken();
    final me = client.userId;
    final lists = await client.call('audio.getPlaylists', {
      'owner_id': '$me',
      'count': '200',
    }) as Map<String, dynamic>;
    final there = (lists['items'] as List).where(
      (item) => (item as Map)['title'] == testTitle,
    );
    if (there.isNotEmpty) {
      print('a playlist "$testTitle" is there already: nothing done');
      return;
    }

    final library = await client.call('audio.get', {
      'count': '200',
    }) as Map<String, dynamic>;
    final libraryItems = (library['items'] as List)
        .cast<Map<String, dynamic>>();
    final ownKeys = {for (final item in libraryItems) keyOf(item)};
    final ownTitles = {
      for (final item in libraryItems)
        '${item['artist']}|${item['title']}'.toLowerCase(),
    };
    // Three library songs from the middle of the library, not its newest.
    final mine = [
      for (final i in [3, 11, 25])
        if (i < libraryItems.length) libraryItems[i],
    ];

    final outside = <Map<String, dynamic>>[];
    for (final query in ['Кино', 'Земфира', 'Сплин']) {
      final found = await client.call('audio.search', {
        'q': query,
        'count': '20',
      }) as Map<String, dynamic>;
      for (final item
          in (found['items'] as List).cast<Map<String, dynamic>>()) {
        final playable = '${item['url'] ?? ''}'.isNotEmpty;
        final title = '${item['artist']}|${item['title']}'.toLowerCase();
        if (playable &&
            !ownKeys.contains(keyOf(item)) &&
            !ownTitles.contains(title)) {
          outside.add(item);
          break;
        }
      }
    }
    print('picked ${mine.length} library songs, ${outside.length} others');

    final made = await client.call('audio.createPlaylist', {
      'owner_id': '$me',
      'title': testTitle,
    }) as Map<String, dynamic>;
    final id = made['id'];
    print('playlist made: ${id is int ? 'yes' : 'no'}');
    if (id is! int) return;

    // Library and other songs mixed: other, mine, other, mine, ...
    final order = [
      for (var i = 0; i < 3; i++) ...[
        if (i < outside.length) outside[i],
        if (i < mine.length) mine[i],
      ],
    ];
    final added = await client.call('audio.addToPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$id',
      'audio_ids': [for (final item in order) keyOf(item)].join(','),
    });
    print(
      'added: ${added is List ? '${added.length} of ${order.length}' : 'reply ${added.runtimeType}'}',
    );
  } on VkException catch (error) {
    print('VK error: ${error.message.replaceAll(RegExp(r'\d{4,}'), 'N')}');
    exitCode = 1;
  } finally {
    client.close();
  }
}
