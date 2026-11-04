// Shows how VK lists the songs of an album that a library song belongs to,
// for the album view (plan Stage H): which call gives the songs, how long it
// takes, how many songs have a link, and how the album's songs match the
// library's copies (by `track_id`, by `release_audio_id`, by owner and id).
//
// Read-only: only audio.get and audio.getPlaylistById are called.
//
// Prints only named fields: titles, counts, timings and kinds. Never a link,
// a key or any other part of a raw reply: VK's replies hold signed stream
// links. With --no-names even titles stay out (the second test account's
// songs stay out of the public repo and its notes).
//
// Run from app/:
//   dart run tool/probe_album_songs.dart --vk-session FILE [--albums N]
//     [--no-names]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

String scrub(String text) => text.replaceAll(RegExp(r'https?://\S+'), '<link>');

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final sessionPath = option('--vk-session');
  if (sessionPath == null) {
    stderr.writeln('--vk-session is required');
    exit(64);
  }
  final albumLimit = int.tryParse(option('--albums') ?? '') ?? 6;
  final names = !args.contains('--no-names');

  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  await vk.ensureToken();
  final userId = vk.userId;

  // The library's first page is enough to find albums to try.
  final page = await vk.call('audio.get', {
    'owner_id': '$userId',
    'count': '200',
  }) as Map<String, dynamic>;
  final library = (page['items'] as List).cast<Map<String, dynamic>>();
  final libraryTrackIds = {
    for (final item in library)
      if (item['track_id'] != null) '${item['track_id']}',
  };
  final libraryReleaseKeys = {
    for (final item in library)
      if (item['release_audio_id'] is String)
        item['release_audio_id'] as String,
  };

  // Albums of the library's songs, each once, with how many library songs
  // name it; the most used first, so albums with several saved songs are tried.
  final albums = <String, Map<String, dynamic>>{};
  final uses = <String, int>{};
  for (final item in library) {
    if (item['album'] case final Map<String, dynamic> album) {
      final key = '${album['owner_id']}_${album['id']}';
      albums[key] = album;
      uses[key] = (uses[key] ?? 0) + 1;
    }
  }
  final keys = albums.keys.toList()
    ..sort((a, b) => uses[b]!.compareTo(uses[a]!));
  print(
    '${library.length} library songs, ${albums.length} albums, '
    'access key on ${albums.values.where((a) => a['access_key'] != null).length}',
  );

  for (final (index, key) in keys.take(albumLimit).indexed) {
    final album = albums[key]!;
    final label = names ? '"${album['title']}"' : 'album ${index + 1}';
    final access = <String, String>{
      if (album['access_key'] case final String accessKey)
        'access_key': accessKey,
    };
    print('--- $label, ${uses[key]} song(s) in the library');

    final infoClock = Stopwatch()..start();
    try {
      final info = await vk.call('audio.getPlaylistById', {
        'owner_id': '${album['owner_id']}',
        'playlist_id': '${album['id']}',
        ...access,
      }) as Map<String, dynamic>;
      print(
        'getPlaylistById ${infoClock.elapsedMilliseconds} ms: '
        'count ${info['count']}, type ${info['type']}, '
        'album_type ${info['album_type']}, year ${info['year']}, '
        'has main_artists ${info['main_artists'] is List}, '
        'has photo ${info['photo'] is Map}, has thumbs ${info['thumbs'] is List}'
        '${names ? ', title "${info['title']}"' : ''}',
      );
    } on VkException catch (error) {
      print('getPlaylistById failed: ${scrub(error.message)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final songsClock = Stopwatch()..start();
    try {
      final reply = await vk.call('audio.get', {
        'owner_id': '${album['owner_id']}',
        'album_id': '${album['id']}',
        ...access,
        'count': '200',
      }) as Map<String, dynamic>;
      final items = (reply['items'] as List).cast<Map<String, dynamic>>();
      final withLink = items.where((i) => (i['url'] as String? ?? '') != '');
      final byTrackId = items.where(
        (i) => libraryTrackIds.contains('${i['track_id']}'),
      );
      final byKey = items.where(
        (i) => libraryReleaseKeys.contains('${i['owner_id']}_${i['id']}'),
      );
      final sameAlbum = items.where((i) {
        final own = i['album'];
        return own is Map<String, dynamic> &&
            '${own['owner_id']}_${own['id']}' == key;
      });
      print(
        'audio.get album ${songsClock.elapsedMilliseconds} ms: '
        'count ${reply['count']}, items ${items.length}, '
        'with link ${withLink.length}, access key on '
        '${items.where((i) => i['access_key'] != null).length}, '
        'own album object = this album on ${sameAlbum.length}, '
        'in library by track_id ${byTrackId.length}, '
        'by release key ${byKey.length}, '
        'owner = album owner on '
        '${items.where((i) => '${i['owner_id']}' == '${album['owner_id']}').length}',
      );
      if (names) {
        for (final item in items.take(3)) {
          print(
            '  ${item['artist']} - ${item['title']} '
            '(${item['duration']} s, track_id ${item['track_id'] != null})',
          );
        }
      }
    } on VkException catch (error) {
      print('audio.get album failed: ${scrub(error.message)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  vk.close();
}
