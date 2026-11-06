// Asks VK why one song cannot be played: audio.getRestrictionPopup for the
// song's key, printing only the popup's title and text, and the song's
// content_restricted code. No link, token or key is printed.
//
// Run from app/:
//   dart run tool/probe_restriction.dart --data-dir DIR --vk-session FILE
//     --track-id N

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final store = LibraryStore.open(p.join(valueOf('--data-dir')!, 'library.db'));
  final id = int.parse(valueOf('--track-id')!);
  final track = store.loadAll().firstWhere((t) => t.id == id);
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  try {
    final key = track.sourceKey!;
    final song = await client.call('audio.getById', {'audios': key}) as List;
    final audio = song.isEmpty ? null : song.first as Map<String, dynamic>;
    print('content_restricted: ${audio?['content_restricted']}');
    final popup = await client.call('audio.getRestrictionPopup', {
      'audio_id': key,
    });
    if (popup is Map<String, dynamic>) {
      for (final field in ['title', 'text']) {
        print('$field: ${popup[field]}');
      }
    } else {
      print('popup: ${popup.runtimeType}');
    }
  } on Object catch (error) {
    print('failed: ${error.runtimeType}');
  } finally {
    client.close();
    store.close();
  }
}
