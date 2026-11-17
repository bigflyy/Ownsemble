// The account's VK playlists (plan 08, B1) from the replies real VK gave
// the test account (test/fixtures/vk_playlists, tool/probe_playlists.dart);
// made playlists and followed albums are the recorded item with the fields
// the second account's showed for those kinds (probe-playlists-25b).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_playlists.dart';

Object? fixture(String name) => jsonDecode(
  File('test/fixtures/vk_playlists/$name.json').readAsStringSync(),
);

/// The recorded followed playlist, changed into another [kind].
Map<String, dynamic> recordedItem() =>
    ((fixture('audio_get_playlists') as Map<String, dynamic>)['items'] as List)
            .first
        as Map<String, dynamic>;

void main() {
  test('the recorded followed playlist', () {
    final list = vkPlaylistOf(recordedItem())!;
    expect(list.kind, VkPlaylistKind.followed);
    expect(list.key, '10000_1', reason: 'the account\'s own entry');
    expect(list.title, 'сладкая вата');
    expect(list.count, 749);
    expect(list.updateTime, 1731794619);
    expect(list.coverUrl, 'https://example.invalid/7.jpg');
    expect(list.accessKey, 'opaque-10');
  });

  test('a made playlist: no original; its cover from the first thumb', () {
    final item = recordedItem()
      ..remove('original')
      ..remove('followed')
      ..remove('photo')
      ..['is_following'] = false
      ..['thumbs'] = [
        {
          'width': 300,
          'height': 300,
          'photo_300': 'https://example.invalid/t.jpg',
        },
      ];
    final list = vkPlaylistOf(item)!;
    expect(list.kind, VkPlaylistKind.made);
    expect(list.coverUrl, 'https://example.invalid/t.jpg');
    item.remove('thumbs');
    expect(vkPlaylistOf(item)!.coverUrl, isNull);
  });

  test('a followed album is an album', () {
    final item = recordedItem()
      ..['type'] = 'album'
      ..['year'] = 2026;
    expect(vkPlaylistOf(item)!.kind, VkPlaylistKind.album);
  });

  test('broken items are left out', () {
    expect(vkPlaylistOf({'title': 'x'}), isNull);
    expect(vkPlaylistOf('x'), isNull);
  });

  test('a JSON round trip keeps everything, Cyrillic too', () {
    final list = vkPlaylistOf(recordedItem())!;
    final back = VkPlaylist.fromJson(
      jsonDecode(jsonEncode(list.toJson())) as Map<String, dynamic>,
    );
    expect(back.toJson(), list.toJson());
    expect(back.sameSongsAs(list), isTrue);
  });

  test('pages advance by the asked size; one held back is fine', () async {
    final asked = <String>[];
    final item = recordedItem();
    Future<Object?> call(String method, Map<String, String> params) async {
      asked.add('$method ${params['offset']}');
      final offset = int.parse(params['offset']!);
      // VK states 201 but gives 199 on the first page and 1 on the next.
      return {
        'count': 201,
        'items': [
          for (var i = 0; i < (offset == 0 ? 199 : 1); i++)
            {...item, 'id': offset + i + 1},
        ],
      };
    }

    final lists = await fetchVkPlaylists(call, 10000);
    expect(asked, ['audio.getPlaylists 0', 'audio.getPlaylists 200']);
    expect(lists, hasLength(200));
    expect(lists.last.key, '10000_201');
  });

  test('the songs of a playlist, in order, through album_id', () async {
    final asked = <Map<String, String>>[];
    Future<Object?> call(String method, Map<String, String> params) async {
      asked.add({'method': method, ...params});
      // The recorded page of 20, as a list of 20.
      final reply = fixture('audio_get_playlist_songs') as Map<String, dynamic>;
      return {...reply, 'count': (reply['items'] as List).length};
    }

    final list = vkPlaylistOf(recordedItem())!;
    final songs = await fetchVkPlaylistSongs(call, list);
    final recorded =
        (fixture('audio_get_playlist_songs') as Map<String, dynamic>)['items']
            as List;
    expect(songs, hasLength(recorded.length));
    expect(songs.first.song.title, (recorded.first as Map)['title']);
    expect(asked.single['owner_id'], '10000');
    expect(asked.single['album_id'], '1');
    expect(asked.single['access_key'], 'opaque-10');
    expect(asked.single['count'], '500');
  });
}
