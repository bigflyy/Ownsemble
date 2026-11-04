import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../vk/vk_album.dart';
import '../vk/vk_client.dart' show VkApiCall;
import '../vk/vk_sync.dart';

/// An album to open: its title and, for a VK album, its link.
///
/// Without a link (a song not synced since the link was stored, or a song
/// from the generator) the album is the library's songs with the same album
/// title and artist, and nothing is asked of VK.
@immutable
class AlbumRef {
  const AlbumRef({required this.title, this.artist, this.link});

  /// What the song row shows as the album.
  final String title;

  /// The artist of the song it was opened from: groups songs when there is no
  /// link, and is shown under the title.
  final String? artist;
  final VkAlbumLink? link;

  /// What makes two refs the same album. The access key may change between
  /// syncs, the album does not.
  String get identity => link?.key ?? '$title\n${artist ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is AlbumRef && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;
}

/// One song as the album's source lists it, and VK's id of its recording
/// (to find the library's copy of it).
typedef AlbumSong = ({Track track, int? vkTrackId});

/// Why an album's full song list could not be loaded, in words for the
/// heading. Never holds a link or a key.
class AlbumNotListed implements Exception {
  const AlbumNotListed(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Where the album view gets its songs: the library's at once, the source's
/// full list later.
abstract interface class AlbumCatalog {
  /// The album [track] is from, or null when it has none.
  AlbumRef? albumOf(Track track);

  /// Library ids of the album's songs the library has, in library order.
  List<int> libraryIds(AlbumRef album);

  /// The listed song of each VK track id the library has.
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds);

  /// Whether [fetch] has anything to ask (a VK link and a logged-in account).
  bool canFetch(AlbumRef album);

  /// The whole album from its source, in the album's order. Throws
  /// [AlbumNotListed] with a reason when it cannot be listed.
  Future<List<AlbumSong>> fetch(AlbumRef album);
}

/// The album catalog of the running app: the library database for the songs
/// at hand and the song's VK account for the whole album, read-only.
class LibraryAlbums implements AlbumCatalog {
  LibraryAlbums({required this.store, required this.apiOfSource});

  final LibraryStore store;

  /// Calls VK as a source's account; null when that account is not logged
  /// in.
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// Ids handed to album songs the library lacks, by "sourceId:ownerId_id",
  /// so the same song keeps its id while the app runs (the player marks the
  /// playing row by id).
  final _outsideIds = <String, int>{};

  /// The album each outside song was listed in, for its own album link.
  final _outsideAlbums = <int, AlbumRef>{};

  @override
  AlbumRef? albumOf(Track track) {
    final title = track.album;
    if (title == null || title.isEmpty) return null;
    if (!track.inLibrary) return _outsideAlbums[track.id];
    return AlbumRef(
      title: title,
      artist: track.artist,
      link: track.source == TrackSource.vk ? store.vkAlbumOf(track.id) : null,
    );
  }

  @override
  List<int> libraryIds(AlbumRef album) => switch (album.link) {
    final link? => store.listedIdsInVkAlbum(link.key),
    null => store.listedIdsWithAlbum(album.title, album.artist ?? ''),
  };

  @override
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds) =>
      store.listedIdsByVkTrackId(vkTrackIds);

  @override
  bool canFetch(AlbumRef album) =>
      album.link != null && apiOfSource(album.link!.sourceId) != null;

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) async {
    final link = album.link;
    if (link == null) {
      throw const AlbumNotListed('only your songs: no VK link to the album');
    }
    final call = apiOfSource(link.sourceId);
    if (call == null) {
      throw const AlbumNotListed(
        'only your songs: log in to the account it came from',
      );
    }
    final List<Map<String, dynamic>> items;
    try {
      items = await fetchVkAlbumItems(
        call,
        link.key,
        accessKey: link.accessKey,
      );
    } catch (error) {
      // The sync's wording, with any link in a message taken out.
      throw AlbumNotListed(
        'VK did not list the album: ${describeSyncError(error)}',
      );
    }
    return [
      for (final item in items)
        _outsideSong(vkItemToTrack(item), album, link.sourceId),
    ];
  }

  /// [song] as a song outside the library, streamed through the account of
  /// [sourceId]. Its album is shown as [album]'s title: VK names some albums
  /// "unnamed" on their songs.
  AlbumSong _outsideSong(NewTrack song, AlbumRef album, int sourceId) {
    final id = _outsideIds.putIfAbsent(
      '$sourceId:${song.sourceKey}',
      () => -(_outsideIds.length + 1),
    );
    _outsideAlbums[id] = album;
    return (
      track: Track(
        id: id,
        sourceId: sourceId,
        source: TrackSource.vk,
        artist: song.artist,
        title: song.title,
        album: album.title,
        durationSec: song.durationSec,
        sourceKey: song.sourceKey,
        accessKey: song.accessKey,
        coverUrl: song.coverUrl,
        coverLargeUrl: song.coverLargeUrl,
        coverMidUrl: song.coverMidUrl,
        coverFullUrl: song.coverFullUrl,
        tint: song.tint,
      ),
      vkTrackId: song.vkTrackId,
    );
  }
}
