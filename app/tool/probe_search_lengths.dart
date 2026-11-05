// Searches VK for a song and prints, for each result, the length VK lists
// and the length of the file VK sends (estimated from 16 KB and the size), to
// see which recordings exist. Read-only, prints no link or key.
//
// Run from app/:
//   dart run tool/probe_search_lengths.dart --vk-session FILE --q TEXT

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

import 'probe_length_sample.dart' show fetchRange, estimate;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final vk = VkClient(SessionCookie.loadAll(File(valueOf('--vk-session')!)));
  final reply = await vk.call('audio.search', {
    'q': valueOf('--q')!,
    'count': '40',
  });
  final items = (reply as Map<String, dynamic>)['items'] as List;
  final http = HttpClient();
  for (final item in items.cast<Map<String, dynamic>>()) {
    final url = item['url'] as String? ?? '';
    var file = 'no link';
    if (url.isNotEmpty) {
      try {
        final link = Uri.parse(url);
        var (head, total) = await fetchRange(http, link, 0, 16384);
        var start = 0;
        if (head.length > 10 &&
            head[0] == 0x49 &&
            head[1] == 0x44 &&
            head[2] == 0x33) {
          start =
              10 +
              ((head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9]);
          (head, _) = await fetchRange(http, link, start, 16384);
        }
        final seconds = total == null ? null : estimate(head, start, total);
        file = seconds == null
            ? 'unknown'
            : '${seconds.toStringAsFixed(1)} s, $total bytes';
      } on Object catch (error) {
        file = 'error ${error.runtimeType}';
      }
    }
    final album = item['album'] is Map ? (item['album'] as Map)['title'] : null;
    print(
      '${item['artist']} - ${item['title']} | listed ${item['duration']} s | '
      'file $file | official ${item['is_official'] ?? false} | '
      'track_id ${item['track_id']} | album ${album ?? '-'}',
    );
  }
  http.close(force: true);
}
