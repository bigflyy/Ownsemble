// Adds the three live uploads of plan 10 G4 (research #69, #20, #87) to the
// TEST account's VK library, and removes them again afterwards. TEST ACCOUNT
// ONLY: it writes to VK (user, 2026-11-23: may add them, removed after).
//
//   dart run tool/g4_live_songs.dart --vk-session FILE --data DIR --add
//   dart run tool/g4_live_songs.dart --vk-session FILE --data DIR --remove
//
// DIR is .local/v2-test. --add finds each live upload again the way
// tool/probe_lyrics_timing.dart --live found it: the library's song at that
// index (checked by its length against DIR/f2-timing/songs/<index>.json),
// then audio.search "<artist> <title> live" and the first result with the
// same artist, a live mark, the studio title, and the length saved in
// DIR/f2-live/songs/<index>.json. It adds that song and writes the new
// library keys to DIR/g4-live-added.json, which --remove reads to delete
// exactly those copies. Printed: index, lengths, added or not, VK error
// codes. No name, link, token, key or id is printed.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/lyrics_match.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';

/// The research's live uploads used by G4.
const liveIndexes = [69, 20, 87];

/// Words in a title that mark a live or acoustic recording (the same as
/// tool/probe_lyrics_timing.dart).
final liveMarks = RegExp(
  r'live|acoustic|unplugged|session|концерт|акуст|живой|live at',
  caseSensitive: false,
);

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// The saved length in seconds of research song [index] in [folder].
int savedSeconds(Directory folder, int index) {
  final json = jsonDecode(
    File('${folder.path}/songs/$index.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return (json['seconds'] as num).round();
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final data = Directory(valueOf('--data')!);
  final keysFile = File('${data.path}/g4-live-added.json');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  await client.ensureToken();

  if (args.contains('--remove')) {
    final keys = (jsonDecode(keysFile.readAsStringSync()) as Map)
        .cast<String, String>();
    var removed = 0;
    for (final entry in keys.entries) {
      final ok = await deleteVkSong(client.call, entry.value);
      print('#${entry.key} removed: $ok');
      if (ok) removed++;
      await pause(800);
    }
    if (removed == keys.length) keysFile.deleteSync();
    print('removed $removed of ${keys.length}');
    return;
  }
  if (!args.contains('--add')) {
    print('pass --add or --remove');
    exit(2);
  }
  if (keysFile.existsSync()) {
    print('${keysFile.path} exists: songs already added; run --remove first');
    exit(1);
  }

  final reply = await client.call('audio.get', {
    'owner_id': '${client.userId}',
    'count': '200',
  }) as Map<String, dynamic>;
  final items = (reply['items'] as List).cast<Map<String, dynamic>>();
  final studioDir = Directory('${data.path}/f2-timing');
  final liveDir = Directory('${data.path}/f2-live');

  // Find all three first, so nothing is added unless every one is found.
  final found = <int, Map<String, dynamic>>{};
  for (final i in liveIndexes) {
    final studioSeconds = savedSeconds(studioDir, i);
    final liveSeconds = savedSeconds(liveDir, i);
    // The library may have changed since the research: look at index i
    // first, then anywhere for a song of the saved length with a live match.
    final candidates = [
      if (i < items.length) items[i],
      for (final item in items)
        if ((item['duration'] as num?)?.round() == studioSeconds) item,
    ];
    Map<String, dynamic>? match;
    for (final item in candidates.toSet()) {
      if ((item['duration'] as num?)?.round() != studioSeconds) continue;
      final artist = '${item['artist'] ?? ''}';
      final title = '${item['title'] ?? ''}';
      await pause(1000);
      final search = await client.call('audio.search', {
        'q': '$artist $title live',
        'count': '30',
      }) as Map<String, dynamic>;
      final results = (search['items'] as List).cast<Map<String, dynamic>>();
      match = results.where((result) {
        final otherTitle = '${result['title'] ?? ''}';
        return foldName('${result['artist'] ?? ''}') == foldName(artist) &&
            liveMarks.hasMatch(otherTitle) &&
            foldName(otherTitle).contains(foldName(title)) &&
            (result['duration'] as num?)?.round() == liveSeconds;
      }).firstOrNull;
      if (match != null) break;
    }
    print(
      '#$i studio ${studioSeconds}s live ${liveSeconds}s: '
      '${match == null ? 'NOT FOUND' : 'found'}',
    );
    if (match != null) found[i] = match;
  }
  if (found.length != liveIndexes.length) {
    print('not every live upload was found: nothing added');
    exit(1);
  }

  final keys = <String, String>{};
  for (final entry in found.entries) {
    final song = entry.value;
    final result = await addVkSong(
      client.call,
      '${song['owner_id']}_${song['id']}',
      accessKey: song['access_key'] as String?,
    );
    if (result.added) {
      keys['${entry.key}'] = result.newKey!;
      // Written after each add, so --remove finds every copy even if a
      // later add fails.
      keysFile.writeAsStringSync(jsonEncode(keys));
    }
    print(
      '#${entry.key} added: ${result.added}'
      '${result.added ? '' : ' (error ${result.errorCode})'}',
    );
    await pause(1000);
  }
}
