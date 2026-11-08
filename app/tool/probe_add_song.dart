// Checks whether the web token may add a song to the account's VK library
// and remove it again (plan 06, A1). TEST ACCOUNT ONLY: it writes to VK.
//
// Steps: read the library's count and newest song; search VK for --query;
// take the first result the library does not have (same artist and title);
// audio.add it; read the newest song again (it should be that one); then
// audio.delete it and read the count once more (it should be as before).
// Prints only named fields: artist, title, length, counts, error codes. No
// link, token, key or id is printed.
//
// Run from app/:
//   dart run tool/probe_add_song.dart --vk-session FILE --query "..."
//   (add --keep to leave the song in the library, for a look in VK)

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final query = valueOf('--query') ?? 'Кино Звезда по имени Солнце';
  final keep = args.contains('--keep');

  String name(Map<String, dynamic> a) => '${a['artist']} - ${a['title']}';

  /// The library's total and its newest songs.
  Future<(int, List<Map<String, dynamic>>)> library(int count) async {
    await client.ensureToken();
    final reply = await client.call('audio.get', {
      'owner_id': '${client.userId}',
      'count': '$count',
    }) as Map<String, dynamic>;
    final items = (reply['items'] as List).cast<Map<String, dynamic>>();
    return (reply['count'] as int, items);
  }

  // --undo "Artist - Title": deletes the newest song when it has exactly
  // that name (cleanup after a run that could not delete).
  final undo = valueOf('--undo');
  if (undo != null) {
    try {
      final (count, newest) = await library(1);
      if (name(newest.first) != undo) {
        print('newest is ${name(newest.first)}, not "$undo"; nothing deleted');
        return;
      }
      final deleted = await client.call('audio.delete', {
        'audio_id': '${newest.first['id']}',
        'owner_id': '${client.userId}',
      });
      final (after, last) = await library(1);
      print(
        'audio.delete removed ${deleted is Map ? (deleted['audio_ids'] as List?)?.length : deleted}; library $count -> $after songs, '
        'newest now: ${name(last.first)}',
      );
    } on VkException catch (error) {
      print('failed: code ${error.code}');
    } finally {
      client.close();
    }
    return;
  }

  try {
    final (before, all) = await library(1000);
    print('library before: $before songs, newest: ${name(all.first)}');
    final have = {for (final a in all) name(a).toLowerCase()};

    final found = await client.call('audio.search', {
      'q': query,
      'count': '20',
    }) as Map<String, dynamic>;
    final items = (found['items'] as List).cast<Map<String, dynamic>>();
    print('search "$query": ${items.length} results');
    final pick = items.firstWhere(
      (a) => !have.contains(name(a).toLowerCase()),
      orElse: () => const {},
    );
    if (pick.isEmpty) {
      print('every result is in the library already; try another --query');
      return;
    }
    print(
      'adding: ${name(pick)} (${pick['duration']} s, '
      'own upload of this account: ${pick['owner_id'] == client.userId}, '
      'has access_key: ${pick['access_key'] != null})',
    );

    final clock = Stopwatch()..start();
    final Object? added;
    try {
      added = await client.call('audio.add', {
        'audio_id': '${pick['id']}',
        'owner_id': '${pick['owner_id']}',
        if (pick['access_key'] != null) 'access_key': '${pick['access_key']}',
      });
    } on VkException catch (error) {
      print('audio.add refused: code ${error.code}');
      return;
    }
    print(
      'audio.add answered in ${clock.elapsedMilliseconds} ms with a '
      '${added.runtimeType}',
    );
    if (added is Map<String, dynamic>) {
      // Field names and value types only: values may hold keys.
      print(
        'answer fields: '
        '${[for (final e in added.entries) '${e.key}: ${e.value.runtimeType}'].join(', ')}',
      );
    }
    // VK 2026-11-08 answered with a batch (items_count, errors_count, items,
    // errors), not the bare id of the old docs; each item has new_audio_id,
    // new_owner_id and audio_raw_id.
    final batchItems = added is Map<String, dynamic> && added['items'] is List
        ? added['items'] as List
        : const [];
    final first = batchItems.isEmpty ? null : batchItems.first;
    if (first != null) {
      print(
        'items[0] is a ${first.runtimeType}'
        '${first is Map ? ' with fields ${first.keys.join(', ')}' : ''}',
      );
    }
    final newId = added is int
        ? added
        : first is int
        ? first
        : first is Map && first['new_audio_id'] is int
        ? first['new_audio_id'] as int
        : first is String && first.contains('_')
        ? int.tryParse(first.split('_')[1])
        : null;

    final (afterAdd, newest) = await library(3);
    print(
      'library after add: $afterAdd songs, newest: ${name(newest.first)}, '
      'same song: ${name(newest.first) == name(pick)}, '
      'new id matches the answer: ${newest.first['id'] == newId}, '
      'has a stream: ${(newest.first['url'] as String?)?.isNotEmpty == true}',
    );

    if (keep) {
      print('--keep: left in the library');
      return;
    }
    if (newId == null) {
      print('no id came back; not deleting anything blindly');
      return;
    }
    try {
      final deleted = await client.call('audio.delete', {
        'audio_id': '$newId',
        'owner_id': '${client.userId}',
      });
      // Count only: the answer names the account and song ids.
      print(
        'audio.delete removed '
        '${deleted is Map ? (deleted['audio_ids'] as List?)?.length : deleted}',
      );
    } on VkException catch (error) {
      print('audio.delete refused: code ${error.code}');
    }
    final (afterDelete, last) = await library(1);
    print(
      'library after delete: $afterDelete songs (before: $before), '
      'newest: ${name(last.first)}',
    );
  } on VkException catch (error) {
    print('failed: code ${error.code}');
  } finally {
    client.close();
  }
}
