// The recommendation calls (plan 07, C1) on the replies real VK gave the
// test account: the music page's lists and "Similar to" shelves, a list's
// songs, VK Mix, similar songs, restricted songs and the dislike.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';

import 'recs_support.dart';

/// Every top-level field name of every song in the recorded replies.
Set<String> _recordedSongFields() {
  final fields = <String>{};
  void addAll(Object? songs) {
    for (final song in songs as List? ?? const []) {
      fields.addAll((song as Map).keys.cast<String>());
    }
  }

  addAll((recFixture('catalog_get_audio') as Map)['audios']);
  addAll((recFixture('audio_get_generated_playlist') as Map)['items']);
  addAll(recFixture('audio_get_stream_mix_audios'));
  addAll((recFixture('audio_get_recommendations') as Map)['items']);
  addAll(recFixture('audio_get_by_id_restricted_2'));
  return fields;
}

void main() {
  test('the fake songs use only fields real VK songs carry', () {
    final recorded = _recordedSongFields();
    final fake = {
      ...recSong(1, 2, trackId: 3).keys,
      ...recSong(1, 2, restricted: 2).keys,
    };
    expect(recorded, containsAll(fake));
    // And the fields the reader needs are really there.
    expect(
      recorded,
      containsAll([
        'id',
        'owner_id',
        'artist',
        'title',
        'duration',
        'url',
        'access_key',
        'track_id',
        'content_restricted',
        'album',
        'date',
      ]),
    );
  });

  test('a restricted song in a recording has no link and its code', () {
    final item = (recFixture('audio_get_by_id_restricted_2') as List).first;
    final song = vkRecSongOf(item)!;
    expect(song.restricted, 2);
    expect(song.playable, isFalse);
    expect(vkRestrictionLabel(2), 'Not in your region');
    expect(vkRestrictionLabel(3), 'Subscription only');
    expect(vkRestrictionLabel(1), 'Unavailable on VK');
    final made = vkRecSongOf(recSong(1, 2, restricted: 3))!;
    expect(made.restricted, 3);
    expect(vkRecSongOf(recSong(1, 2))!.playable, isTrue);
  });

  group('the music page', () {
    final page = parseVkMusicPage(
      recFixture('catalog_get_audio'),
      me: recFixtureMe,
    );

    test('lists the seven lists VK made, with English names', () {
      expect(page.lists.map((l) => l.title), [
        'For you',
        'Discoveries',
        'New releases',
        'Daily playlist 1',
        'Daily playlist 2',
        'Daily playlist 3',
        'Daily playlist 4',
      ]);
      final forYou = page.lists.first;
      expect(forYou.kind, VkListKind.forYou);
      expect(forYou.vkTitle, 'Для вас');
      expect(forYou.key, '${recFixtureMe}_-21');
      expect(forYou.accessKey, startsWith('opaque-'));
      expect(forYou.updateTime, 1794846702);
      expect(forYou.coverUrl, startsWith('https://example.invalid/'));
      expect(forYou.subtitle, contains('and others'));
      expect(page.lists[3].kind, VkListKind.daily);
      expect(page.lists[3].subtitle, startsWith('You listened to '));
      expect(page.lists[1].subtitle, 'In your taste');
    });

    test('reads the "Similar to" shelf with its songs in Cyrillic', () {
      expect(page.similar, hasLength(1));
      final shelf = page.similar.single;
      expect(shelf.title, 'Similar to Пой же, пой (Lemium)');
      expect(shelf.songs, hasLength(18));
      expect(shelf.songs.first.song.artist, isNotEmpty);
      expect(shelf.blockId, isNotNull);
      expect(shelf.nextFrom, isNotNull);
      expect(page.hasMix, isTrue);
    });

    test('keeps nothing of another owner and survives an odd reply', () {
      expect(
        parseVkMusicPage(recFixture('catalog_get_audio'), me: 1).lists,
        isEmpty,
      );
      final odd = parseVkMusicPage('nonsense', me: 1);
      expect(odd.lists, isEmpty);
      expect(odd.similar, isEmpty);
    });

    test('a list round-trips through its cache form', () {
      final list = page.lists[4];
      final back = VkRecList.fromJson(list.toJson());
      expect(back.toJson(), list.toJson());
    });
  });

  test(
    'a list\'s songs come from audio.get with its owner, id and key',
    () async {
      final vk = RecsVk();
      final page = await fetchVkMusicPage(vk.call, me: recFixtureMe);
      final songs = await fetchVkListSongs(vk.call, page.lists.first);
      expect(songs, hasLength(12));
      expect(
        vk.calls.last,
        allOf(
          contains('owner_id=$recFixtureMe'),
          contains('album_id=-21'),
          contains('access_key=opaque-'),
        ),
      );
      expect(songs.first.song.artist, 'Кино');
      expect(songs.first.song.title, 'Закрой за мной дверь');
    },
  );

  test('VK Mix gives the new songs of each call', () async {
    final vk = RecsVk();
    final songs = await fetchVkMixSongs(vk.call);
    expect(songs, hasLength(3));
    expect(vk.calls.single, contains('mix_id=common'));
  });

  test('a shelf continues from its next_from', () async {
    final vk = RecsVk();
    final page = await fetchVkMusicPage(vk.call, me: recFixtureMe);
    final shelf = page.similar.single;
    final more = await fetchVkShelfMore(vk.call, shelf);
    expect(more.songs.length, greaterThan(shelf.songs.length));
    expect(vk.calls.last, contains('start_from=${shelf.nextFrom}'));
  });

  group('similar songs', () {
    test('of a found song: 30 songs by its key', () async {
      final vk = RecsVk();
      // The recorded file keeps 12 of the 30.
      final songs = await fetchVkSimilarSongs(vk.call, '5_6');
      expect(songs, hasLength(12));
      expect(vk.calls.single, contains('target_audio=5_6'));
    });

    test('of an upload with no track id: VK gives none', () async {
      final vk = RecsVk(
        overrides: {
          'audio.getRecommendations': (_) =>
              recFixture('audio_get_recommendations_target_no_track_id'),
        },
      );
      expect(await fetchVkSimilarSongs(vk.call, '5_6'), isEmpty);
    });

    test('a song with a track id stands for itself', () async {
      final vk = RecsVk();
      final target = await similarTargetOf(
        vk.call,
        artist: 'a',
        title: 'b',
        sourceKey: '5_6',
        hasTrackId: true,
      );
      expect(target, '5_6');
      expect(vk.calls, isEmpty);
    });

    test(
      'an upload with no track id takes a same-name copy that has one',
      () async {
        final vk = RecsVk(
          overrides: {
            'audio.search': (_) => {
              'count': 3,
              'items': [
                recSong(7, 1, artist: 'Кино', title: 'Звезда'),
                recSong(7, 2, artist: 'Кино', title: 'Другая', trackId: 9),
                recSong(7, 3, artist: 'КИНО', title: 'звезда ', trackId: 8),
              ],
            },
          },
        );
        final target = await similarTargetOf(
          vk.call,
          artist: 'Кино',
          title: 'Звезда',
          sourceKey: '5_6',
        );
        expect(target, '7_3');
      },
    );

    test('no same-name copy with a track id: none', () async {
      final vk = RecsVk(
        overrides: {
          'audio.search': (_) => {
            'count': 1,
            'items': [recSong(7, 1, artist: 'Кино', title: 'Звезда')],
          },
        },
      );
      expect(
        await similarTargetOf(vk.call, artist: 'Кино', title: 'Звезда'),
        isNull,
      );
    });
  });

  test('a dislike and its undo name the song', () async {
    final vk = RecsVk();
    await dislikeVkSong(vk.call, '5_6');
    await undislikeVkSong(vk.call, '5_6');
    expect(vk.calls, [
      'audio.addDislike audio_ids=5_6',
      'audio.removeDislike audio_ids=5_6',
    ]);
  });
}
