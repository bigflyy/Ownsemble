// What VK gives for playlists (plan 08, Stage A): the account's own and
// followed playlists (audio.getPlaylists), their fields, and their songs
// (audio.get with a playlist id): order, repeats, songs VK gives no file for,
// how many the library has, and whether a followed playlist reads the same
// through its copy and through its original.
//
// READ ONLY: nothing is created, followed, edited or removed on VK.
//
// Prints an ALLOWLIST of named fields only: kinds, counts, ages in days,
// yes/no flags, field names and error codes; playlist and song names only
// without --counts-only. Never a link, key, token, id or whole reply.
//
// Run from app/:
//   dart run tool/probe_playlists.dart --vk-session FILE [--counts-only]
//     [--lists N]
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

/// Long numbers blanked, so an id inside an error text never shows.
String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

String keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

/// Who owns a playlist, as a kind only.
String ownerKind(Object? ownerId, int me) => switch (ownerId) {
  final int id when id == me => 'own',
  final int id when id < 0 => 'group',
  int() => 'user',
  _ => 'none',
};

/// Field names of a map, one level into maps and lists of maps. No values.
Set<String> fieldPaths(Map<String, dynamic> map, [String prefix = '']) {
  final seen = <String>{};
  for (final MapEntry(:key, :value) in map.entries) {
    final path = '$prefix$key';
    seen.add(path);
    if (prefix.isNotEmpty) continue;
    if (value is Map<String, dynamic>) {
      seen.addAll(fieldPaths(value, '$path.'));
    } else if (value is List &&
        value.isNotEmpty &&
        value.first is Map<String, dynamic>) {
      seen.addAll(fieldPaths(value.first as Map<String, dynamic>, '$path[].'));
    }
  }
  return seen;
}

/// Days from a Unix time to now, or '-' without one.
String ageDays(Object? unix) => unix is int && unix > 0
    ? '${DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unix * 1000)).inDays}d'
    : '-';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final countsOnly = args.contains('--counts-only');
  final maxLists = int.parse(valueOf('--lists') ?? '12');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
  );
  String name(Object? text) => countsOnly ? '(name)' : '$text';

  Future<Object?> ask(String method, Map<String, String> params) async {
    try {
      return await client.call(method, params);
    } on VkException catch (error) {
      print('  $method: VK error ${blank(error.message)}');
      return null;
    }
  }

  try {
    await client.ensureToken();
    final me = client.userId;
    print('probe_playlists ${DateTime.now().toIso8601String()}');

    // The library's keys, to count the playlist songs it has.
    final ownKeys = <String>{};
    var total = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final library = await client.call('audio.get', {
        'count': '500',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      total = library['count'] as int;
      for (final item in (library['items'] as List)) {
        ownKeys.add(keyOf(item as Map<String, dynamic>));
      }
    }
    print('library: $total songs');

    // 1. The playlists, as the music page's "My playlists" lists them.
    final reply = await ask('audio.getPlaylists', {
      'owner_id': '$me',
      'count': '200',
    }) as Map<String, dynamic>?;
    if (reply == null) return;
    final lists = (reply['items'] as List).cast<Map<String, dynamic>>();
    print('audio.getPlaylists: count ${reply['count']}, ${lists.length} items');
    final fields = <String>{};
    for (final list in lists) {
      fields.addAll(fieldPaths(list));
    }
    print('playlist fields: ${(fields.toList()..sort()).join(' ')}');
    final kinds = <String, int>{};
    for (final list in lists) {
      final original = list['original'] as Map<String, dynamic>?;
      final kind =
          'type ${list['type']} owner ${ownerKind(list['owner_id'], me)}'
          '${original == null ? '' : ' original ${ownerKind(original['owner_id'], me)}'}'
          '${list['album_type'] == null ? '' : ' album_type ${list['album_type']}'}';
      kinds[kind] = (kinds[kind] ?? 0) + 1;
    }
    print('kinds: $kinds');

    // 2. Each playlist: its fields as flags, then its songs.
    for (final list in lists.take(maxLists)) {
      final original = list['original'] as Map<String, dynamic>?;
      final photo = list['photo'] as Map<String, dynamic>?;
      final thumbs = list['thumbs'] as List?;
      print(
        '\n"${name(list['title'])}": type ${list['type']}, '
        'owner ${ownerKind(list['owner_id'], me)}, '
        'original ${original == null ? 'none' : ownerKind(original['owner_id'], me)}, '
        'following ${list['is_following']}, count ${list['count']}, '
        'created ${ageDays(list['create_time'])} ago, '
        'updated ${ageDays(list['update_time'])} ago, '
        'access_key ${list['access_key'] != null}, '
        'followers ${list['followers']}, plays ${list['plays']}, '
        'year ${list['year']}, album_type ${list['album_type']}, '
        'photo ${photo != null}, thumbs ${thumbs?.length ?? 0}, '
        'main_artists ${(list['main_artists'] as List?)?.length ?? 0}, '
        'description ${'${list['description'] ?? ''}'.length} chars, '
        'explicit ${list['is_explicit']}',
      );
      Future<List<Map<String, dynamic>>?> songsOf(
        Object? ownerId,
        Object? playlistId,
        Object? accessKey,
        String via,
      ) async {
        final clock = Stopwatch()..start();
        final songs = <Map<String, dynamic>>[];
        var count = 0;
        for (var offset = 0; offset == 0 || offset < count; offset += 500) {
          final page = await ask('audio.get', {
            'owner_id': '$ownerId',
            'playlist_id': '$playlistId',
            'access_key': ?(accessKey as String?),
            'count': '500',
            'offset': '$offset',
          }) as Map<String, dynamic>?;
          if (page == null) return null;
          count = page['count'] as int;
          songs.addAll((page['items'] as List).cast<Map<String, dynamic>>());
          if ((page['items'] as List).isEmpty) break;
        }
        final keys = [for (final song in songs) keyOf(song)];
        final repeats = keys.length - keys.toSet().length;
        final restricted = songs
            .where((s) => s['content_restricted'] != null)
            .length;
        final noUrl = songs.where((s) => '${s['url'] ?? ''}'.isEmpty).length;
        final have = keys.where(ownKeys.contains).length;
        print(
          '  songs via $via: VK count $count, got ${songs.length} in '
          '${clock.elapsedMilliseconds} ms, repeats $repeats, '
          'restricted $restricted, no link $noUrl, in library $have',
        );
        if (!countsOnly) {
          for (final song in songs.take(3)) {
            print(
              '    ${song['artist']} - ${song['title']} (${song['duration']} s)',
            );
          }
        }
        return songs;
      }

      final copy = await songsOf(
        list['owner_id'],
        list['id'],
        list['access_key'],
        'its id',
      );
      if (original != null) {
        final first = await songsOf(
          original['owner_id'],
          original['playlist_id'],
          original['access_key'],
          'the original',
        );
        if (copy != null && first != null) {
          final same = copy.map(keyOf).join(',') == first.map(keyOf).join(',');
          print('  copy and original: same songs in the same order: $same');
        }
      }
    }

    // 3. One playlist by id: anything more than in the list reply?
    if (lists.isNotEmpty) {
      final list = lists.first;
      final byId = await ask('audio.getPlaylistById', {
        'owner_id': '${list['owner_id']}',
        'playlist_id': '${list['id']}',
        'access_key': ?(list['access_key'] as String?),
      }) as Map<String, dynamic>?;
      if (byId != null) {
        final extra = fieldPaths(byId).difference(fieldPaths(list));
        print('\naudio.getPlaylistById adds fields: ${extra.toList()..sort()}');
      }
    }
  } finally {
    client.close();
  }
}
