// Asks VK for a fresh link to every song of a library and looks at what the
// audio server sends for it, the way the proxy asks: MP3 or an HLS playlist.
//
// VK sometimes answers a song with an HLS playlist (#EXTM3U) instead of the
// MP3. This shows how often, whether the link itself says so, and whether a
// new link brings the MP3. The library is opened read-only.
//
// Prints titles, counts, reply headers and the playlist's structure. Never
// prints a link, a token or a playlist's addresses: every URI in a playlist
// line is replaced.
//
// Run from app/:
//   dart run tool/probe_stream_kinds.dart --data-dir DIR --vk-session FILE
//     [--rounds N] [--title TEXT] [--again N]
//
// --rounds N    passes over the library (default 1)
// --title TEXT  only songs whose title or artist contains TEXT
// --again N     for a song that gave a playlist, ask for N new links

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// What the audio server sent for one link.
class Reply {
  Reply(this.status, this.type, this.length, this.head, this.body);

  final int status;
  final String? type;
  final int length;

  /// The first 8 bytes, as hex.
  final String head;

  /// The whole reply when it is short enough to be a playlist.
  final List<int>? body;

  bool get isPlaylist => head.startsWith('234558544d3355');
}

/// True when the link's path ends in .m3u8. Says nothing else about the link.
bool linkSaysPlaylist(Uri link) => link.path.toLowerCase().endsWith('.m3u8');

/// Requests the first bytes of [link] with mpv's whole-file Range header.
Future<Reply> fetchStart(HttpClient http, Uri link) async {
  final request = await http.getUrl(link);
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
  final response = await request.close();
  final head = <int>[];
  final length = response.contentLength;
  // A short reply is read whole; of a song only the start is needed.
  final readAll = length >= 0 && length < 64 * 1024;
  await for (final chunk in response) {
    head.addAll(chunk);
    if (!readAll && head.length >= 8) break;
  }
  return Reply(
    response.statusCode,
    response.headers.value(HttpHeaders.contentTypeHeader),
    length,
    head.take(8).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    readAll ? head : null,
  );
}

/// The playlist's lines with every address taken out, repeats folded.
List<String> describePlaylist(List<int> body) {
  final text = utf8.decode(body, allowMalformed: true);
  final tags = <String, int>{};
  var segments = 0;
  var seconds = 0.0;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('#EXTINF:')) {
      segments++;
      seconds += double.tryParse(line.substring(8).split(',').first) ?? 0;
      continue;
    }
    if (!line.startsWith('#')) continue;
    final safe = line.replaceAll(RegExp(r'URI="[^"]*"'), 'URI="<removed>"');
    tags[safe] = (tags[safe] ?? 0) + 1;
  }
  return [
    '$segments segments, ${seconds.toStringAsFixed(1)} s',
    for (final tag in tags.entries) '${tag.value} x ${tag.key}',
  ];
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  if (dataDir == null || sessionPath == null) {
    stderr.writeln('--data-dir and --vk-session are required');
    exit(64);
  }
  final rounds = int.parse(valueOf('--rounds') ?? '1');
  final again = int.parse(valueOf('--again') ?? '3');
  final filter = valueOf('--title')?.toLowerCase();

  final db = sqlite3.open(
    p.join(dataDir, 'library.db'),
    mode: OpenMode.readOnly,
  );
  final songs = db
      .select(
        'SELECT artist, title, source_key, access_key FROM tracks '
        'WHERE gone_at_ms IS NULL ORDER BY added_at DESC',
      )
      .where(
        (row) =>
            filter == null ||
            '${row['artist']} ${row['title']}'.toLowerCase().contains(filter),
      )
      .toList();
  db.close();
  print('${songs.length} songs, $rounds round(s)');

  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  await vk.ensureToken();

  final kinds = <String, int>{};
  final playlistSongs = <String, int>{};
  var noLink = 0;
  var linksSaidPlaylist = 0;
  var skipped = 0;

  for (var round = 1; round <= rounds; round++) {
    for (final song in songs) {
      final name = '${song['artist']} - ${song['title']}';
      final key = song['source_key'] as String;
      final accessKey = song['access_key'] as String?;
      try {
        final stream = await vk.resolveStream(key, accessKey);
        final link = stream.link;
        if (link == null) {
          noLink++;
          continue;
        }
        if (stream.playlistLinks > 0) {
          skipped++;
          print('skipped ${stream.playlistLinks} HLS link(s): $name');
        }
        final saysPlaylist = linkSaysPlaylist(link);
        if (saysPlaylist) linksSaidPlaylist++;
        final reply = await fetchStart(http, link);
        final kind =
            '${reply.status} ${reply.type} '
            '${reply.isPlaylist ? 'PLAYLIST' : 'audio'} '
            'link${saysPlaylist ? ' .m3u8' : ' other'}';
        kinds[kind] = (kinds[kind] ?? 0) + 1;
        if (!reply.isPlaylist) continue;

        playlistSongs[name] = (playlistSongs[name] ?? 0) + 1;
        print(
          'PLAYLIST round $round: $name, '
          'link path ends .m3u8: $saysPlaylist, ${reply.length} bytes, '
          'has release: ${stream.releaseKey != null}',
        );
        final body = reply.body;
        if (body != null) {
          describePlaylist(body).forEach((line) => print('    $line'));
        }
        for (var ask = 1; ask <= again; ask++) {
          final fresh = await vk.resolveStream(key, accessKey);
          if (fresh.link == null) {
            print('    new link $ask: none');
            continue;
          }
          final same = fresh.link == link;
          final next = await fetchStart(http, fresh.link!);
          print(
            '    new link $ask: same as before: $same, '
            'status ${next.status}, ${next.type}, ${next.length} bytes, '
            '${next.isPlaylist ? 'PLAYLIST' : 'audio'}, '
            'path ends .m3u8: ${linkSaysPlaylist(fresh.link!)}',
          );
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        final release = await vk.releaseLink(stream);
        if (release != null) {
          final next = await fetchStart(http, release);
          print(
            '    release link: status ${next.status}, ${next.type}, '
            '${next.length} bytes, '
            '${next.isPlaylist ? 'PLAYLIST' : 'audio'}',
          );
        }
      } catch (error) {
        // The error's type only: messages may carry the server's address.
        final kind = 'error ${error.runtimeType}';
        kinds[kind] = (kinds[kind] ?? 0) + 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  print('--- replies');
  kinds.forEach((kind, count) => print('$count x $kind'));
  print(
    'no link: $noLink, links ending .m3u8: $linksSaidPlaylist, '
    'requests where resolveStream skipped one: $skipped',
  );
  print('--- songs that gave a playlist');
  playlistSongs.forEach((name, count) => print('$count x $name'));
  http.close(force: true);
  vk.close();
}
