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
