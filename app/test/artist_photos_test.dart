// Tests for plan 09 C3: the stored photos of VK artists and which artists
// the Artists place still asks VK about.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_artists.dart';

const day = 24 * 3600 * 1000;

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.open(':memory:'));
  tearDown(() => store.close());

  test('a lookup stores links, or that VK has no photo; a failed one '
      'keeps what was there', () {
    store.saveArtistPhotos(
      photosToStore({
        '1': const VkArtistPhotoFound(small: 's1.jpg', large: 'l1.jpg'),
        '2': const VkArtistPhotoMissing(),
      }),
      atMs: 1000,
    );
    expect(store.artistPhotos(), {
      '1': (small: 's1.jpg', large: 'l1.jpg', fetchedAtMs: 1000),
      '2': (small: null, large: null, fetchedAtMs: 1000),
    });
    // Asked again later: '2' has a photo now; '1' failed, so not in the map.
    store.saveArtistPhotos(
      photosToStore({
        '2': const VkArtistPhotoFound(small: 's2.jpg', large: 'l2.jpg'),
      }),
      atMs: 5000,
    );
    expect(store.artistPhotos()['1']!.fetchedAtMs, 1000);
    expect(store.artistPhotos()['2'], (
      small: 's2.jpg',
      large: 'l2.jpg',
      fetchedAtMs: 5000,
    ));
  });

  test('artists wanting a photo: in the given order, never asked or read '
      '30 days ago, name-only ones skipped, at most the limit', () {
    var id = 0;
    Track song(String artist) => Track(
      id: ++id,
      sourceId: 1,
      source: TrackSource.vk,
      artist: artist,
      title: 'Песня',
      durationSec: 200,
    );
    final songs = [song('A'), song('B'), song('C'), song('D'), song('Без id')];
    final index = ArtistIndex.build(songs, {
      for (final (i, s) in songs.take(4).indexed)
        s.id: [ArtistCredit(vkId: '${i + 1}', name: s.artist)],
    });
    final order = index.sorted(ArtistSort.name);
    expect(order.last.nameOnly, isTrue);
    const now = 100 * day;
    final stored = {
      '1': (small: 'a.jpg', large: 'a.jpg', fetchedAtMs: now - 2 * day),
      '2': (small: null, large: null, fetchedAtMs: now - 31 * day),
      '3': (small: null, large: null, fetchedAtMs: now - day),
    };
    List<String> wanted({int? limit}) => [
      for (final artist in artistsWantingPhotos(
        order,
        stored,
        nowMs: now,
        lifetime: LibraryStore.artistPhotoLifetime,
        limit: limit,
      ))
        artist.vkId!,
    ];
    expect(wanted(), ['2', '4']);
    expect(wanted(limit: 1), ['2']);
  });
}
