// Read-only: do songs VK answers with plain lyrics come back timed when
// asked differently (extra arguments, a newer API version)? Prints counts
// and argument names only, never words, keys or tokens.
//
//   dart run tool/probe_lyrics_timed.dart --vk-session FILE [--songs 6]
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
  final wanted = int.parse(valueOf('--songs') ?? '6');
  Future<void> pause() =>
      Future<void>.delayed(const Duration(milliseconds: 500));
  String shape(Object? reply) {
    final lyrics = reply is Map ? reply['lyrics'] : null;
    if (lyrics is! Map) return 'no lyrics';
    final stamps = lyrics['timestamps'];
    final text = lyrics['text'];
    return [
      if (stamps is List) 'timestamps ${stamps.length}',
      if (text is List) 'text ${text.length}',
      'keys ${lyrics.keys.join('/')}',
      if (reply is Map) 'top ${reply.keys.join('/')}',
    ].join(', ');
  }

  try {
    final reply = await client.call('audio.get', {'count': '200'}) as Map;
    final songs = (reply['items'] as List).cast<Map<String, dynamic>>();
    final plain = <Map<String, dynamic>>[];
    for (final song in songs.where((s) => s['has_lyrics'] == true)) {
      if (plain.length >= wanted) break;
      await pause();
      final id = '${song['owner_id']}_${song['id']}';
      final answer = await client.call('audio.getLyrics', {'audio_id': id});
      final lyrics = answer is Map ? answer['lyrics'] : null;
      if (lyrics is Map && lyrics['timestamps'] == null) plain.add(song);
    }
    print('plain songs to try: ${plain.length}');
    final variants = <String, Map<String, String>>{
      'need_timestamps': {'need_timestamps': '1'},
      'timestamps': {'timestamps': '1'},
      'with_timestamps': {'with_timestamps': '1'},
      'need_lyrics_timestamps': {'need_lyrics_timestamps': '1'},
      'format=lrc': {'format': 'lrc'},
      'v=5.299': {'v': '5.299'},
      'v=5.199 (older)': {'v': '5.199'},
    };
    var i = 0;
    for (final song in plain) {
      i++;
      final id = '${song['owner_id']}_${song['id']}';
      final ak = song['access_key'];
      for (final MapEntry(key: name, value: extra) in variants.entries) {
        await pause();
        try {
          final answer = await client.call('audio.getLyrics', {
            'audio_id': id,
            ...extra,
          });
          print('song $i, $name: ${shape(answer)}');
        } on VkException catch (error) {
          print('song $i, $name: error ${error.code}');
        }
      }
      if (ak is String) {
        await pause();
        try {
          final answer = await client.call('audio.getLyrics', {
            'audio_id': '${id}_$ak',
          });
          print('song $i, with access key: ${shape(answer)}');
        } on VkException catch (error) {
          print('song $i, with access key: error ${error.code}');
        }
      }
      // The song as audio.getById returns it: any lyrics fields there?
      await pause();
      final byId = await client.call('audio.getById', {'audios': id}) as List;
      final fields = (byId.first as Map).keys.where(
        (k) => '$k'.contains('lyric') || '$k'.contains('karaoke'),
      );
      print('song $i, getById lyrics fields: ${fields.join(', ')}');
    }
  } on Object catch (error) {
    print(
      'failed: ${error.runtimeType} ${error is VkException ? error.code : ''}',
    );
  } finally {
    client.close();
  }
}
