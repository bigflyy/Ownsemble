import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_sync.dart';

/// Fake `audio.get` over [total] songs where the ids in [blocked] are counted
/// but never returned, as VK does.
Future<Object?> Function(String, Map<String, String>) fakeAudioGet(
  int total,
  Set<int> blocked,
  List<int> offsetsSeen,
) {
  return (method, params) async {
    expect(method, 'audio.get');
    final offset = int.parse(params['offset']!);
    final count = int.parse(params['count']!);
    offsetsSeen.add(offset);
    return {
      'count': total,
      'items': [
        for (var id = offset; id < offset + count && id < total; id++)
          if (!blocked.contains(id))
            {'owner_id': 5, 'id': id, 'artist': 'A', 'title': 'T $id'},
      ],
    };
  };
}

void main() {
  test(
    'offset advances by page size even when pages omit blocked songs',
    () async {
      final offsets = <int>[];
      final library = await fetchVkLibrary(
        fakeAudioGet(126, {3, 60, 125}, offsets),
        5,
        pageSize: 50,
      );
      expect(offsets, [0, 50, 100]);
      expect(library.pages, 3);
      expect(library.declaredCount, 126);
      expect(library.items.length, 123);
      expect(library.items.map(vkSourceKey).toSet().length, 123);
    },
  );

  test('a page made only of blocked songs does not stop the sync', () async {
    final offsets = <int>[];
    final library = await fetchVkLibrary(
      fakeAudioGet(30, {for (var i = 10; i < 20; i++) i}, offsets),
      5,
      pageSize: 10,
    );
    expect(offsets, [0, 10, 20]);
    expect(library.items.length, 20);
  });

  test('an empty library takes one request', () async {
    final offsets = <int>[];
    final library = await fetchVkLibrary(fakeAudioGet(0, {}, offsets), 5);
    expect(offsets, [0]);
    expect(library.items, isEmpty);
  });

  test('VK items become library songs with trimmed Cyrillic text', () {
    final track = vkItemToTrack({
      'owner_id': -2001,
      'id': 77,
      'access_key': 'k',
      'artist': ' Сплин ',
      'title': 'Выхода нет ',
      'duration': 236,
      'date': 1700000000,
      'album': {'title': 'Альбом'},
    });
    expect(track.sourceKey, '-2001_77');
    expect(track.accessKey, 'k');
    expect(track.artist, 'Сплин');
    expect(track.title, 'Выхода нет');
    expect(track.album, 'Альбом');
    expect(track.durationSec, 236);
    expect(track.coverUrl, isNull);
  });

  test('covers come from the song thumb, else from the album', () {
    Map<String, String> thumb(String name) => {
      'photo_34': '$name-34',
      'photo_135': '$name-135',
      'photo_600': '$name-600',
      'photo_1200': '$name-1200',
    };
    final own = vkItemToTrack({
      'owner_id': 1,
      'id': 1,
      'thumb': thumb('song'),
      'album': {'title': 'Альбом', 'thumb': thumb('album')},
      'main_color': '#1a2B3c',
    });
    expect(own.coverUrl, 'song-135');
    expect(own.coverLargeUrl, 'song-600');
    expect(own.tint, 0xFF1A2B3C);

    final albumOnly = vkItemToTrack({
      'owner_id': 1,
      'id': 2,
      'album': {'title': 'Альбом', 'thumb': thumb('album')},
    });
    expect(albumOnly.coverUrl, 'album-135');
    expect(albumOnly.tint, isNull);
  });

  test('odd main colors are ignored', () {
    expect(parseVkColor('#fff'), isNull);
    expect(parseVkColor('зелёный'), isNull);
    expect(parseVkColor(12), isNull);
    expect(parseVkColor('ff0000'), 0xFFFF0000);
  });
}
