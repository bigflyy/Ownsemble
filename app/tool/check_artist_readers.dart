// Runs the app's artist readers (lib/vk/vk_artists.dart, plan 09 C3) on a
// real account: the biggest artists' pages, Popular paged to the end, a
// similar artist's page opened by its address name, and photo batches for
// every artist id of the library.
//
// READ ONLY. Prints counts, yes/no flags, times and error codes only; never
// an id, link or name.
//
// Run from app/:
//   dart run tool/check_artist_readers.dart --vk-session FILE [--pages N]
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/vk/vk_artists.dart';
import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final pages = int.parse(valueOf('--pages') ?? '3');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    requestTimeout: const Duration(seconds: 60),
    silenceTimeout: const Duration(seconds: 30),
  );
  Future<T?> timed<T>(String what, Future<T> Function() run) async {
    final clock = Stopwatch()..start();
    try {
      final result = await run();
      print('  $what: ${clock.elapsedMilliseconds} ms');
      return result;
    } on VkException catch (error) {
      print(
        '  $what: VK error ${error.code ?? 'other'} '
        '(${clock.elapsedMilliseconds} ms)',
      );
      return null;
    }
  }

  try {
    await client.ensureToken();
    print('check_artist_readers ${DateTime.now().toIso8601String()}');
    final credits = <ArtistCredit>[];
    var total = 0;
    var songs = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final page = await client.call('audio.get', {
        'count': '500',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      total = page['count'] as int;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      songs += items.length;
      for (final item in items) {
        credits.addAll(vkArtistCredits(item));
      }
      if (items.isEmpty) break;
    }
    final perId = <String, int>{};
    final nameOf = <String, String>{};
    for (final credit in credits) {
      perId[credit.vkId] = (perId[credit.vkId] ?? 0) + 1;
      nameOf[credit.vkId] ??= credit.name;
    }
    final byCount = (perId.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)));
    print('library $songs songs, ${perId.length} artist ids');

    String? similarDomain;
    for (final (n, entry) in byCount.take(pages).indexed) {
      print('artist #${n + 1} (${entry.value} library songs):');
      final page = await timed(
        'page',
        () => fetchVkArtistPage(client.call, entry.key),
      );
      if (page == null) {
        print('  no page');
        continue;
      }
      print(
        '  same id ${page.id == entry.key}, domain ${page.domain != null}, '
        'banner ${page.bannerUrl != null}, popular ${page.popular.songs.length}'
        ' (VK says ${page.popularTotal}, more ${page.popular.hasMore}), '
        'releases ${page.releases.length} '
        '(singles ${page.releases.where((r) => r.single).length}, '
        'all by this id ${page.releases.every((r) => r.artists.any((a) => a.vkId == page.id))}), '
        'similar ${page.similar.length} '
        '(with domain ${page.similar.where((a) => a.domain != null).length}, '
        'photo ${page.similar.where((a) => a.photoUrl != null).length})',
      );
      similarDomain ??= page.similar
          .map((a) => a.domain)
          .whereType<String>()
          .firstOrNull;
      var block = page.popular;
      var calls = 0;
      final clock = Stopwatch()..start();
      while (block.hasMore && calls < 20) {
        final next = await timed(
          'popular page ${calls + 1}',
          () => fetchVkBlockMore(client.call, block),
        );
        calls++;
        if (next == null) break;
        block = next;
      }
      print(
        '  popular paged: ${block.songs.length} songs in $calls calls, '
        '${clock.elapsedMilliseconds} ms, ended ${!block.hasMore}, '
        'repeats ${block.songs.length - {for (final s in block.songs) s.key}.length}',
      );
      // Releases past VK's first 10 (user 2026-11-21): the reply's shape
      // (key names and counts only), then the app's reader.
      if (page.hasMoreReleases) {
        final raw = await timed(
          'releases raw page',
          () => client.call('catalog.getBlockItems', {
            'block_id': page.releasesBlockId!,
            'start_from': page.releasesNextFrom!,
          }),
        );
        if (raw is Map<String, dynamic>) {
          final lists = (raw['playlists'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          print(
            '  raw keys ${raw.keys.toList()}, block keys '
            '${(raw['block'] as Map?)?.keys.toList()}, playlists '
            '${lists.length}, albums '
            '${lists.where((l) => l['type'] == 'album').length}, with '
            'main_artists ${lists.where((l) => l['main_artists'] is List).length}',
          );
        }
      }
      final all = await timed(
        'releases paged',
        () => fetchVkReleasesMore(client.call, page),
      );
      if (all != null) {
        print(
          '  releases: first ${page.releases.length}, more '
          '${page.hasMoreReleases}, after paging ${all.releases.length}, '
          'repeats ${all.releases.length - {for (final r in all.releases) r.key}.length}, '
          'all by this id ${all.releases.every((r) => r.artists.any((a) => a.vkId == page.id))}',
        );
      }
    }

    if (similarDomain != null) {
      print('a similar artist by its address name:');
      final page = await timed(
        'page',
        () => fetchVkArtistPage(client.call, similarDomain!),
      );
      print(
        '  opened ${page != null}, its domain matches '
        '${page?.domain == similarDomain}, popular '
        '${page?.popular.songs.length}',
      );
    }

    print('photos of all ${byCount.length} artist ids, 25 a request:');
    var found = 0;
    var missing = 0;
    var failed = 0;
    final clock = Stopwatch()..start();
    final ids = [for (final entry in byCount) entry.key];
    for (var start = 0; start < ids.length; start += artistPhotoBatch) {
      final part = [
        for (final id in ids.skip(start).take(artistPhotoBatch))
          (id: id, name: nameOf[id]!),
      ];
      final photos = await timed(
        'batch ${start ~/ artistPhotoBatch + 1} (${part.length})',
        () => fetchVkArtistPhotos(client.call, part),
      );
      if (photos == null) {
        failed += part.length;
        continue;
      }
      found += photos.values.whereType<VkArtistPhotoFound>().length;
      missing += photos.values.whereType<VkArtistPhotoMissing>().length;
      failed += part.length - photos.length;
    }
    print(
      '  found $found, missing $missing, failed $failed, '
      '${clock.elapsedMilliseconds} ms',
    );
  } finally {
    client.close();
  }
}
