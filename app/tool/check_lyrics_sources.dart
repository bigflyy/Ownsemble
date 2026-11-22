// Read-only check for plan 10 E1: the app's own outside lyrics sources
// (lib/lyrics/lyrics_sources.dart: LRCLIB, NetEase, QQ Music, with the
// app's LRC reading and name matching) over the TEST account's songs, to
// compare with the A4 probe (tool/probe_lyrics_outside.dart, session 37).
//
//   dart run tool/check_lyrics_sources.dart --vk-session FILE [--count 200]
//       [--sources lrclib,netease,qq] [--only 3,11]
//
// Printed per song: its index, VK's kind (from has_lyrics and
// audio.getLyrics) and each source's answer (timed or plain, exact or loose
// names, length difference, ms); then totals and the walk's pick as the
// app makes it (VK timed > outside timed > VK plain > outside plain, LRCLIB
// first, NetEase and QQ only when nothing timed yet). No song name, lyric
// line, link, key or token is printed.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_lyrics.dart';

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final count = int.parse(valueOf('--count') ?? '200');
  final wanted = (valueOf('--sources') ?? 'lrclib,netease,qq').split(',');
  final only = {
    for (final i in (valueOf('--only') ?? '').split(','))
      if (i.trim().isNotEmpty) int.parse(i.trim()),
  };
  final sources = outsideLyricsSources(httpGetJson())
      .where((source) => wanted.contains(source.id))
      .toList();
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final reply = await client.call('audio.get', {
    'count': '$count',
  }) as Map<String, dynamic>;
  final items = (reply['items'] as List).cast<Map<String, dynamic>>();
  print('${items.length} songs; sources: ${wanted.join(', ')}');

  final picks = <String, int>{};
  final kinds = <String, Map<String, int>>{};
  final gaps = <int>[];
  for (var i = 0; i < items.length; i++) {
    if (only.isNotEmpty && !only.contains(i)) continue;
    final item = items[i];
    final song = SongNames(
      artist: '${item['artist'] ?? ''}',
      title: '${item['title'] ?? ''}',
      album: (item['album'] as Map?)?['title'] as String?,
      seconds: (item['duration'] as num?)?.toInt() ?? 0,
    );
    var vk = 'none';
    final flagged = item['has_lyrics'] == true || item['has_lyrics'] == 1;
    if (flagged) {
      await pause(700);
      try {
        final answer = await fetchVkLyrics(
          client.call,
          sourceKey: '${item['owner_id']}_${item['id']}',
        );
        vk = switch (answer) {
          VkLyricsFound(:final lyrics) => lyrics.timed ? 'timed' : 'plain',
          VkLyricsNone() => 'none',
        };
      } on VkException catch (error) {
        vk = 'error ${error.code}';
      }
    }
    final line = StringBuffer('#$i vk $vk');
    final answers = <String, LyricsCandidate?>{};
    for (final source in sources) {
      final clock = Stopwatch()..start();
      String verdict;
      try {
        final found = await source.find(song);
        answers[source.id] = found;
        verdict = found == null
            ? 'none'
            : '${found.lyrics.timed ? 'timed' : 'plain'} '
                  '${found.names.name} +-${found.lengthDiff}s '
                  '${found.lyrics.lines.length} lines';
      } on LyricsSourceException catch (error) {
        verdict = 'failed ${error.message}';
      }
      final kind = verdict.split(' ').first;
      (kinds[source.id] ??= {})[kind] = (kinds[source.id]![kind] ?? 0) + 1;
      line.write(' | ${source.id}: $verdict (${clock.elapsedMilliseconds}ms)');
      await pause(source.id == 'lrclib' ? 1400 : 700);
    }
    // The app's pick: VK timed; else LRCLIB timed; else NetEase/QQ timed;
    // else VK plain; else outside plain.
    String pick;
    LyricsCandidate? timedOutside() {
      for (final id in ['lrclib', 'netease', 'qq']) {
        final found = answers[id];
        if (found != null && found.lyrics.timed) return found;
      }
      return null;
    }

    LyricsCandidate? plainOutside() {
      for (final id in ['lrclib', 'netease', 'qq']) {
        if (answers[id] != null) return answers[id];
      }
      return null;
    }

    if (vk == 'timed') {
      pick = 'vk timed';
    } else if (timedOutside() case final found?) {
      pick = '${found.source} timed';
    } else if (vk == 'plain') {
      pick = 'vk plain';
    } else if (plainOutside() case final found?) {
      pick = '${found.source} plain';
    } else {
      pick = 'none';
    }
    if (!pick.endsWith('timed')) gaps.add(i);
    picks[pick] = (picks[pick] ?? 0) + 1;
    line.write(' => $pick');
    print(line);
  }
  print('');
  for (final source in sources) {
    print('${source.id}: ${kinds[source.id]}');
  }
  print('picks: $picks');
  final timed = picks.entries
      .where((entry) => entry.key.endsWith('timed'))
      .fold(0, (sum, entry) => sum + entry.value);
  print('timed $timed of ${picks.values.fold(0, (a, b) => a + b)}');
  print('no timed lyrics (indexes): ${gaps.join(' ')}');
  exit(0);
}
