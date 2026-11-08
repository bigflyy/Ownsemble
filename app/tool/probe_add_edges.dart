// The edge cases of adding a song to the VK library (plan 06, A2).
// TEST ACCOUNT ONLY: it writes to VK, and removes every song it added before
// it ends (also when a step fails).
//
// Cases:
// 1. add a found song: time, answer, album and cover kept on the copy;
// 2. add the same found song again: a second copy, or an error in `errors`;
// 3. add a song without its access_key;
// 4. add a song VK blocks (content_restricted), when a search finds one;
// 5. a real sync into a scratch library: the added song comes in once, under
//    the key "me_newid" the add answered with; after the removal it is gone;
// 6. Undo after Remove: add two songs, remove the older one (2nd place),
//    `audio.restore` it: back at its old place, under the same id?
// 7. pace: a few add + delete rounds back to back; any captcha / flood (14/9)?
//
// Prints only named fields: artist, title, counts, places, times, error codes
// and error texts with long numbers blanked. No link, token, key or id.
//
// Run from app/:
//   dart run tool/probe_add_edges.dart --vk-session FILE [--rounds 5]
//   (--only-blocked runs case 4 alone)

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:path/path.dart' as p;

/// What one `audio.add` did.
class AddOutcome {
  AddOutcome(this.ms, this.newId, this.errors);
  final int ms;

  /// The id of the copy in the account's library; null when nothing was added.
  final int? newId;

  /// The batch's errors, safe to print (codes and texts, long numbers blanked).
  final List<String> errors;
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final onlyBlocked = args.contains('--only-blocked');
  final rounds = int.tryParse(valueOf('--rounds') ?? '') ?? 5;
  await client.ensureToken();
  final me = client.userId;

  String name(Map<String, dynamic> a) => '${a['artist']} - ${a['title']}';
  String albumOf(Map<String, dynamic> a) {
    final album = a['album'];
    return album is Map ? '"${album['title']}"' : 'none';
  }

  bool hasThumb(Map<String, dynamic> a) {
    final album = a['album'];
    return a['thumb'] is Map || (album is Map && album['thumb'] is Map);
  }

  /// Error texts may name songs or accounts by number: blank long numbers
  /// and links.
  String scrub(Object? text) => '$text'
      .replaceAll(RegExp(r'https?://\S+'), '<link>')
      .replaceAll(RegExp(r'\d{4,}'), '#');

  /// The library's total and its first [count] songs, newest first.
  Future<(int, List<Map<String, dynamic>>)> library(int count) async {
    final reply = await client.call('audio.get', {
      'owner_id': '$me',
      'count': '$count',
    }) as Map<String, dynamic>;
    return (
      reply['count'] as int,
      (reply['items'] as List).cast<Map<String, dynamic>>(),
    );
  }

  /// Ids this run added and has not removed yet; removed in `finally`.
  final added = <int>{};
  final log = <String>[];
  void say(String line) {
    print(line);
    log.add(line);
  }

  var writes = 0;
  final writeClock = Stopwatch()..start();

  Future<AddOutcome> add(
    Map<String, dynamic> song, {
    bool withKey = true,
  }) async {
    final clock = Stopwatch()..start();
    writes++;
    final Object? reply;
    try {
      reply = await client.call('audio.add', {
        'audio_id': '${song['id']}',
        'owner_id': '${song['owner_id']}',
        if (withKey && song['access_key'] != null)
          'access_key': '${song['access_key']}',
      });
    } on VkException catch (error) {
      return AddOutcome(clock.elapsedMilliseconds, null, [
        'refused: code ${error.code} ${scrub(error.message)}',
      ]);
    }
    final ms = clock.elapsedMilliseconds;
    if (reply is! Map<String, dynamic>) {
      return AddOutcome(ms, null, ['answer is a ${reply.runtimeType}']);
    }
    final items = reply['items'] is List ? reply['items'] as List : const [];
    final first = items.isEmpty ? null : items.first;
    final newId = first is Map && first['new_audio_id'] is int
        ? first['new_audio_id'] as int
        : null;
    if (first is Map && first['new_owner_id'] != me) {
      say('  note: new_owner_id is not this account');
    }
    if (newId != null) added.add(newId);
    final errors = [
      for (final e in (reply['errors'] is List ? reply['errors'] as List : []))
        e is Map
            ? 'fields ${e.keys.join(', ')}; '
                  'code ${e['error_code'] ?? e['code']}; '
                  'text ${scrub(e['error_msg'] ?? e['msg'] ?? e['message'])}'
            : scrub(e),
    ];
    return AddOutcome(ms, newId, [
      if (reply['items_count'] != items.length)
        'items_count ${reply['items_count']} vs ${items.length} items',
      'errors_count ${reply['errors_count']}',
      ...errors,
    ]);
  }

  Future<bool> remove(int id) async {
    writes++;
    try {
      await client.call('audio.delete', {'audio_id': '$id', 'owner_id': '$me'});
      added.remove(id);
      return true;
    } on VkException catch (error) {
      say('  audio.delete refused: code ${error.code}');
      return false;
    }
  }

  /// Place (0 = newest) of the song with [id] in the newest [count]; -1 when
  /// it is not there.
  Future<int> placeOf(int id, {int count = 10}) async {
    final (_, items) = await library(count);
    return items.indexWhere((a) => a['id'] == id);
  }

  final temp = Directory.systemTemp.createTempSync('ownsemble_add_edges');
  final store = LibraryStore.open(p.join(temp.path, 'library.db'));
  final (before, all) = await library(1000);
  final newestBefore = name(all.first);
  say('library before: $before songs, newest: $newestBefore');

  try {
    // A scratch library synced from the account, as the app's would be.
    final first = await syncVkSource(
      call: client.call,
      userId: me,
      store: store,
    );
    say('scratch sync: ${first.listed} listed, ${first.added} added');

    // Songs to add: search results the library does not have.
    final have = {for (final a in all) name(a).toLowerCase()};
    final pool = <Map<String, dynamic>>[];
    final blocked = <Map<String, dynamic>>[];
    var withoutKey = 0;
    for (final query in [
      'Кино Группа крови',
      'Земфира Искала',
      'Ария Беспечный ангел',
      'Metallica Nothing Else Matters',
      'Сплин Выхода нет',
    ]) {
      final found = await client.call('audio.search', {
        'q': query,
        'count': '30',
      }) as Map<String, dynamic>;
      for (final a in (found['items'] as List).cast<Map<String, dynamic>>()) {
        if (a['access_key'] == null) withoutKey++;
        if (a['content_restricted'] != null) {
          blocked.add(a);
        } else if (!have.contains(name(a).toLowerCase()) &&
            !pool.any((b) => name(b) == name(a))) {
          pool.add(a);
        }
      }
    }
    say(
      'search: ${pool.length} new playable songs, ${blocked.length} blocked, '
      '$withoutKey results without access_key',
    );
    // 4. A blocked song: from the searches, else one of the library's own
    // blocked songs (VK lists those with content_restricted), which also
    // makes it a second copy.
    Future<void> blockedCase() async {
      final fromLibrary = [
        for (final a in all)
          if (a['content_restricted'] != null) a,
      ];
      final source = blocked.isNotEmpty ? 'search' : 'library';
      final b = blocked.isNotEmpty
          ? blocked.first
          : fromLibrary.isEmpty
          ? null
          : fromLibrary.first;
      if (b == null) {
        say('\n4. no blocked song in the searches or the library; not checked');
        return;
      }
      say(
        '\n4. add blocked ${name(b)} from the $source '
        '(content_restricted ${b['content_restricted']}; '
        '${fromLibrary.length} blocked in the library)',
      );
      final (countBefore, _) = await library(1);
      final a4 = await add(b);
      final (countAfter, t) = await library(1);
      say(
        '  ${a4.ms} ms, new id came back: ${a4.newId != null}, ${a4.errors}; '
        'library $countBefore -> $countAfter; '
        'newest is the copy: ${a4.newId != null && t.first['id'] == a4.newId}',
      );
      for (final id in added.toList()) {
        await remove(id);
      }
    }

    if (onlyBlocked) {
      await blockedCase();
      return;
    }
    if (pool.length < 3) {
      say('fewer than 3 songs to add; stopping');
      return;
    }
    final songA = pool[0];
    final songB = pool[1];
    final songC = pool[2];

    // 1. Add, and compare the copy with the found song.
    say('\n1. add ${name(songA)}');
    final a1 = await add(songA);
    say('  ${a1.ms} ms, new id came back: ${a1.newId != null}, ${a1.errors}');
    final (_, top) = await library(3);
    final copy = top.first;
    say(
      '  copy is newest: ${copy['id'] == a1.newId}; '
      'album found ${albumOf(songA)} / copy ${albumOf(copy)}; '
      'cover found ${hasThumb(songA)} / copy ${hasThumb(copy)}; '
      'length ${songA['duration']} / ${copy['duration']} s; '
      'copy has access_key: ${copy['access_key'] != null}; '
      'copy content_restricted: ${copy['content_restricted']}',
    );

    // 2. The same found song again.
    say('\n2. add ${name(songA)} again (same found song)');
    final a2 = await add(songA);
    final (afterTwice, _) = await library(1);
    say(
      '  ${a2.ms} ms, new id came back: ${a2.newId != null}, '
      'same id as the first copy: ${a2.newId == a1.newId}, ${a2.errors}; '
      'library $before -> $afterTwice',
    );
    // And the copy itself (owner = me) added once more.
    say('  add the copy itself (owner = this account)');
    final a2b = await add(copy);
    final (afterCopy, _) = await library(1);
    say(
      '  ${a2b.ms} ms, new id came back: ${a2b.newId != null}, '
      '${a2b.errors}; library now $afterCopy',
    );

    // 5. A real sync sees the added songs once each, under the add's key.
    say('\n5. scratch sync after the adds');
    final second = await syncVkSource(
      call: client.call,
      userId: me,
      store: store,
    );
    final rows = store
        .loadAll()
        .where((t) => '${t.artist} - ${t.title}' == name(songA))
        .toList();
    say(
      '  sync added ${second.added}; rows named like the song: ${rows.length}; '
      'row keys are "me_newid" of the adds: '
      '${rows.every((t) => added.any((id) => t.sourceKey == '${me}_$id'))}',
    );

    // 3. Without the access_key.
    say(
      '\n3. add ${name(songB)} without its access_key '
      '(it has one: ${songB['access_key'] != null})',
    );
    final a3 = await add(songB, withKey: false);
    say('  ${a3.ms} ms, new id came back: ${a3.newId != null}, ${a3.errors}');

    await blockedCase();

    // Remove everything added so far before the Undo case.
    for (final id in added.toList()) {
      await remove(id);
    }
    final (cleared, _) = await library(1);
    say('\nremoved the adds: library $cleared (before $before)');

    // 5b. The sync after the removal.
    final third = await syncVkSource(
      call: client.call,
      userId: me,
      store: store,
    );
    say(
      '5b. scratch sync after the removal: newly gone ${third.newlyGone}, '
      'added ${third.added}',
    );

    // 6. Undo after Remove: is audio.restore's song back at its old place?
    say('\n6. Undo after Remove');
    final older = await add(songB);
    final newer = await add(songC);
    if (older.newId == null || newer.newId == null) {
      say('  an add failed; not checked');
    } else {
      final placeBefore = await placeOf(older.newId!);
      await remove(older.newId!);
      final placeRemoved = await placeOf(older.newId!);
      final clock = Stopwatch()..start();
      writes++;
      Object? restored;
      try {
        restored = await client.call('audio.restore', {
          'audio_id': '${older.newId}',
          'owner_id': '$me',
        });
        added.add(older.newId!);
      } on VkException catch (error) {
        say('  audio.restore refused: code ${error.code}');
      }
      final ms = clock.elapsedMilliseconds;
      final (count, items) = await library(10);
      final placeAfter = items.indexWhere((a) => a['id'] == older.newId);
      final sameName = items.indexWhere((a) => name(a) == name(songB));
      say(
        '  ${name(songB)} at place $placeBefore; after Remove: $placeRemoved; '
        'audio.restore answered in $ms ms with a ${restored.runtimeType}'
        '${restored is Map ? ' (fields ${restored.keys.join(', ')})' : ''}; '
        'after: same id at place $placeAfter, same name at place $sameName; '
        'library $count',
      );
      // Restore after a pause the length of an Undo bar.
      await remove(older.newId!);
      await Future<void>.delayed(const Duration(seconds: 8));
      try {
        writes++;
        await client.call('audio.restore', {
          'audio_id': '${older.newId}',
          'owner_id': '$me',
        });
        added.add(older.newId!);
        say('  restore 8 s after Remove: place ${await placeOf(older.newId!)}');
      } on VkException catch (error) {
        say('  restore 8 s after Remove refused: code ${error.code}');
      }
      // The sync after Remove + restore: the same row, not gone, not new.
      final fourth = await syncVkSource(
        call: client.call,
        userId: me,
        store: store,
      );
      say(
        '  scratch sync after Remove + restore: added ${fourth.added}, '
        'back ${fourth.back}, newly gone ${fourth.newlyGone}',
      );
    }
    for (final id in added.toList()) {
      await remove(id);
    }

    // 7. Pace: add + delete rounds back to back.
    say('\n7. $rounds add + delete rounds back to back');
    final times = <int>[];
    for (var i = 0; i < rounds; i++) {
      final r = await add(songC);
      times.add(r.ms);
      if (r.newId == null) {
        say('  round ${i + 1}: ${r.errors}');
        break;
      }
      await remove(r.newId!);
    }
    say('  add times: $times ms; no refusal: ${times.length == rounds}');
  } on VkException catch (error) {
    say('failed: code ${error.code} ${scrub(error.message)}');
  } finally {
    for (final id in added.toList()) {
      await remove(id);
    }
    final (after, last) = await library(1);
    say(
      '\nlibrary after: $after songs (before $before), newest: '
      '${name(last.first)}, as before: ${name(last.first) == newestBefore}; '
      '$writes writes in ${writeClock.elapsed.inSeconds} s; '
      'left behind: ${added.length}',
    );
    store.close();
    client.close();
    temp.deleteSync(recursive: true);
  }
}
