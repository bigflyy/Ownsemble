// Which of VK's first search results for --query the account has, and by
// which rule (plan 06, C4e): the same key, the same VK track id (with the
// lengths of both, since VK reuses ids for other songs), or the same name
// with a length within 2 s; and which have only the name (another version).
// Read-only. Prints names, lengths and yes/no only: no link, key or id.
//
// Run from app/:
//   dart run tool/probe_found_owned.dart --vk-session FILE --query "..."
//   (or --query-file FILE with the words in UTF-8; default "дайте танк")

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/same_song.dart';
import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  // Cyrillic on the Windows command line turns into question marks: the
  // words can come from a UTF-8 file instead.
  final queryFile = valueOf('--query-file');
  final query = queryFile != null
      ? File(queryFile).readAsStringSync().trim()
      : valueOf('--query') ?? 'дайте танк';
  final shown = int.parse(valueOf('--rows') ?? '10');
  await client.ensureToken();

  final own = await client.call('audio.get', {
    'owner_id': '${client.userId}',
    'count': '1000',
  }) as Map<String, dynamic>;
  final ownItems = (own['items'] as List).cast<Map<String, dynamic>>();
  String keyOf(Map<String, dynamic> a) => '${a['owner_id']}_${a['id']}';
  String textOf(Map<String, dynamic> a) =>
      songMatchText('${a['artist']}', '${a['title']}');
  final ownKeys = {for (final a in ownItems) keyOf(a)};
  final ownByTrack = <int, List<Map<String, dynamic>>>{};
  final ownByText = <String, List<Map<String, dynamic>>>{};
  for (final a in ownItems) {
    if (a['track_id'] case final int t) (ownByTrack[t] ??= []).add(a);
    (ownByText[textOf(a)] ??= []).add(a);
  }
  print('account: ${ownItems.length} songs');

  final reply = await client.call('audio.search', {
    'q': query,
    'count': '50',
    'offset': '0',
  }) as Map<String, dynamic>;
  final items = (reply['items'] as List).cast<Map<String, dynamic>>();
  print('search: ${items.length} on page 1');
  for (final (i, a) in items.take(shown).indexed) {
    final seconds = a['duration'] as int;
    final byTrack = ownByTrack[a['track_id']] ?? const [];
    final byText = ownByText[textOf(a)] ?? const [];
    final parts = [
      if (ownKeys.contains(keyOf(a))) 'own key',
      if (a['track_id'] == null) 'no track id',
      for (final b in byTrack)
        'track id = yours "${b['artist']} - ${b['title']}" ${b['duration']} s',
      for (final b in byText) 'name = yours ${b['duration']} s',
    ];
    final close = byTrack.any(
          (b) => ((b['duration'] as int) - seconds).abs() <= 2,
        ) ||
        byText.any((b) => ((b['duration'] as int) - seconds).abs() <= 2);
    print(
      '${i + 1}. ${a['artist']} - ${a['title']} $seconds s: '
      '${parts.isEmpty ? 'not yours' : parts.join('; ')}'
      '${parts.isEmpty ? '' : close ? ' -> same recording' : ' -> other length'}',
    );
  }
}
