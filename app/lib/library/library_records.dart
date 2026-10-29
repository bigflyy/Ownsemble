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
  int? goneAtMs,
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
