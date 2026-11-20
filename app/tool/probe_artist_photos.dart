// The cheapest way to get the photos of many artists (plan 09, B1): one
// artist page without blocks, VK's `execute` batching several pages in one
// request, and a few method names that might list artists by id.
//
// READ ONLY. Prints counts, yes/no flags, times and error codes only; never
// an id, link or name.
//
// Run from app/:
//   dart run tool/probe_artist_photos.dart --vk-session FILE [--artists N]
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final count = int.parse(valueOf('--artists') ?? '25');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
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

  try {
    await client.ensureToken();
    print('probe_artist_photos ${DateTime.now().toIso8601String()}');
    // Artist ids of the library, most songs first.
    final songs = <Map<String, dynamic>>[];
    var total = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final page = await client.call('audio.get', {
        'count': '500',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      total = page['count'] as int;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      songs.addAll(items);
      if (items.isEmpty) break;
    }
    final perId = <String, int>{};
    for (final song in songs) {
      for (final artist in (song['main_artists'] as List? ?? const [])) {
        final id = '${(artist as Map)['id']}';
        perId[id] = (perId[id] ?? 0) + 1;
      }
    }
    final ids =
        (perId.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .map((e) => e.key)
            .take(count)
            .toList();
    print(
      'library ${songs.length} songs, ${perId.length} artist ids, '
      'asking for ${ids.length}',
    );

    bool hasPhoto(Object? reply) =>
        reply is Map &&
        ((reply['artists'] as List?)?.firstOrNull as Map?)?['photo'] is List;

    // 1. One page with and without blocks.
    final (withBlocks, withMs) = await ask('catalog.getAudioArtist', {
      'artist_id': ids.first,
      'need_blocks': '1',
    });
    final (noBlocks, noMs) = await ask('catalog.getAudioArtist', {
      'artist_id': ids.first,
      'need_blocks': '0',
    });
    print(
      'page with blocks $withMs ms (${jsonEncode(withBlocks).length} '
      'bytes, photo ${hasPhoto(withBlocks)}); without $noMs ms '
      '(${jsonEncode(noBlocks).length} bytes, photo ${hasPhoto(noBlocks)})',
    );

    // 2. execute: several pages in one request (VK allows 25 calls).
    for (final batch in [5, 25]) {
      final part = ids.take(batch).toList();
      final code = StringBuffer('var r = [];');
      for (final id in part) {
        code.write(
          'var a = API.catalog.getAudioArtist({"artist_id": "$id", '
          '"need_blocks": 1}); r.push(a.artists[0].photo);',
        );
      }
      code.write('return r;');
      final (reply, ms) = await ask('execute', {'code': '$code'});
      if (reply is List) {
        final withPhoto = reply.where((p) => p is List && p.isNotEmpty).length;
        print(
          'execute of $batch pages: $ms ms, ${reply.length} answers, '
          '$withPhoto with a photo',
        );
      }
    }

    print(
      'no-blocks reply keys: ${noBlocks is Map ? noBlocks.keys.join(' ') : noBlocks.runtimeType}'
      '${noBlocks is Map && noBlocks['artists'] is List ? ', artists[0] keys ${((noBlocks['artists'] as List).first as Map).keys.join(' ')}' : ''}',
    );

    // 3. Sequential pages without blocks, for comparison.
    final clock = Stopwatch()..start();
    var photos = 0;
    for (final id in ids.take(5)) {
      final (reply, _) = await ask('catalog.getAudioArtist', {
        'artist_id': id,
        'need_blocks': '0',
      });
      if (hasPhoto(reply)) photos++;
    }
    print(
      '5 pages one by one: ${clock.elapsedMilliseconds} ms, '
      '$photos with a photo',
    );

    // 4. Method names that might list artists by id.
    for (final method in [
      'audio.getArtists',
      'audio.getArtistsById',
      'catalog.getArtists',
      'audio.getArtist',
    ]) {
      final (reply, ms) = await ask(method, {
        'artist_ids': ids.take(3).join(','),
        'artist_id': ids.first,
      });
      if (reply != null) {
        print(
          '$method $ms ms: answered '
          '${reply is Map ? 'map ${reply.keys.join(' ')}' : reply.runtimeType}',
        );
      }
    }
  } finally {
    client.close();
  }
}
