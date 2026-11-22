// Read-only collection for plan 10 F2 (automatic lyrics timing): for the
// TEST account's songs, saves every timed lyrics candidate (VK, LRCLIB,
// NetEase) and the song's MP3 into a local folder, so a timing analysis can
// run offline against the same audio again and again.
//
//   dart run tool/probe_lyrics_timing.dart --vk-session FILE --out DIR
//       [--count 200] [--only 3,11] [--no-audio]
//   dart run tool/probe_lyrics_timing.dart --vk-session FILE --out DIR
//       --live LIVE_DIR [--count 200]
//
// --live: for every song already saved in DIR, searches VK for a live or
// acoustic upload by the same artist (the case whose lines come early) and
// saves it in LIVE_DIR the same way, with the studio song's lyrics, plus
// LRCLIB's lyrics for the live upload's own names and length when LRCLIB
// has them timed (source "truth").
//
// Writes DIR/songs/<index>.json ({index, seconds, sources: {id: lines}},
// lines as the library stores them) and DIR/audio/<index>.mp3. The folder
// must stay under .local/ (out of git): it holds words and audio. Printed
// per song: its index, which sources are timed, line counts and the file
// size. No song name, lyric line, link, key or token is printed.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_match.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_lyrics.dart';

/// Fetches [url] whole into [target]; returns the size. (The app's own
/// fetchToFile lives beside Flutter code, which a plain Dart run cannot load.)
Future<int> fetchToFile(Uri url, File target) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final part = File('${target.path}.part');
  try {
    final response = await (await http.getUrl(url)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('status ${response.statusCode}');
    }
    final sink = part.openWrite();
    var bytes = 0;
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      sink.add(chunk);
      bytes += chunk.length;
    }
    await sink.close();
    if (response.contentLength >= 0 && bytes != response.contentLength) {
      throw const HttpException('download ended early');
    }
    part.renameSync(target.path);
    return bytes;
  } catch (_) {
    if (part.existsSync()) part.deleteSync();
    rethrow;
  } finally {
    http.close(force: true);
  }
}

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final count = int.parse(valueOf('--count') ?? '200');
  final out = Directory(valueOf('--out')!);
  final withAudio = !args.contains('--no-audio');
  final only = {
    for (final i in (valueOf('--only') ?? '').split(','))
      if (i.trim().isNotEmpty) int.parse(i.trim()),
  };
  // QQ is left out: its search answers HTTP 500 for now (open check B27).
  final sources = outsideLyricsSources(httpGetJson())
      .where((source) => source.id != 'qq')
      .toList();
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final reply = await client.call('audio.get', {
    'count': '$count',
  }) as Map<String, dynamic>;
  final items = (reply['items'] as List).cast<Map<String, dynamic>>();
  if (valueOf('--live') case final live?) {
    await collectLive(client, items, out, Directory(live), sources.first);
    exit(0);
  }
  Directory('${out.path}/songs').createSync(recursive: true);
  Directory('${out.path}/audio').createSync(recursive: true);
  print('${items.length} songs');

  var timedSongs = 0;
  for (var i = 0; i < items.length; i++) {
    if (only.isNotEmpty && !only.contains(i)) continue;
    final item = items[i];
    final sourceKey = '${item['owner_id']}_${item['id']}';
    final seconds = (item['duration'] as num?)?.toInt() ?? 0;
    final timed = <String, Lyrics>{};
    final line = StringBuffer('#$i ${seconds}s');

    if (item['has_lyrics'] == true || item['has_lyrics'] == 1) {
      await pause(700);
      try {
        final answer = await fetchVkLyrics(client.call, sourceKey: sourceKey);
        if (answer case VkLyricsFound(:final lyrics) when lyrics.timed) {
          timed['vk'] = lyrics;
        }
      } on VkException catch (error) {
        line.write(' vk error ${error.code}');
      }
    }
    final song = SongNames(
      artist: '${item['artist'] ?? ''}',
      title: '${item['title'] ?? ''}',
      album: (item['album'] as Map?)?['title'] as String?,
      seconds: seconds,
    );
    for (final source in sources) {
      try {
        final found = await source.find(song);
        if (found != null && found.lyrics.timed) {
          timed[source.id] = found.lyrics;
        }
      } on LyricsSourceException catch (error) {
        line.write(' ${source.id} failed ${error.message}');
      }
      await pause(source.id == 'lrclib' ? 1400 : 700);
    }
    for (final entry in timed.entries) {
      line.write(' ${entry.key} ${entry.value.lines.length}');
    }
    if (timed.isEmpty) {
      line.write(' no timed lyrics');
      print(line);
      continue;
    }
    timedSongs++;
    File('${out.path}/songs/$i.json').writeAsStringSync(
      jsonEncode({
        'index': i,
        'seconds': seconds,
        'sources': {
          for (final entry in timed.entries)
            entry.key: jsonDecode(entry.value.linesToJson()),
        },
      }),
    );

    final mp3 = File('${out.path}/audio/$i.mp3');
    if (withAudio && !mp3.existsSync()) {
      try {
        final stream = await client.resolveStream(
          sourceKey,
          item['access_key'] as String?,
        );
        final link = stream.link;
        if (link == null) {
          line.write(' | no audio link');
        } else if (link.path.toLowerCase().endsWith('.m3u8')) {
          line.write(' | audio is a playlist, skipped');
        } else {
          final bytes = await fetchToFile(link, mp3);
          line.write(' | audio ${(bytes / 1048576).toStringAsFixed(1)} MB');
        }
      } on Object catch (error) {
        // The error text may hold the link: name only its kind.
        line.write(' | audio failed ${error.runtimeType}');
      }
      await pause(500);
    }
    print(line);
  }
  print('songs with timed lyrics: $timedSongs');
  exit(0);
}

/// Words in a title that mark a live or acoustic recording.
final liveMarks = RegExp(
  r'live|acoustic|unplugged|session|концерт|акуст|живой|live at',
  caseSensitive: false,
);

/// The --live collection (see the top of the file).
Future<void> collectLive(
  VkClient client,
  List<Map<String, dynamic>> items,
  Directory studio,
  Directory out,
  OutsideLyricsSource lrclib,
) async {
  Directory('${out.path}/songs').createSync(recursive: true);
  Directory('${out.path}/audio').createSync(recursive: true);
  var found = 0;
  for (var i = 0; i < items.length; i++) {
    final saved = File('${studio.path}/songs/$i.json');
    if (!saved.existsSync()) continue;
    final item = items[i];
    final artist = '${item['artist'] ?? ''}';
    final title = '${item['title'] ?? ''}';
    if (liveMarks.hasMatch(title)) continue;
    await pause(1000);
    final List<Map<String, dynamic>> results;
    try {
      final reply = await client.call('audio.search', {
        'q': '$artist $title live',
        'count': '30',
      }) as Map<String, dynamic>;
      results = (reply['items'] as List).cast<Map<String, dynamic>>();
    } on VkException catch (error) {
      print('#$i search error ${error.code}');
      continue;
    }
    final studioSeconds = (item['duration'] as num?)?.toInt() ?? 0;
    final match = results.where((result) {
      final otherTitle = '${result['title'] ?? ''}';
      final otherSeconds = (result['duration'] as num?)?.toInt() ?? 0;
      return foldName('${result['artist'] ?? ''}') == foldName(artist) &&
          liveMarks.hasMatch(otherTitle) &&
          foldName(otherTitle).contains(foldName(title)) &&
          (otherSeconds - studioSeconds).abs() >= 3;
    }).firstOrNull;
    if (match == null) {
      print('#$i no live upload');
      continue;
    }
    final seconds = (match['duration'] as num?)?.toInt() ?? 0;
    final json = jsonDecode(saved.readAsStringSync()) as Map<String, dynamic>;
    final sources = Map<String, dynamic>.of(
      json['sources'] as Map<String, dynamic>,
    );
    final line = StringBuffer(
      '#$i live ${seconds}s (studio ${studioSeconds}s)',
    );
    try {
      final truth = await lrclib.find(
        SongNames(
          artist: '${match['artist'] ?? ''}',
          title: '${match['title'] ?? ''}',
          seconds: seconds,
        ),
      );
      if (truth != null && truth.lyrics.timed) {
        sources['truth'] = jsonDecode(truth.lyrics.linesToJson());
        line.write(' truth ${truth.lyrics.lines.length} lines');
      }
    } on LyricsSourceException catch (error) {
      line.write(' lrclib failed ${error.message}');
    }
    await pause(1400);
    final mp3 = File('${out.path}/audio/$i.mp3');
    try {
      final stream = await client.resolveStream(
        '${match['owner_id']}_${match['id']}',
        match['access_key'] as String?,
      );
      final link = stream.link;
      if (link == null || link.path.toLowerCase().endsWith('.m3u8')) {
        line.write(' | no usable audio link');
        print(line);
        continue;
      }
      final bytes = await fetchToFile(link, mp3);
      line.write(' | audio ${(bytes / 1048576).toStringAsFixed(1)} MB');
    } on Object catch (error) {
      line.write(' | audio failed ${error.runtimeType}');
      print(line);
      continue;
    }
    File('${out.path}/songs/$i.json').writeAsStringSync(
      jsonEncode({'index': i, 'seconds': seconds, 'sources': sources}),
    );
    found++;
    print(line);
  }
  print('live uploads saved: $found');
}
