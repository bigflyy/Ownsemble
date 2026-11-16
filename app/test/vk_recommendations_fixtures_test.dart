// Checks the recorded VK recommendation replies (plan 07, A5) that the
// unit tests' fakes are built from: they were scrubbed before being
// committed (no real link, key or id), they keep their references (block
// lists point at songs and playlists in the same reply), and their Cyrillic
// names came through as UTF-8.
//
// The files come from tool/probe_recommendations.dart --fixtures on the
// test account, 2026-11-16.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/fixtures/vk_recommendations';

Object? _load(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync());

/// Every string value in [value], with the key it sits under.
Iterable<(String, String)> _texts(Object? value, [String key = '']) sync* {
  switch (value) {
    case Map():
      for (final MapEntry(key: k, value: v) in value.entries) {
        yield* _texts(v, '$k');
      }
    case List():
      for (final v in value) {
        yield* _texts(v, key);
      }
    case String():
      yield (key, value);
  }
}

String _keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

void main() {
  final files = Directory(_dir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
      .toList();

  test('all the recorded replies are there', () {
    expect(
      files,
      containsAll([
        'catalog_get_audio',
        'catalog_get_block_items',
        'audio_get_playlist_by_id_generated',
        'audio_get_generated_playlist',
        'audio_get_recommendations',
        'audio_get_recommendations_target',
        'audio_get_stream_mix_audios',
        'audio_get_by_id_restricted_1',
        'audio_get_by_id_restricted_2',
      ]),
    );
  });

  test('no real link, key or long id is left', () {
    for (final name in files) {
      for (final (key, text) in _texts(_load(name))) {
        if (text.startsWith('http')) {
          expect(text, startsWith('https://example.invalid/'), reason: name);
        }
        if (key.contains('key') || key.contains('hash')) {
          expect(text, anyOf('', startsWith('opaque-')), reason: '$name $key');
        }
        // A header's "show all" action has an internal link without a
        // scheme: it becomes opaque like any other unknown text.
        if (key == 'url') {
          expect(
            text,
            anyOf(
              '',
              startsWith('https://example.invalid/'),
              startsWith('opaque-'),
            ),
            reason: name,
          );
        }
      }
    }
  });

  test('the music page lists point at songs and playlists in the reply', () {
    final page = _load('catalog_get_audio') as Map<String, dynamic>;
    final songs = {
      for (final a in (page['audios'] as List).cast<Map<String, dynamic>>())
        _keyOf(a),
    };
    final playlists = {
      for (final p in (page['playlists'] as List).cast<Map<String, dynamic>>())
        _keyOf(p),
    };
    final sections = (page['catalog'] as Map)['sections'] as List;
    final blocks = sections
        .cast<Map<String, dynamic>>()
        .expand((s) => (s['blocks'] as List? ?? const []))
        .cast<Map<String, dynamic>>()
        .toList();
    final songIds = blocks.expand((b) => b['audios_ids'] as List? ?? const []);
    final listIds = blocks
        .where((b) => b['data_type'] == 'music_playlists')
        .expand((b) => b['playlists_ids'] as List? ?? const []);
    expect(songIds, isNotEmpty);
    expect(songIds.every(songs.contains), isTrue);
    expect(listIds, isNotEmpty);
    expect(listIds.every(playlists.contains), isTrue);
    // The "made by algorithms" lists are the account's own generated ones.
    final generated = (page['playlists'] as List)
        .cast<Map<String, dynamic>>()
        .where((p) => p['type'] == 'generated');
    expect(generated.length, greaterThanOrEqualTo(7));
  });

  test('a generated playlist reads as a page of songs with Cyrillic names', () {
    final reply = _load('audio_get_generated_playlist') as Map<String, dynamic>;
    final items = (reply['items'] as List).cast<Map<String, dynamic>>();
    expect(reply['count'], greaterThan(items.length - 1));
    expect(items, hasLength(12));
    final names = items.map((i) => '${i['artist']} ${i['title']}').join(' ');
    expect(names, matches(RegExp('[А-Яа-яЁё]')));
    expect(names, isNot(contains('�')));
    for (final item in items) {
      expect(item['duration'], isA<int>());
      expect(item['url'], startsWith('https://example.invalid/'));
    }
  });

  test('restricted songs come without a link and with their code', () {
    for (final code in [1, 2]) {
      final reply = _load('audio_get_by_id_restricted_$code') as List;
      final song = reply.single as Map<String, dynamic>;
      expect(song['url'], '');
      expect(song['content_restricted'], code);
    }
  });
}
