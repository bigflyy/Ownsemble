import 'track.dart';

/// One place songs come from: a VK account, the generator, later a folder.
class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.kind,
    required this.name,
    required this.songCount,
    required this.goneCount,
    this.account,
    this.lastSyncAtMs,
    this.lastSyncError,
    this.color = 1,
  });

  final int id;
  final TrackSource kind;

  /// VK user id; null for a VK source carried over from the speed-gate
  /// library, until the first sync claims it.
  final String? account;
  final String name;

  /// When the last sync finished (with or without error), Unix milliseconds.
  final int? lastSyncAtMs;

  /// Why the last sync failed; null when it succeeded or never ran.
  final String? lastSyncError;

  /// Songs from this source, including those gone from it.
  final int songCount;

  /// Songs the source no longer has.
  final int goneCount;

  /// The source's color slot, from 1 (see `OwnColors.sourceColor`).
  final int color;
}

/// One play in the History, newest first in lists.
class HistoryEntry {
  const HistoryEntry(this.id, this.trackId, this.playedAtMs);

  final int id;
  final int trackId;
  final int playedAtMs;
}

/// A named Stack: a list that only grows on top.
class StackInfo {
  const StackInfo({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.entryCount,
  });

  final int id;
  final String name;
  final int createdAtMs;
  final int entryCount;
}

/// One song placed on a Stack. The same song can be on a Stack many times;
/// each placement is its own entry.
class StackEntry {
  const StackEntry(this.id, this.trackId, this.addedAtMs);

  final int id;
  final int trackId;
  final int addedAtMs;
}

/// What [LibraryStore.upsertTracks] wrote.
class UpsertResult {
  const UpsertResult(this.ids, this.changedIds);

  /// Library ids of all given songs, in input order.
  final List<int> ids;

  /// Ids of songs that were added or whose stored fields changed (a cleared
  /// gone mark counts as a change).
  final List<int> changedIds;
}

/// A song key's state in the library: its VK access key, stored cover links
/// and when it was marked gone (null while the source still has it).
typedef KnownTrack = ({
  String? accessKey,
  String? coverUrl,
  String? coverLargeUrl,
  String? coverMidUrl,
  String? coverFullUrl,
  int? goneAtMs,
});

/// A VK album as a song's row links to it: the account (source) whose reply
/// named it, its "ownerId_albumId" key and the access key VK needs to list
/// its songs.
typedef VkAlbumLink = ({int sourceId, String key, String? accessKey});

/// What [LibraryStore.mergeSameSongs] did.
class MergeResult {
  const MergeResult(
    this.merged,
    this.unusedFiles, {
    this.unmerged = 0,
    this.marked = 0,
  });

  /// Rows that became copies of another row.
  final int merged;

  /// Copies listed on their own again: their rule no longer holds.
  final int unmerged;

  /// Copies that only moved between the certain and the likely rule.
  final int marked;

  /// Stored audio no row points at any more; the caller deletes the files.
  final List<String> unusedFiles;

  /// Whether the listed library changed, so it has to be loaded again.
  bool get changed => merged > 0 || unmerged > 0 || marked > 0;
}

/// A row whose VK file the sync prints (Stage L): its id, its account, and
/// the song's key and access key in that account.
typedef PrintRequest = ({
  int trackId,
  int sourceId,
  String sourceKey,
  String? accessKey,
});

/// A cached song's stored file, as the cache limit sees it.
class CachedAudio {
  const CachedAudio({
    required this.trackId,
    required this.path,
    required this.bytes,
    required this.lastUsedMs,
  });

  final int trackId;

  /// Stored path, relative to the data folder (or absolute).
  final String path;
  final int bytes;

  /// Last play, or when the file was stored if never played; Unix ms.
  final int lastUsedMs;
}
