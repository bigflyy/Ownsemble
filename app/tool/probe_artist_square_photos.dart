// Where a square artist photo comes from (plan 09, C3): the artist page's
// own photo is a wide banner (795x200, 1510x344 on the test account), and
// the round tiles of the Artists place need squares. Asks, for the
// library's biggest artists: the page's photo sizes, and VK's artist search
// (audio.searchArtists, catalog.getAudioSearch) for the same id.
//
// READ ONLY. Prints sizes, counts, yes/no flags, times and error codes
// only; never an id, link or name.
//
// Run from app/:
//   dart run tool/probe_artist_square_photos.dart --vk-session FILE [--artists N]
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final count = int.parse(valueOf('--artists') ?? '8');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    requestTimeout: const Duration(seconds: 60),
    silenceTimeout: const Duration(seconds: 30),
  );
  Future<(Object?, int)> ask(String method, Map<String, String> params) async {
    final clock = Stopwatch()..start();
    try {
      return (await client.call(method, params), clock.elapsedMilliseconds);
    } on VkException catch (error) {
      print(
        '  $method: VK error ${error.code ?? 'other'} '
        '(${clock.elapsedMilliseconds} ms)',
      );
      return (null, clock.elapsedMilliseconds);
    }
  }

  /// "WxH" of each size in a VK image list ({url, width, height}).
  String sizes(Object? list) => list is List
      ? [
          for (final size in list)
            if (size is Map) '${size['width']}x${size['height']}',
        ].join(' ')
      : '(${list.runtimeType})';

  try {
    await client.ensureToken();
    print('probe_artist_square_photos ${DateTime.now().toIso8601String()}');
    final songs = <Map<String, dynamic>>[];
    var total = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final page =
          await client.call('audio.get', {
                'count': '500',
                'offset': '$offset',
              })
              as Map<String, dynamic>;
      total = page['count'] as int;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      songs.addAll(items);
      if (items.isEmpty) break;
    }
    final perId = <String, int>{};
    final nameOf = <String, String>{};
    for (final song in songs) {
      for (final artist in (song['main_artists'] as List? ?? const [])) {
        final id = '${(artist as Map)['id']}';
        perId[id] = (perId[id] ?? 0) + 1;
        nameOf[id] = '${artist['name']}';
      }
    }
    final ids =
        (perId.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .map((e) => e.key)
            .take(count)
            .toList();
    print('library ${songs.length} songs, asking for ${ids.length} artists');

    var searchHits = 0;
    var searchSquare = 0;
    var catalogHits = 0;
    var catalogSquare = 0;
    for (final (n, id) in ids.indexed) {
      print('artist #${n + 1}:');
      final (page, pageMs) = await ask('catalog.getAudioArtist', {
        'artist_id': id,
        'need_blocks': '0',
      });
      if (page is Map && page['artists'] is List) {
        final artist = (page['artists'] as List).first as Map;
        print(
          '  page $pageMs ms: photo ${sizes(artist['photo'])}, '
          'is_album_cover ${artist['is_album_cover']}, '
          'keys ${artist.keys.join(' ')}',
        );
      }

      // audio.searchArtists: the old artist search.
      final (found, foundMs) = await ask('audio.searchArtists', {
        'q': nameOf[id]!,
        'count': '10',
      });
      if (found is Map && found['items'] is List) {
        final items = (found['items'] as List).cast<Map>();
        final same = items.where((item) => '${item['id']}' == id).toList();
        print(
          '  audio.searchArtists $foundMs ms: ${items.length} items, '
          'same id ${same.length}, item keys '
          '${items.isEmpty ? '-' : items.first.keys.join(' ')}',
        );
        if (same.isNotEmpty) {
          searchHits++;
          final photo = same.first['photo'];
          print('    photo ${sizes(photo)}');
          if (photo is List &&
              photo.any(
                (size) => size is Map && size['width'] == size['height'],
              )) {
            searchSquare++;
          }
        }
      }

      // catalog.getAudioSearch: the app's search page, which lists artists.
      final (search, searchMs) = await ask('catalog.getAudioSearch', {
        'query': nameOf[id]!,
        'need_blocks': '1',
      });
      if (search is Map) {
        final artists = (search['artists'] as List? ?? const []).cast<Map>();
        final links = (search['links'] as List? ?? const []).cast<Map>();
        final same = artists.where((a) => '${a['id']}' == id).toList();
        print(
          '  catalog.getAudioSearch $searchMs ms: ${artists.length} artists '
          '(same id ${same.length}), ${links.length} links '
          '(artist links ${links.where((l) => (l['meta'] as Map?)?['content_type'] == 'artist').length})',
        );
        if (same.isNotEmpty) {
          catalogHits++;
          print('    artist photo ${sizes(same.first['photo'])}');
          final photo = same.first['photo'];
          if (photo is List &&
              photo.any(
                (size) => size is Map && size['width'] == size['height'],
              )) {
            catalogSquare++;
          }
        }
        for (final link in links.take(3)) {
          if ((link['meta'] as Map?)?['content_type'] != 'artist') continue;
          print('    artist link image ${sizes(link['image'])}');
        }
      }
    }
    // 25 searches in one execute: how long, how many find the same id.
    for (final batch in [5, 25]) {
      final part = (perId.keys.toList()..sort()).take(batch).toList();
      final code = StringBuffer('var r = [];');
      for (final id in part) {
        // A JSON string is a valid VKScript string literal.
        final q = jsonEncode(nameOf[id]!);
        code.write(
          'r.push(API.audio.searchArtists({"q": $q, "count": 5}).items);',
        );
      }
      code.write('return r;');
      final (reply, ms) = await ask('execute', {'code': '$code'});
      if (reply is List) {
        var same = 0;
        var square = 0;
        for (final (i, items) in reply.indexed) {
          if (items is! List) continue;
          final hit = items.cast<Map>().where((x) => '${x['id']}' == part[i]);
          if (hit.isEmpty) continue;
          same++;
          final photo = hit.first['photo'];
          if (photo is List && photo.isNotEmpty) square++;
        }
        print(
          'execute of $batch searches: $ms ms, ${reply.length} answers, '
          'same id $same, with a photo $square',
        );
      }
    }

    print(
      'summary: audio.searchArtists same id $searchHits of ${ids.length} '
      '($searchSquare square); catalog.getAudioSearch same id $catalogHits '
      '($catalogSquare square)',
    );
  } finally {
    client.close();
  }
}
