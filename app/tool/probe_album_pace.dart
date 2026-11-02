// Asks audio.getPlaylistById many times at the pace a sync would use, to see
// whether VK limits it. The test library has few "unnamed" albums, so the same
// albums are asked again and again; a real library may need hundreds of calls.
//
// Prints only counts, times and VK's error codes. Never a link, a key or any
// other part of a raw reply: VK's replies hold signed stream links.
//
// Run from app/:
//   dart run tool/probe_album_pace.dart --vk-session FILE [--calls N] [--gap-ms N]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final session = option('--vk-session');
  if (session == null) {
    stderr.writeln('--vk-session is required');
    exit(64);
  }
  final calls = int.parse(option('--calls') ?? '300');
  final gapMs = int.parse(option('--gap-ms') ?? '150');

  final vk = VkClient(SessionCookie.loadAll(File(session)));
  await vk.ensureToken();
  final page = await vk.call('audio.get', {
    'owner_id': '${vk.userId}',
    'count': '200',
  }) as Map<String, dynamic>;

  // Each album once, whichever way VK names it.
  final albums = <String, Map<String, dynamic>>{};
  for (final item in (page['items'] as List).cast<Map<String, dynamic>>()) {
    final album = item['album'];
    if (album is Map<String, dynamic> && album['id'] != null) {
      albums['${album['owner_id']}_${album['id']}'] = album;
    }
  }
  final list = albums.values.toList();
  print('${list.length} albums, $calls calls, $gapMs ms apart');

  var good = 0;
  var slowest = 0;
  final failures = <String, int>{};
  final all = Stopwatch()..start();
  for (var n = 0; n < calls; n++) {
    final album = list[n % list.length];
    final clock = Stopwatch()..start();
    try {
      await vk.call('audio.getPlaylistById', {
        'owner_id': '${album['owner_id']}',
        'playlist_id': '${album['id']}',
        if (album['access_key'] != null)
          'access_key': album['access_key'] as String,
      });
      good++;
    } on VkException catch (error) {
      // Only the part up to the code: a message may carry a link.
      final code = RegExp(r'error (\d+)').firstMatch(error.message)?.group(1);
      final name = code == null ? 'no code' : 'error $code';
      failures[name] = (failures[name] ?? 0) + 1;
    }
    if (clock.elapsedMilliseconds > slowest) {
      slowest = clock.elapsedMilliseconds;
    }
    await Future<void>.delayed(Duration(milliseconds: gapMs));
  }
  print(
    '$good of $calls answered in ${all.elapsed.inSeconds} s, '
    'slowest $slowest ms, failures: $failures',
  );
  vk.close();
}
