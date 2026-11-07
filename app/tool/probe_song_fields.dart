// Lists which fields VK sends for the songs of an account (audio.get), and
// how many of the songs have each: names and counts only. No value is
// printed, so no link, key, token or song name can leak.
//
// Run from app/:
//   dart run tool/probe_song_fields.dart --vk-session FILE [--count 200]

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
  try {
    final reply = await client.call('audio.get', {
      'count': valueOf('--count') ?? '200',
    }) as Map<String, dynamic>;
    final items = (reply['items'] as List).cast<Map<String, dynamic>>();
    final counts = <String, int>{};

    // Field paths, one level into objects and into the first element of
    // lists of objects ("main_artists[].name").
    void walk(Map<String, dynamic> map, String prefix, Set<String> seen) {
      for (final MapEntry(:key, :value) in map.entries) {
        final path = '$prefix$key';
        final kind = switch (value) {
          Map() => 'object',
          List() => 'list',
          String() => 'text',
          int() || double() => 'number',
          bool() => 'yes/no',
          null => 'empty',
          _ => 'other',
        };
        seen.add('$path ($kind)');
        if (value is Map<String, dynamic> && prefix.split('.').length < 3) {
          walk(value, '$path.', seen);
        } else if (value is List &&
            value.isNotEmpty &&
            value.first is Map<String, dynamic>) {
          walk(value.first as Map<String, dynamic>, '$path[].', seen);
        }
      }
    }

    for (final item in items) {
      final seen = <String>{};
      walk(item, '', seen);
      for (final path in seen) {
        counts[path] = (counts[path] ?? 0) + 1;
      }
    }
    print('${items.length} songs');
    final paths = counts.keys.toList()..sort();
    for (final path in paths) {
      print('${counts[path].toString().padLeft(4)}  $path');
    }
  } on Object catch (error) {
    print('failed: ${error.runtimeType}');
  } finally {
    client.close();
  }
}
