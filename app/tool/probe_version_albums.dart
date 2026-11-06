// Searches VK for one song the way the versions place does and tries to
// list the album of each upload that names one, as the album place does.
// Prints album titles, song counts and errors only: no link, token or key.
//
// Run from app/:
//   dart run tool/probe_version_albums.dart --vk-session FILE --q "artist title"

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_album.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_versions.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  try {
    final reply =
        await client.call('audio.search', {
              'q': valueOf('--q')!,
              'count': '$versionSearchCount',
            })
            as Map<String, dynamic>;
    final items = (reply['items'] as List).cast<Map<String, dynamic>>();
    print('search: ${items.length} items');
    for (final item in items) {
      final album = item['album'];
      if (album is! Map<String, dynamic>) continue;
      final version = versionFromItem(item);
      final owner = album['owner_id'];
      print(
        '${item['artist']} - ${item['title']}: album "${album['title']}" '
        '(owner ${owner is int && owner < 0 ? 'group' : 'user'}, '
        'access key ${version.albumAccessKey == null ? 'none' : 'given'}, '
        'key ${version.albumKey == null ? 'none' : 'given'})',
      );
      if (version.albumKey == null) continue;
      try {
        final songs = await fetchVkAlbumItems(
          client.call,
          version.albumKey!,
          accessKey: version.albumAccessKey,
        );
        print('  listed: ${songs.length} songs');
      } on Object catch (error) {
        final text = '$error'.replaceAll(RegExp(r'https?://\S+'), '<url>');
        print('  failed: ${text.length > 160 ? text.substring(0, 160) : text}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close();
  }
}
