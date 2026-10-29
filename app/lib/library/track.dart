/// Where a song in the library comes from.
enum TrackSource {
  /// Synthetic song made by the speed-gate generator.
  generated,

  /// Song from the user's VK library.
  vk,
}

/// One song in the library, as the list and the player need it.
class Track {
  const Track({
    required this.id,
    required this.source,
    required this.artist,
    required this.title,
    required this.durationSec,
    this.sourceKey,
    this.accessKey,
    this.localPath,
  });

  /// Library row id; also the search index rowid.
  final int id;
  final TrackSource source;
  final String artist;
  final String title;
  final int durationSec;

  /// Id inside the source, for VK "ownerId_audioId".
  final String? sourceKey;

  /// VK access key needed to resolve a fresh stream URL.
  final String? accessKey;

  /// Cached audio file on disk, if any.
  final String? localPath;

  /// Whether the player can start this song without the network.
  bool get isCached => localPath != null;
}
