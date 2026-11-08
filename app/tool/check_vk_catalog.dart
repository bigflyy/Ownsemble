// Real check of lib/vk/vk_catalog.dart (plan 06, C1). TEST ACCOUNT ONLY: it
// writes to VK and removes everything it adds in the same run.
//
// Steps: library count and newest song; searchVkSongs for --query, page 1
// and page 2; addVkSong the first found song the library does not have; it
// must be the newest song under the key the add answered with; deleteVkSong
// it; restoreVkSong it (back as the newest, same key); deleteVkSong again;
// addVkSong a blocked song of the library (must be refused, code 15, nothing
// added); the count must be as before. Prints only named fields: names,
// counts, times, yes/no and error codes. No link, token, key or id.
//
// Run from app/:
//   dart run tool/check_vk_catalog.dart --vk-session FILE [--query "..."]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final query = valueOf('--query') ?? 'Наутилус Помпилиус';
  var problems = 0;
  void check(bool ok, String what) {
    if (!ok) problems++;
    print('  ${ok ? 'ok  ' : 'FAIL'} $what');
  }

  String name(Map<String, dynamic> a) => '${a['artist']} - ${a['title']}';

  /// The library's total and its newest songs.
  Future<(int, List<Map<String, dynamic>>)> library(int count) async {
    final reply = await client.call('audio.get', {
      'owner_id': '${client.userId}',
      'count': '$count',
    }) as Map<String, dynamic>;
    return (
      reply['count'] as int,
      (reply['items'] as List).cast<Map<String, dynamic>>(),
    );
  }

  // Keys of copies this run added and has not removed yet.
  final leftOver = <String>{};
  try {
    await client.ensureToken();
    final (before, all) = await library(1000);
    print('library before: $before songs, newest: ${name(all.first)}');
    final ownKeys = {for (final a in all) vkSourceKey(a)};
    final ownNames = {for (final a in all) name(a).toLowerCase()};

    print('1. search "$query"');
    var clock = Stopwatch()..start();
    final page1 = await searchVkSongs(client.call, query);
    final ms1 = clock.elapsedMilliseconds;
    clock = Stopwatch()..start();
    final page2 = await searchVkSongs(
      client.call,
      query,
      offset: page1.nextOffset,
    );
    final ms2 = clock.elapsedMilliseconds;
    print(
      '  page 1: ${page1.songs.length} songs in $ms1 ms, total ${page1.total}; '
      'page 2: ${page2.songs.length} songs in $ms2 ms, more: ${page2.hasMore}',
    );
    final page1Keys = {for (final s in page1.songs) s.sourceKey};
    check(page1.songs.isNotEmpty, 'page 1 found songs');
    check(
      page2.songs.every((s) => !page1Keys.contains(s.sourceKey)),
      'page 2 repeats none of page 1',
    );
    check(
      page1.songs.every((s) => s.artist.isNotEmpty && s.title.isNotEmpty),
      'every found song has an artist and a title',
    );
    print(
      '  first found: ${page1.songs.first.artist} - '
      '${page1.songs.first.title}',
    );

    final pick = page1.songs.firstWhere(
      (s) =>
          !ownKeys.contains(s.sourceKey) &&
          !ownNames.contains('${s.artist} - ${s.title}'.toLowerCase()),
    );
    print('2. add ${pick.artist} - ${pick.title} (${pick.durationSec} s)');
    clock = Stopwatch()..start();
    final added = await addVkSong(
      client.call,
      pick.sourceKey,
      accessKey: pick.accessKey,
    );
    print('  answered in ${clock.elapsedMilliseconds} ms');
    check(added.added, 'added (error code: ${added.errorCode})');
    if (!added.added) return;
    leftOver.add(added.newKey!);
    final (afterAdd, newest) = await library(1);
    check(afterAdd == before + 1, 'library $before -> $afterAdd');
    check(
      vkSourceKey(newest.first) == added.newKey,
      'the newest song is under the key the add answered with',
    );
    check(
      newest.first['owner_id'] == client.userId,
      'the copy belongs to the account',
    );
    check(
      name(newest.first) == '${pick.artist} - ${pick.title}',
      'the newest song is the found one by name',
    );
    // The app stores the copy without an access key (NewTrack.asAddedCopy)
    // until the next sync: VK must give the account's own song without one.
    final stream = await client.resolveStream(added.newKey!, null);
    check(stream.link != null, 'the copy gives a stream without an access key');
    check(
      newest.first['track_id'] == null ||
          '${newest.first['track_id']}' == '${pick.vkTrackId}',
      'the copy keeps the track id of the found song (FoundMatcher rule 2)',
    );

    print('3. delete the copy');
    clock = Stopwatch()..start();
    final deleted = await deleteVkSong(client.call, added.newKey!);
    print('  answered in ${clock.elapsedMilliseconds} ms');
    check(deleted, 'VK says it removed that song');
    final (afterDelete, _) = await library(1);
    check(afterDelete == before, 'library back to $afterDelete');
    if (deleted) leftOver.remove(added.newKey);

    print('4. restore it (Undo)');
    clock = Stopwatch()..start();
    final restored = await restoreVkSong(client.call, added.newKey!);
    print('  answered in ${clock.elapsedMilliseconds} ms');
    leftOver.add(added.newKey!);
    check(restored.sourceKey == added.newKey, 'restored under the same key');
    check(
      '${restored.artist} - ${restored.title}' ==
          '${pick.artist} - ${pick.title}',
      'restored song read with its name',
    );
    final (afterRestore, newestAgain) = await library(1);
    check(afterRestore == before + 1, 'library $before -> $afterRestore');
    check(
      vkSourceKey(newestAgain.first) == added.newKey,
      'back at its old place (newest)',
    );

    print('5. delete it again');
    final deletedAgain = await deleteVkSong(client.call, added.newKey!);
    check(deletedAgain, 'VK says it removed that song');
    if (deletedAgain) leftOver.remove(added.newKey);

    final blocked = all.where((a) => ((a['url'] as String?) ?? '').isEmpty);
    if (blocked.isEmpty) {
      print('6. no blocked song in the library; refusal not checked');
    } else {
      final song = blocked.first;
      print('6. add the blocked ${name(song)} again');
      final refused = await addVkSong(
        client.call,
        vkSourceKey(song),
        accessKey: song['access_key'] as String?,
      );
      if (refused.added) leftOver.add(refused.newKey!);
      check(!refused.added, 'not added');
      check(
        refused.noAccess,
        'refused with code ${refused.errorCode}: ${refused.errorText}',
      );
    }
  } on VkException catch (error) {
    problems++;
    print('VK failed: code ${error.code}');
  } finally {
    for (final key in leftOver) {
      try {
        final ok = await deleteVkSong(client.call, key);
        print('cleanup: removed a copy left behind: $ok');
      } on VkException catch (error) {
        print('cleanup FAILED: code ${error.code}; remove it by hand');
      }
    }
    try {
      final (after, newest) = await library(1);
      print('library after: $after songs, newest: ${name(newest.first)}');
    } on VkException catch (error) {
      print('last count failed: code ${error.code}');
    }
    print(problems == 0 ? 'ALL OK' : '$problems PROBLEMS');
    client.close();
  }
}
