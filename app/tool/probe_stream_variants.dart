// Lists the stream variants VK names for one song (audio.getById's
// audio_streams) and the length each one plays, to find whether one of them is
// the recording the library lists when the main link is another. Reads files
// into memory only, never saves or plays them. Prints field NAMES of each
// variant and lengths, never a value that could be a link.
//
// Run from app/:
//   dart run tool/probe_stream_variants.dart --data-dir DIR --vk-session FILE
//     --track-id N

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'probe_own_file.dart' show mp3Seconds;

Future<Uint8List> fetchAll(HttpClient http, Uri link) async {
  final request = await http.getUrl(link);
  final response = await request.close();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Sum of #EXTINF durations of an HLS media playlist, following one level
/// of variant playlists.
Future<String> hlsSeconds(HttpClient http, Uri link) async {
  final text = utf8.decode(await fetchAll(http, link), allowMalformed: true);
  final lines = const LineSplitter().convert(text);
  if (!text.startsWith('#EXTM3U')) {
    return 'not a playlist (${text.length} chars)';
  }
  var seconds = 0.0;
  var segments = 0;
  for (final line in lines) {
    if (line.startsWith('#EXTINF:')) {
      segments++;
      seconds += double.tryParse(line.substring(8).split(',').first) ?? 0;
    }
  }
  if (segments > 0) {
    return '${seconds.toStringAsFixed(1)} s in $segments segments';
  }
  final variant = lines.firstWhere(
    (l) => l.isNotEmpty && !l.startsWith('#'),
    orElse: () => '',
  );
  if (variant.isEmpty) return 'empty playlist';
  return 'variant -> ${await hlsSeconds(http, link.resolve(variant))}';
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final db = sqlite3.open(
    p.join(valueOf('--data-dir')!, 'library.db'),
    mode: OpenMode.readOnly,
  );
  final row = db.select(
    'SELECT artist, title, duration_sec, source_key, access_key FROM tracks WHERE id = ?',
    [int.parse(valueOf('--track-id')!)],
  ).first;
  db.close();
  print(
    'song: ${row['artist']} - ${row['title']}, listed ${row['duration_sec']} s',
  );
  final vk = VkClient(SessionCookie.loadAll(File(valueOf('--vk-session')!)));
  final key = row['source_key'] as String;
  final access = row['access_key'] as String?;
  final reply = await vk.call('audio.getById', {
    'audios': access == null ? key : '${key}_$access',
  }) as List;
  final audio = reply.first as Map<String, dynamic>;
  print('reply fields: ${audio.keys.toList()..sort()}');
  final streams = audio['audio_streams'];
  if (streams is! List) {
    print('audio_streams: ${streams.runtimeType}');
    return;
  }
  final http = HttpClient();
  for (final stream in streams.cast<Map<String, dynamic>>()) {
    final type = stream['type'];
    final urlText =
        (args.contains('--fallback') ? stream['fallback_url'] : stream['url'])
            as String?;
    final sameAsFallback = stream['url'] == stream['fallback_url'];
    var length = 'no url';
    if (urlText != null && urlText.isNotEmpty) {
      final link = Uri.parse(urlText);
      try {
        if (link.path.toLowerCase().endsWith('.m3u8') ||
            '$type'.startsWith('hls')) {
          length = await hlsSeconds(http, link);
        } else {
          final bytes = await fetchAll(http, link);
          final seconds = mp3Seconds(bytes);
          length =
              '${bytes.length} bytes, '
              '${seconds == null ? 'not MP3 frames' : '${seconds.toStringAsFixed(1)} s as MP3'}';
        }
      } on Object catch (error) {
        length = 'error ${error.runtimeType}';
      }
    }
    print('variant type=$type url==fallback $sameAsFallback: $length');
  }
  http.close(force: true);
}
