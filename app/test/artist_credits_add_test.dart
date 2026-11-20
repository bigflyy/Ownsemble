// Tests for plan 09 C1b (Codex review R3): the artists VK names on a song
// travel with it through every place that shows a VK song outside the
// library (search, VK lists, albums, other uploads, the For you cache), so
// + stores them on the added row at once, before any sync.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/ui/for_you_page.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';
import 'package:ownsemble/vk/vk_sync.dart';
import 'package:ownsemble/vk/vk_versions.dart';

import 'catalog_support.dart';

/// The two artists of a song by two main artists and a featured one, in
/// VK's shape (real field names, made-up ids).
const _mainArtists = [
  {'id': '1001', 'name': 'Дайте танк (!)', 'domain': 'daitetank'},
  {'id': '1002', 'name': 'Кис-кис', 'domain': 'kiskis'},
];
const _featuredArtists = [
  {'id': '1003', 'name': 'Аигел'},
];

const _expected = [
  ArtistCredit(vkId: '1001', name: 'Дайте танк (!)', domain: 'daitetank'),
  ArtistCredit(vkId: '1002', name: 'Кис-кис', domain: 'kiskis'),
  ArtistCredit(vkId: '1003', name: 'Аигел', featured: true),
];

/// [item] with the artists above.
Map<String, dynamic> _credited(Map<String, dynamic> item) => {
  ...item,
  'artist': 'Дайте танк (!), Кис-кис feat. Аигел',
  'main_artists': _mainArtists,
  'featured_artists': _featuredArtists,
};

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    vk = FakeVk(42);
    library = LibraryController(store.loadAll());
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: ValueNotifier(store.sources()),
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
      reloadAfter: const Duration(milliseconds: 10),
    );
  });

  tearDown(() {
    catalog.dispose();
    library.dispose();
    store.close();
  });

  /// Adds [found] and returns the credits stored on the account's new copy.
  Future<List<ArtistCredit>> addAndRead(FoundSong found) async {
    expect(await catalog.add(found), startsWith('Added'));
    final added = store.loadAll().singleWhere(
      (track) => track.sourceKey!.startsWith('42_'),
    );
    return store.artistCredits()[added.id] ?? const [];
  }

  test('a song found by search keeps its artists when added', () async {
    final found = FoundSong(
      song: vkItemToTrack(_credited(vkAudio(-7, 1))),
      track: const Track(
        id: -2000000001,
        sourceId: 0,
        source: TrackSource.vk,
        artist: '',
        title: '',
        durationSec: 225,
        sourceKey: '-7_1',
        accessKey: 'key1',
      ),
    );
    expect(await addAndRead(found), _expected);
  });

  test("a VK list's song (For you, playlists, an artist's Popular) keeps "
      'its artists when added', () async {
    final outside = OutsideSongs(libraryCopyOfSong: (_) => null);
    final rec = VkRecSong(vkItemToTrack(_credited(vkAudio(-7, 2))));
    final track = outside.trackOf(rec, source);
    expect(track.artists, _expected);
    final found = recFoundSong(outside, catalog, track)!;
    expect(found.song.artists, _expected);
    expect(await addAndRead(found), _expected);
  });

  test(
    "an album's song the library lacks keeps its artists when added",
    () async {
      Future<Object?> call(String method, Map<String, String> params) async =>
          method == 'audio.get'
          ? jsonDecode(
              jsonEncode({
                'count': 1,
                'items': [_credited(vkAudio(-5, 3))],
              }),
            )
          : vk.call(method, params);
      final albums = LibraryAlbums(store: store, apiOfSource: (_) => call);
      final songs = await albums.fetch(
        AlbumRef(
          title: 'Человеко-часы',
          link: (sourceId: source, key: '-5_9', accessKey: null),
        ),
      );
      final track = songs.single.track;
      expect(track.artists, _expected);
      expect(await addAndRead(catalog.outsideSong(track)), _expected);
    },
  );

  test('another upload in Versions keeps its artists when added', () async {
    final version = versionFromItem(_credited(vkAudio(-7, 4)));
    expect(version.artists, _expected);
    final book = VersionBook(
      store: store,
      find: (track, route, progress) async => const [],
      measure: (route) async => null,
    );
    const row = Track(
      id: 1,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Дайте танк (!)',
      title: 'Звезда по имени Солнце',
      durationSec: 225,
      sourceKey: '42_1',
    );
    final track = book.versionTrack(row, version);
    expect(track.artists, _expected);
    expect(await addAndRead(catalog.outsideSong(track)), _expected);
  });

  test("the For you cache keeps a song's artists (Cyrillic round trip)", () {
    final rec = VkRecSong(vkItemToTrack(_credited(vkAudio(-7, 5))));
    final json = jsonDecode(jsonEncode(recSongToJson(rec)));
    final back = recSongFromJson(json as Map<String, dynamic>);
    expect(back.song.artists, _expected);
    // An old cache file has no artists: none, no error.
    final old = Map<String, dynamic>.of(json)..remove('artists');
    expect(recSongFromJson(old).song.artists, isEmpty);
  });

  test("a song's own cover swap keeps its artists", () {
    const track = Track(
      id: -5,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Дайте танк (!), Кис-кис feat. Аигел',
      title: 'Люди',
      durationSec: 180,
      artists: _expected,
    );
    expect(track.withCoversOf(track).artists, _expected);
  });
}
