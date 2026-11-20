/// VK's artist pages and artist photos (plan 09, C3), read-only.
///
/// Probes of 2026-11-20 (tool/probe_artists.dart, probe_artist_photos.dart,
/// probe_artist_square_photos.dart on the test account):
/// - `catalog.getAudioArtist {artist_id, need_blocks: 1}` is the whole page
///   in one reply (1.3-2.3 s): the artist, then blocks in VK's order: a
///   banner, Popular (30 songs + next_from), Releases, Appears on, In
///   playlists, Official pages, Music videos, You may like. `artist_id`
///   takes the address name (domain) too.
/// - The page's own photo is a wide banner (795x200, 1510x344), not a
///   square: the round tiles take the artist photo of `audio.searchArtists`
///   (270x270), found by id among the search's answers for the name. 25
///   searches in one `execute`: 6.1 s, 24 of 25 found.
/// - Block titles are in the account's language, so blocks are told apart
///   by what they hold, never by title.
library;

import 'dart:convert';

import '../library/artist_credit.dart';
import 'vk_client.dart';
import 'vk_recommendations.dart';

/// An image VK gives in several sizes, as `[{url, width, height}]`: the
/// smallest at least [min] px wide, else the biggest; null for none. With
/// [square], only sizes about as tall as wide count (VK lists an artist's
/// photo as 270x200 and 270x270).
String? vkImageUrl(Object? sizes, {required int min, bool square = false}) {
  if (sizes is! List) return null;
  final usable = [
    for (final size in sizes)
      if (size case {'url': final String url, 'width': final int width}
          when url.isNotEmpty && (!square || _squarish(width, size['height'])))
        (url: url, width: width),
  ]..sort((a, b) => a.width.compareTo(b.width));
  if (usable.isEmpty) return null;
  for (final size in usable) {
    if (size.width >= min) return size.url;
  }
  return usable.last.url;
}

/// One release of the artist on VK (an album, an EP or a single).
class VkArtistRelease {
  const VkArtistRelease({
    required this.key,
    required this.title,
    required this.count,
    this.accessKey,
    this.year,
    this.coverUrl,
    this.artists = const [],
  });

  /// "ownerId_id", as the album place opens a VK album.
  final String key;
  final String? accessKey;
  final String title;

  /// The song count VK states: 1 is a single.
  final int count;
  final int? year;

  /// The cover, about 300 px.
  final String? coverUrl;

  /// The release's main artists.
  final List<ArtistCredit> artists;

  bool get single => count == 1;
}

/// An artist VK suggests on a page ("You may like"): opened by its address
/// name, the last part of its link (`/artist/<domain>`).
class VkSimilarArtist {
  const VkSimilarArtist({required this.name, this.domain, this.photoUrl});

  final String name;

  /// Null when the link is not an artist page's.
  final String? domain;

  /// A square photo, about 270 px.
  final String? photoUrl;
}

/// A block of songs VK pages on with `catalog.getBlockItems`.
class VkSongBlock {
  const VkSongBlock({required this.songs, this.blockId, this.nextFrom});

  final List<VkRecSong> songs;

  /// The block and the mark its next page starts from; null when VK gives
  /// no next page.
  final String? blockId;
  final String? nextFrom;

  bool get hasMore => blockId != null && nextFrom != null;
}

/// VK's page of one artist, as the artist page shows it.
class VkArtistPage {
  const VkArtistPage({
    required this.id,
    required this.name,
    required this.popular,
    required this.releases,
    required this.similar,
    this.domain,
    this.bannerUrl,
    this.popularTotal,
  });

  /// VK's artist id: the page asked by address name says whose it is.
  final String id;
  final String name;
  final String? domain;

  /// The wide header photo, about 800 px wide.
  final String? bannerUrl;

  /// The first page of Popular, in VK's order.
  final VkSongBlock popular;

  /// How many songs VK says Popular has ("Show all" count); null when it
  /// does not say.
  final int? popularTotal;

  /// The Releases block's releases, in its order.
  final List<VkArtistRelease> releases;
  final List<VkSimilarArtist> similar;
}

/// The page [reply] of `catalog.getAudioArtist` holds; null when it names
/// no artist.
VkArtistPage? vkArtistPageOf(Object? reply) {
  if (reply is! Map<String, dynamic>) return null;
  final artists = reply['artists'];
  if (artists is! List || artists.isEmpty || artists.first is! Map) {
    return null;
  }
  final artist = artists.first as Map;
  final id = '${artist['id'] ?? ''}';
  final name = '${artist['name'] ?? ''}'.trim();
  if (id.isEmpty || name.isEmpty) return null;

  final songs = <String, VkRecSong>{};
  for (final item in reply['audios'] as List? ?? const []) {
    final song = vkRecSongOf(item);
    if (song != null) songs[song.key] = song;
  }
  final playlists = <String, Map<String, dynamic>>{};
  for (final item in reply['playlists'] as List? ?? const []) {
    if (item case {'owner_id': final int owner, 'id': final int id}
        when item is Map<String, dynamic>) {
      playlists['${owner}_$id'] = item;
    }
  }
  final links = <String, Map>{};
  for (final item in reply['links'] as List? ?? const []) {
    if (item case final Map link when link['id'] is String) {
      links[link['id'] as String] = link;
    }
  }

  final blocks = switch (reply['catalog']) {
    {'sections': [{'blocks': final List blocks}, ...]} => blocks,
    _ => const [],
  };
  VkSongBlock? popular;
  int? popularTotal;
  List<VkArtistRelease>? releases;
  List<VkSimilarArtist>? similar;
  for (final block in blocks.whereType<Map>()) {
    switch (block['data_type']) {
      // Popular: the first block of songs.
      case 'music_audios' when popular == null:
        popular = VkSongBlock(
          songs: [
            for (final key in block['audios_ids'] as List? ?? const [])
              ?songs['$key'],
          ],
          blockId: block['id'] as String?,
          nextFrom: _nonEmpty(block['next_from']),
        );
      // Releases: the first block of playlists that are albums of this
      // artist (Appears on holds other artists' albums, In playlists the
      // users' lists), in the block's order (R11).
      case 'music_playlists' when releases == null:
        final own = [
          for (final key in block['playlists_ids'] as List? ?? const [])
            if (playlists['$key'] case final item? when _isReleaseOf(item, id))
              _releaseOf(item),
        ];
        if (own.isNotEmpty) releases = own;
      // You may like: the block of links to artist pages.
      case 'links' when similar == null:
        final artistsHere = [
          for (final key in block['links_ids'] as List? ?? const [])
            if (links['$key'] case final link?
                when (link['meta'] as Map?)?['content_type'] == 'artist')
              VkSimilarArtist(
                name: '${link['title'] ?? ''}'.trim(),
                domain: artistDomainOfLink(link['url']),
                photoUrl: vkImageUrl(link['image'], min: 240, square: true),
              ),
        ].where((artist) => artist.name.isNotEmpty).toList();
        if (artistsHere.isNotEmpty) similar = artistsHere;
    }
  }
  // The "Show all" count of Popular, on the header block's action.
  for (final block in blocks.whereType<Map>()) {
    for (final action in block['actions'] as List? ?? const []) {
      if (action case {
        'ref_data_type': 'music_audios',
        'ref_items_count': final int count,
      }) {
        popularTotal ??= count;
      }
    }
  }
  final domain = artist['domain'];
  return VkArtistPage(
    id: id,
    name: name,
    domain: domain is String && domain.isNotEmpty ? domain : null,
    bannerUrl: vkImageUrl(artist['photo'], min: 700),
    popular: popular ?? const VkSongBlock(songs: []),
    popularTotal: popularTotal,
    releases: releases ?? const [],
    similar: similar ?? const [],
  );
}

/// Whether a [width] x [height] image is square within 5% (266x270 is).
bool _squarish(int width, Object? height) =>
    height is int && (width - height).abs() * 20 <= width;

String? _nonEmpty(Object? text) =>
    text is String && text.isNotEmpty ? text : null;

bool _isReleaseOf(Map<String, dynamic> item, String artistId) =>
    item['type'] == 'album' &&
    (item['main_artists'] as List? ?? const []).any(
      (artist) => artist is Map && '${artist['id']}' == artistId,
    );

VkArtistRelease _releaseOf(Map<String, dynamic> item) {
  final photo = item['photo'];
  final year = item['year'];
  final count = item['count'];
  return VkArtistRelease(
    key: '${item['owner_id']}_${item['id']}',
    accessKey: _nonEmpty(item['access_key']),
    title: '${item['title'] ?? ''}',
    count: count is int ? count : 0,
    year: year is int && year > 0 ? year : null,
    coverUrl: photo is Map
        ? (photo['photo_300'] ?? photo['photo_270']) as String?
        : null,
    artists: vkArtistCredits({'main_artists': item['main_artists']}),
  );
}

/// The address name in a link to an artist page (`.../artist/<domain>`,
/// any host, with or without a query); null for any other link.
String? artistDomainOfLink(Object? url) {
  if (url is! String) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final parts = uri.pathSegments;
  final at = parts.indexOf('artist');
  if (at < 0 || at + 1 >= parts.length) return null;
  final domain = parts[at + 1];
  return domain.isEmpty ? null : domain;
}

/// VK's page of the artist [idOrDomain] (its id or address name). One retry
/// on error 10 ("could not check access_token now", seen once in A2).
/// Null when VK gives no artist.
Future<VkArtistPage?> fetchVkArtistPage(
  VkApiCall call,
  String idOrDomain,
) async {
  final params = {'artist_id': idOrDomain, 'need_blocks': '1'};
  Object? reply;
  try {
    reply = await call('catalog.getAudioArtist', params);
  } on VkException catch (error) {
    if (error.code != 10) rethrow;
    reply = await call('catalog.getAudioArtist', params);
  }
  return vkArtistPageOf(reply);
}

/// The next page of [block] (about 20 songs, 0.3-1.0 s), with songs it
/// already has left out; when a page brings nothing new, paging stops, so a
/// mark VK repeats cannot loop (R7).
Future<VkSongBlock> fetchVkBlockMore(VkApiCall call, VkSongBlock block) async {
  final blockId = block.blockId;
  final nextFrom = block.nextFrom;
  if (blockId == null || nextFrom == null) return block;
  final reply = await call('catalog.getBlockItems', {
    'block_id': blockId,
    'start_from': nextFrom,
  });
  if (reply is! Map<String, dynamic>) {
    return VkSongBlock(songs: block.songs);
  }
  final songs = <String, VkRecSong>{};
  for (final item in reply['audios'] as List? ?? const []) {
    final song = vkRecSongOf(item);
    if (song != null) songs[song.key] = song;
  }
  final ids = switch (reply['block']) {
    {'audios_ids': final List ids} => ids,
    _ => [for (final song in songs.values) song.key],
  };
  final known = {for (final song in block.songs) song.key};
  final added = [
    for (final id in ids)
      if (songs['$id'] case final song? when known.add(song.key)) song,
  ];
  final next = switch (reply['block']) {
    {'next_from': final String next} when next.isNotEmpty => next,
    _ => null,
  };
  return VkSongBlock(
    songs: [...block.songs, ...added],
    blockId: blockId,
    nextFrom: added.isEmpty || next == nextFrom ? null : next,
  );
}

/// What one artist's photo lookup gave.
sealed class VkArtistPhoto {
  const VkArtistPhoto();
}

/// The artist's square photo, small (about 135 px) and large (about 270).
class VkArtistPhotoFound extends VkArtistPhoto {
  const VkArtistPhotoFound({required this.small, required this.large});

  final String small;
  final String large;
}

/// The search answered, and the artist has no photo there (or was not
/// among its answers): the tile keeps its letters.
class VkArtistPhotoMissing extends VkArtistPhoto {
  const VkArtistPhotoMissing();
}

/// How many artists one photo request asks for: VK runs up to 25 calls in
/// one `execute`; 25 searches took 6.1 s.
const artistPhotoBatch = 25;

/// The photos of [artists] ({id, name}, at most [artistPhotoBatch]) in one
/// request: VK's artist search for each name, its answer with the same id.
/// An artist whose own search failed inside the batch is left out of the
/// result, so it is asked again later and never marked missing (R2).
Future<Map<String, VkArtistPhoto>> fetchVkArtistPhotos(
  VkApiCall call,
  List<({String id, String name})> artists,
) async {
  if (artists.isEmpty) return const {};
  if (artists.length > artistPhotoBatch) {
    throw ArgumentError.value(artists.length, 'artists', 'more than 25');
  }
  final code = StringBuffer('var r = [];');
  for (final artist in artists) {
    // A JSON string is a valid VKScript string literal.
    code.write(
      'r.push(API.audio.searchArtists({"q": ${jsonEncode(artist.name)}, '
      '"count": 10}).items);',
    );
  }
  code.write('return r;');
  final reply = await call('execute', {'code': '$code'});
  if (reply is! List) return const {};
  return vkArtistPhotosOf(artists, reply);
}

/// The photos in [reply], the list an [fetchVkArtistPhotos] batch returns:
/// one entry per artist, a list of found artists or `false` for a search
/// that failed.
Map<String, VkArtistPhoto> vkArtistPhotosOf(
  List<({String id, String name})> artists,
  List reply,
) {
  final photos = <String, VkArtistPhoto>{};
  for (final (index, artist) in artists.indexed) {
    if (index >= reply.length) break;
    final items = reply[index];
    if (items is! List) continue;
    final same = items.whereType<Map>().where(
      (item) => '${item['id']}' == artist.id,
    );
    final sizes = same.isEmpty ? null : same.first['photo'];
    final large = vkImageUrl(sizes, min: 240, square: true);
    photos[artist.id] = large == null
        ? const VkArtistPhotoMissing()
        : VkArtistPhotoFound(
            small: vkImageUrl(sizes, min: 120, square: true) ?? large,
            large: large,
          );
  }
  return photos;
}

/// [photos] as LibraryStore.saveArtistPhotos takes them: links, or null
/// for an artist VK has no photo for.
Map<String, ({String small, String large})?> photosToStore(
  Map<String, VkArtistPhoto> photos,
) => {
  for (final MapEntry(key: id, value: photo) in photos.entries)
    id: switch (photo) {
      VkArtistPhotoFound(:final small, :final large) => (
        small: small,
        large: large,
      ),
      VkArtistPhotoMissing() => null,
    },
};
