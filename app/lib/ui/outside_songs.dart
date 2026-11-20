/// Songs from VK's lists that are not in the library (plan 08, B1): VK's
/// recommended lists (plan 07) and the account's playlists share one
/// registry, so a song keeps one id in both, and +, the greyed tag of songs
/// VK gives no file for, the album link and playback work the same in each.
library;

import '../library/library_store.dart';
import '../library/track.dart';
import '../vk/vk_recommendations.dart';
import 'albums.dart';

/// Ids of outside list songs start here and go down, below the album songs
/// (-1, -2, ...) and versions (-1e9 - n), above found songs (-2e9 - n).
const firstOutsideListId = -1500000000;

/// The songs of VK lists that the library lacks, as tracks with ids that
/// stay while the app runs (the player marks the playing row by id).
class OutsideSongs {
  OutsideSongs({required this.libraryCopyOfSong});

  /// The library's song that a VK song is (same key, the same VK
  /// recording, or the same name and length), or null.
  final Track? Function(NewTrack song) libraryCopyOfSong;

  final _ids = <String, int>{};
  final _byId = <int, VkRecSong>{};
  final _sourceOfId = <int, int>{};
  final _recommended = <int>{};

  /// [song] as a track streamed through the account of [sourceId]. The same
  /// song of the same account keeps its id. [recommended] marks a song VK
  /// recommended (the thumb-down is offered for those only); a song seen in
  /// a playlist too stays marked.
  Track trackOf(VkRecSong song, int sourceId, {bool recommended = false}) {
    final id = _ids.putIfAbsent(
      '$sourceId:${song.key}',
      () => firstOutsideListId - _ids.length,
    );
    _byId[id] = song;
    _sourceOfId[id] = sourceId;
    if (recommended) _recommended.add(id);
    final s = song.song;
    return Track(
      id: id,
      sourceId: sourceId,
      source: TrackSource.vk,
      artist: s.artist,
      title: s.title,
      album: s.album,
      durationSec: s.durationSec,
      sourceKey: s.sourceKey,
      accessKey: s.accessKey,
      coverUrl: s.coverUrl,
      coverLargeUrl: s.coverLargeUrl,
      coverMidUrl: s.coverMidUrl,
      coverFullUrl: s.coverFullUrl,
      tint: s.tint,
      artists: s.artists,
    );
  }

  /// [songs] as a list's songs, in their order.
  List<AlbumSong> albumSongs(
    List<VkRecSong> songs,
    int sourceId, {
    bool recommended = false,
  }) => [
    for (final song in songs)
      (
        track: trackOf(song, sourceId, recommended: recommended),
        vkTrackId: song.song.vkTrackId,
      ),
  ];

  /// The VK song behind the outside track [id], or null.
  VkRecSong? songOf(int id) => _byId[id];

  /// Whether [id] is a song VK recommended that the library lacks.
  bool isRecommended(int id) => _recommended.contains(id);

  /// VK's restriction code of the outside track [id] (it cannot play);
  /// null for a song that plays and for any other song.
  int? restrictionOf(int id) => _byId[id]?.restricted;

  /// The library's song that the outside track [id] is, or null.
  Track? libraryCopyOf(int id) {
    final song = _byId[id];
    return song == null ? null : libraryCopyOfSong(song.song);
  }

  /// The VK album of the outside track [track], through the account it was
  /// listed for; null for any other song or one without an album link.
  AlbumRef? albumOf(Track track) {
    final song = _byId[track.id]?.song;
    final title = song?.album;
    final key = song?.vkAlbumKey;
    if (song == null || title == null || title.isEmpty || key == null) {
      return null;
    }
    return AlbumRef(
      title: title,
      artist: song.artist,
      link: (
        sourceId: _sourceOfId[track.id] ?? track.sourceId,
        key: key,
        accessKey: song.vkAlbumAccessKey,
      ),
    );
  }
}
