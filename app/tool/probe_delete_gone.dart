// What VK answers when Remove from library deletes a song the account no
// longer has (plan 06, C5; the user, 2026-11-16: "on the ones that already
// were removed from VK side undo doesnt work").
// TEST ACCOUNT ONLY: it adds one found song and removes it before it ends.
//
// Cases:
// 1. audio.delete of an id the account never had;
// 2. a song added, deleted, then deleted again (already gone);
// 3. audio.restore after that second delete.
//
// Prints only answer shapes: whether VK said removed, error codes and texts
// with long numbers blanked. No link, token, key or id.
//
// Run from app/:
//   dart run tool/probe_delete_gone.dart --vk-session FILE
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';

String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

/// Only named fields of an answer: whether a delete names a song as
/// removed, whether a restore gave a song back (with its album or not).
String shape(Object? reply) => switch (reply) {
  {'audio_ids': final List ids} => 'removed ${ids.length} song(s)',
  {'id': int _, 'title': final String title} =>
    'gave back "$title"${reply['album'] == null ? ', no album' : ', with album'}',
  _ => 'a ${reply.runtimeType}',
};

Future<String> tryCall(Future<Object?> Function() call) async {
  try {
    final reply = await call();
    return 'answer: ${shape(reply)}';
  } on VkException catch (error) {
    return 'VK error: ${blank(error.message)}';
  } catch (error) {
    return 'error ${error.runtimeType}';
  }
}

Future<void> main(List<String> args) async {
  final session = args[args.indexOf('--vk-session') + 1];
  final client = VkClient(SessionCookie.loadAll(File(session)));
  await client.ensureToken();
  final me = client.userId;
  Future<Object?> delete(String key) {
    final (owner, id) = splitVkKey(key);
    return client.call('audio.delete', {
      'audio_id': '$id',
      'owner_id': '$owner',
    });
  }

  Future<Object?> restore(String key) {
    final (owner, id) = splitVkKey(key);
    return client.call('audio.restore', {
      'audio_id': '$id',
      'owner_id': '$owner',
    });
  }

  print('1. delete an id never had: ${await tryCall(() => delete('${me}_1'))}');

  final page = await searchVkSongs(client.call, 'Кино Кукушка');
  final found = page.songs.firstWhere((s) => s.durationSec > 60);
  final added = await addVkSong(
    client.call,
    found.sourceKey,
    accessKey: found.accessKey,
  );
  final key = added.newKey;
  if (key == null) {
    print('add failed: ${blank(added.errorText)}');
    return;
  }
  try {
    print('2a. first delete: ${await tryCall(() => delete(key))}');
    print('2b. delete again: ${await tryCall(() => delete(key))}');
    print('3. restore after: ${await tryCall(() => restore(key))}');
  } finally {
    // Whatever happened, the copy leaves the account.
    final again = await tryCall(() => delete(key));
    print('cleanup delete: $again');
  }
}
