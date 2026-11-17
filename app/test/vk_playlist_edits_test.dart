// The VK writes of playlist edits (plan 08, C2), against a fake that does
// what real VK did on the test account (test/playlist_edits_support.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_playlist_edits.dart';
import 'package:ownsemble/vk/vk_playlists.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';

import 'playlist_edits_support.dart';

void main() {
  late EditVk vk;
  setUp(() => vk = EditVk());

  test('a key splits at its last underscore; others are refused', () {
    expect(splitVkKey('-123_45'), (owner: '-123', id: '45'));
    expect(() => splitVkKey('12345'), throwsArgumentError);
    expect(() => splitVkKey('12_'), throwsArgumentError);
    expect(vkSongRef('1_2', null), '1_2');
    expect(vkSongRef('1_2', ''), '1_2');
    expect(vkSongRef('1_2', 'ak'), '1_2_ak');
  });

  test('a new playlist with songs: the last one on top, editable', () async {
    vk.song(10000, 1);
    vk.song(10000, 2);
    final list = await createVkPlaylist(
      vk.call,
      10000,
      'Новый',
      songs: ['10000_1', '10000_2'],
    );
    expect(list.title, 'Новый');
    expect(list.kind, VkPlaylistKind.made);
    expect(list.editable, isTrue);
    final fake = vk.byId(int.parse(splitVkKey(list.key).id));
    expect(vk.keysOf(fake), ['10000_2', '10000_1']);
  });

  test('add puts a song on top; another owner\'s song goes in as a copy, '
      'and twice makes two copies', () async {
    vk.song(10000, 1);
    vk.song(555, 7, trackId: 77);
    final list = vk.made('Мой', [vk.known['10000_1']!]);
    final key = '10000_${list.id}';
    expect(await addToVkPlaylist(vk.call, key, '555_7_ak'), isTrue);
    final keys = vk.keysOf(list);
    expect(keys, hasLength(2));
    expect(keys.first, isNot('555_7'), reason: 'a copy with a new key');
    expect(keys.first, startsWith('10000_'));
    expect(vk.known[keys.first]!['track_id'], 77);
    // The account's own song again: nothing added (one item replied).
    expect(await addToVkPlaylist(vk.call, key, '10000_1'), isTrue);
    expect(vk.keysOf(list), hasLength(2));
    // The original again: a second copy.
    await addToVkPlaylist(vk.call, key, '555_7');
    expect(vk.keysOf(list), hasLength(3));
  });

  test('remove by the read key; a removed copy cannot come back', () async {
    vk.song(555, 7);
    final list = vk.made('Мой');
    final key = '10000_${list.id}';
    await addToVkPlaylist(vk.call, key, '555_7');
    final copy = vk.keysOf(list).single;
    expect(await removeFromVkPlaylist(vk.call, key, '555_7'), isFalse);
    expect(vk.keysOf(list), [copy], reason: 'the original key is not in');
    expect(await removeFromVkPlaylist(vk.call, key, copy), isTrue);
    expect(vk.keysOf(list), isEmpty);
    expect(await addToVkPlaylist(vk.call, key, copy), isFalse);
    expect(vk.keysOf(list), isEmpty);
  });

  test('move before or after a neighbour, by the read keys', () async {
    for (final id in [1, 2, 3]) {
      vk.song(10000, id);
    }
    final list = vk.made('Мой', [
      for (final id in [1, 2, 3]) vk.known['10000_$id']!,
    ]);
    final key = '10000_${list.id}';
    await moveInVkPlaylist(vk.call, key, '10000_3', beforeKey: '10000_1');
    expect(vk.keysOf(list), ['10000_3', '10000_1', '10000_2']);
    await moveInVkPlaylist(vk.call, key, '10000_3', afterKey: '10000_2');
    expect(vk.keysOf(list), ['10000_1', '10000_2', '10000_3']);
    expect(
      vk.calls.last,
      'audio.reorder playlist_id=${list.id} audio_id=3 after=2',
    );
    expect(
      () => moveInVkPlaylist(vk.call, key, '10000_3'),
      throwsArgumentError,
    );
  });

  test('rename keeps the songs; a followed copy refuses edits', () async {
    vk.song(10000, 1);
    final list = vk.made('Мой', [vk.known['10000_1']!]);
    await renameVkPlaylist(vk.call, '10000_${list.id}', 'Другой');
    expect(list.title, 'Другой');
    expect(vk.keysOf(list), ['10000_1']);
    final followed = vk.followed('Чужой', '555_3');
    final read = await fetchVkPlaylist(vk.call, '10000_${followed.id}');
    expect(read!.kind, VkPlaylistKind.followed);
    expect(read.editable, isFalse);
    expect(read.originalKey, '555_3');
    expect(read.originalAccessKey, 'ak-original');
    await expectLater(
      renameVkPlaylist(vk.call, '10000_${followed.id}', 'x'),
      throwsA(anything),
    );
  });

  test('delete removes the playlist', () async {
    final list = vk.made('Мой');
    await deleteVkPlaylist(vk.call, '10000_${list.id}');
    expect(vk.playlists, isEmpty);
    await expectLater(
      deleteVkPlaylist(vk.call, '10000_${list.id}'),
      throwsA(isA<VkEditRefused>()),
    );
  });

  test('already in: the same key, or the same recording within the length '
      'tolerance; no track id matches by key only', () {
    VkRecSong rec(String key, {int? trackId, int duration = 200}) {
      final [owner, id] = key.split('_');
      return vkRecSongOf(
        vkSongItem(
          int.parse(owner),
          int.parse(id),
          trackId: trackId,
          duration: duration,
        ),
      )!;
    }

    final songs = [rec('10000_1', trackId: 5), rec('10000_2')];
    expect(playlistHasSong(songs, '10000_1', null, 200), isTrue);
    expect(playlistHasSong(songs, '555_9', 5, 201), isTrue);
    expect(playlistHasSong(songs, '555_9', 5, 260), isFalse);
    expect(playlistHasSong(songs, '555_9', null, 200), isFalse);
    expect(playlistHasSong(songs, '555_9', 6, 200), isFalse);
  });
}
