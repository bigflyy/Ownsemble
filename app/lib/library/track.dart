/// What kind of place a song comes from.
enum TrackSource {
  /// Synthetic song made by the speed-gate generator.
  generated,

  /// Song from a VK account's library.
  vk,
}

/// One song in the library, as the list and the player need it.
class Track {
  const Track({
    required this.id,
    required this.sourceId,
    required this.source,
    required this.artist,
    required this.title,
    required this.durationSec,
    this.album,
    this.sourceKey,
    this.accessKey,
    this.coverUrl,
    this.coverLargeUrl,
    this.coverMidUrl,
    this.coverFullUrl,
    this.tint,
    this.goneAtMs,
    this.localPath,
    this.pinned = false,
  });

  /// Library row id.
  final int id;

  /// Library id of the source (one VK account, the generator, ...).
  final int sourceId;
  final TrackSource source;
  final String artist;
  final String title;
  final String? album;
  final int durationSec;

  /// Id inside the source, for VK "ownerId_audioId".
  final String? sourceKey;

  /// VK access key needed to resolve a fresh stream URL.
  final String? accessKey;

  /// Small cover image (about 135 px) for list rows.
  final String? coverUrl;

  /// Large cover image (about 600 px) for the player panel.
  final String? coverLargeUrl;

  /// Middle cover image (about 300 px), for when VK does not serve the size
  /// that was asked for: it often lacks one size of an image and has the rest.
  final String? coverMidUrl;

  /// Biggest cover image (about 1200 px).
  final String? coverFullUrl;

  /// Main color of the cover as 0xAARRGGBB, for stand-in tiles.
  final int? tint;

  /// Links to try for a list row's tile, best first.
  List<String> get smallCovers => [
    ?coverUrl,
    ?coverMidUrl,
    ?coverLargeUrl,
    ?coverFullUrl,
  ];

  /// Links to try for a panel-sized tile, best first. The small size is left
  /// out: the row's own small cover is what shows under it anyway.
  List<String> get largeCovers => [?coverLargeUrl, ?coverFullUrl, ?coverMidUrl];

  /// Whether VK gave the song a real cover, in any size.
  bool get hasCover => smallCovers.isNotEmpty;

  /// When a sync found the song gone from its source, Unix milliseconds.
  final int? goneAtMs;

  /// Stored audio file, relative to the data folder (or absolute), if any.
  final String? localPath;

  /// Whether the stored file is a download: kept until the user removes it,
  /// never evicted by the cache limit.
  final bool pinned;

  /// Whether the player can start this song without the network.
  bool get isCached => localPath != null;

  /// Whether the song is downloaded (pinned in storage).
  bool get isDownloaded => localPath != null && pinned;

  /// Whether the source no longer has this song; it plays only if stored.
  bool get isGone => goneAtMs != null;
}
