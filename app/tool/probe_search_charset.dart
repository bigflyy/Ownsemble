// Sends one Cyrillic audio.search --times times and counts how often VK
// answers for the words asked and how often with songs that have
// question-mark names instead (as if VK read the words as "????"), seen on
// 2026-11-12: one search of three came back that way. Read-only. Prints
// counts and the first song's name only: no link, key or id.
//
// Run from app/ (the words from a UTF-8 file: Cyrillic on the Windows
// command line turns into question marks):
//   dart run tool/probe_search_charset.dart --vk-session FILE \
//       --query-file FILE [--times 15] [--app]
// --app searches through the app's searchVkSongs, which asks again when an
// answer looks misread, and says when it did.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/same_song.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final query = File(valueOf('--query-file')!).readAsStringSync().trim();
  final times = int.parse(valueOf('--times') ?? '15');
  final throughApp = args.contains('--app');
  final words = songMatchText(query, '').split(' ');
  var right = 0, junk = 0, other = 0;
  for (var i = 0; i < times; i++) {
    final clock = Stopwatch()..start();
    final List<String> names;
    final Object? count;
    var again = '';
    if (throughApp) {
      final page = await searchVkSongs(client.call, query, count: 10);
      names = [for (final s in page.songs) '${s.artist} - ${s.title}'];
      count = page.total;
      if (page.askedAgain) again = ' (asked again)';
    } else {
      final reply = await client.call('audio.search', {
        'q': query,
        'count': '10',
        'offset': '0',
      }) as Map<String, dynamic>;
      final items = (reply['items'] as List).cast<Map<String, dynamic>>();
      names = [for (final a in items) '${a['artist']} - ${a['title']}'];
      count = reply['count'];
    }
    final items = names;
    final matching = names
        .where((n) => words.every(songMatchText(n, '').contains))
        .length;
    final broken = names.where(isQuestionMarkName).length;
    final verdict = matching >= items.length ~/ 2 && items.isNotEmpty
        ? 'right'
        : broken >= items.length ~/ 2 && items.isNotEmpty
        ? 'junk'
        : 'other';
    switch (verdict) {
      case 'right':
        right++;
      case 'junk':
        junk++;
      default:
        other++;
    }
    print(
      '${i + 1}. $verdict$again: ${items.length} songs (count $count), '
      '$matching with the words, $broken question-mark names, '
      '${clock.elapsedMilliseconds} ms; first: ${names.firstOrNull ?? '-'}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
  print('right $right, junk $junk, other $other of $times');
  client.close();
}
