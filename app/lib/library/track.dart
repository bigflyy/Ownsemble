/// What kind of place a song comes from.
enum TrackSource {
  /// Synthetic song made by the speed-gate generator.
  generated,

  /// Song from a VK account's library.
  vk,
}

/// One account's copy of a song: another account's row merged into the one
/// that is listed. See `planMerges`.
class TrackCopy {
  const TrackCopy({
    required this.sourceId,
    required this.sourceKey,
    this.accessKey,
    this.goneAtMs,
    this.likely = false,
  });

  final int sourceId;
  final String? sourceKey;
  final String? accessKey;

  /// When this account lost the song, Unix milliseconds.
  final int? goneAtMs;

  /// Merged by the likely rule only: probably, not certainly, the same file
  /// (Stage L).
  final bool likely;
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
    this.copies = const [],
    this.addedAt = 0,
  });

  /// When the song was added to its source, by the source's own date, Unix
  /// seconds (0: unknown).
  final int addedAt;

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

  /// When a sync found the song gone from its source ([sourceId]), Unix
  /// milliseconds. Another account may still have it: see [isGone].
  final int? goneAtMs;

  /// The same song in other accounts; empty for most songs.
  final List<TrackCopy> copies;

  /// Every account's copy of this song, this row's own first.
  List<TrackCopy> get allCopies => [
    TrackCopy(
      sourceId: sourceId,
      sourceKey: sourceKey,
      accessKey: accessKey,
      goneAtMs: goneAtMs,
    ),
    ...copies,
  ];

  /// Whether another account's copy was merged in only by the likely rule
  /// (the setting "also merge likely copies"), so the row is marked.
  bool get mergedLikely => copies.any((copy) => copy.likely);

  /// Whether [source] has this song, gone or not.
  bool isFrom(int source) =>
      sourceId == source || copies.any((copy) => copy.sourceId == source);

  /// Stored audio file, relative to the data folder (or absolute), if any.
  final String? localPath;

  /// Whether the stored file is a download: kept until the user removes it,
  /// never evicted by the cache limit.
  final bool pinned;

  /// Whether the player can start this song without the network.
  bool get isCached => localPath != null;

  /// Whether the song is downloaded (pinned in storage).
  bool get isDownloaded => localPath != null && pinned;

  /// Whether the song is a library row. A song of an opened album that the
  /// library lacks gets a negative id instead: it streams like any other,
  /// but has no row for History, Stacks or stored audio to point at.
  bool get inLibrary => id >= 0;

  /// Whether no account has this song any more; it plays only if stored.
  bool get isGone =>
      goneAtMs != null && copies.every((copy) => copy.goneAtMs != null);

  /// This song with [other]'s cover in every size and its color: how an
  /// album's place shows the user's own copy of one of its songs.
  Track withCoversOf(Track other) => Track(
    id: id,
    sourceId: sourceId,
    source: source,
    artist: artist,
    title: title,
    album: album,
    durationSec: durationSec,
    sourceKey: sourceKey,
    accessKey: accessKey,
    coverUrl: other.coverUrl,
    coverLargeUrl: other.coverLargeUrl,
    coverMidUrl: other.coverMidUrl,
    coverFullUrl: other.coverFullUrl,
    tint: other.tint,
    goneAtMs: goneAtMs,
    localPath: localPath,
    pinned: pinned,
    copies: copies,
    addedAt: addedAt,
  );
}
