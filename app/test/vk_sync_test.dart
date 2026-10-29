import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
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
    expect(track.source, TrackSource.vk);
    expect(track.sourceKey, '-2001_77');
    expect(track.accessKey, 'k');
    expect(track.artist, 'Сплин');
    expect(track.title, 'Выхода нет');
    expect(track.album, 'Альбом');
    expect(track.durationSec, 236);
  });
}
