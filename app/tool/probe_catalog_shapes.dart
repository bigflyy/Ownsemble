// Prints the SHAPES of the audio.delete answer and of audio.add's error item
// (plan 06, C1), with every number of 4 or more digits blanked to '#'. TEST
// ACCOUNT ONLY: adds one found song and removes it in the same run.
//
// Run from app/: dart run tool/probe_catalog_shapes.dart --vk-session FILE

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  final client = VkClient(
    SessionCookie.loadAll(File(args[args.indexOf('--vk-session') + 1])),
  );

  /// [value] with its Dart types and long numbers blanked; no links.
  String shape(Object? value) => switch (value) {
    Map() =>
      '{${[for (final e in value.entries) '${e.key}: ${shape(e.value)}'].join(', ')}}',
    List() => '[${value.map(shape).join(', ')}]',
    String() =>
      'String "${value.replaceAll(RegExp(r'https?://\S+'), '<link>').replaceAll(RegExp(r'\d{4,}'), '#')}"',
    _ => '${value.runtimeType} ${'$value'.replaceAll(RegExp(r'\d{4,}'), '#')}',
  };

  try {
    await client.ensureToken();
    final me = client.userId;
    final library = await client.call('audio.get', {
      'owner_id': '$me',
      'count': '1000',
    }) as Map<String, dynamic>;
    final items = (library['items'] as List).cast<Map<String, dynamic>>();
    final before = library['count'];
    final blocked = items.firstWhere(
      (a) => ((a['url'] as String?) ?? '').isEmpty,
    );
    final refused = await client.call('audio.add', {
      'audio_id': '${blocked['id']}',
      'owner_id': '${blocked['owner_id']}',
    });
    print('add of a blocked song: ${shape(refused)}');

    final found = await client.call('audio.search', {
      'q': 'ДДТ Осень',
      'count': '20',
    }) as Map<String, dynamic>;
    final own = {for (final a in items) '${a['artist']} - ${a['title']}'};
    final pick = (found['items'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((a) => !own.contains('${a['artist']} - ${a['title']}'));
    final added = await client.call('audio.add', {
      'audio_id': '${pick['id']}',
      'owner_id': '${pick['owner_id']}',
      'access_key': '${pick['access_key']}',
    }) as Map<String, dynamic>;
    print('add: ${shape(added)}');
    final newId = ((added['items'] as List).first as Map)['new_audio_id'];
    final deleted = await client.call('audio.delete', {
      'audio_id': '$newId',
      'owner_id': '$me',
    });
    print('delete: ${shape(deleted)}');
    if (deleted is Map && deleted['audio_ids'] is List) {
      for (final id in deleted['audio_ids'] as List) {
        print(
          '  entry equals the new id: ${'$id' == '$newId'}, '
          'equals me_newid: ${'$id' == '${me}_$newId'}',
        );
      }
    }
    final after = (await client.call('audio.get', {
      'owner_id': '$me',
      'count': '1',
    }) as Map<String, dynamic>)['count'];
    print('library $before -> $after');
  } on VkException catch (error) {
    print('failed: code ${error.code}');
  } finally {
    client.close();
  }
}
