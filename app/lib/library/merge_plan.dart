/// Which rows of several accounts become one listed row (Stage L).
///
/// User, 2026-11-04: "only same if we can reliably 100% say they are same.
/// otherwise ... make it toggleable from settings: merge them or not via the
/// most accurate rule we come up with". So:
///
/// - certain: the same VK upload (same key), or VK gives both rows the same
///   file (equal [FilePrint]s). Always merged.
/// - likely: the same `track_id`, listed lengths within
///   [sameSongLengthTolerance] and real file lengths within
///   [likelyRealTolerance]. Merged only when the setting is on, and marked.
///
/// [isSameSong] only finds the candidates: pairs worth printing.
library;

import 'file_print.dart';
import 'same_song.dart';

/// How far apart the real lengths of two files may be for the likely rule.
const likelyRealTolerance = 1.0;

/// One row as the merge sees it.
class MergeRow {
  const MergeRow(this.song, {this.print, this.likely = false});

  /// The row; its [SongRow.sameAs] is the merge stored now.
  final SongRow song;

  /// VK's file for the row; null when not read yet.
  final FilePrint? print;

  /// Whether the row is stored as a copy merged by the likely rule.
  final bool likely;

  int get id => song.id;
}

/// How two rows may be one.
enum MergeKind { certain, likely }

/// What [planMerges] decided.
class MergePlan {
  const MergePlan(this.copies, this.likely);

  /// Each copy's id to the id of the row listed for it.
  final Map<int, int> copies;

  /// The copies merged by the likely rule only.
  final Set<int> likely;
}

/// Whether [a] and [b] are close enough for the likely rule: one VK
/// `track_id`, listed lengths within 2 s and files that play within 1 s.
bool isLikelySame(MergeRow a, MergeRow b) {
  final (first, second) = (a.song.vkTrackId, b.song.vkTrackId);
  final (aSeconds, bSeconds) = (a.print?.seconds, b.print?.seconds);
  return first != null &&
      first == second &&
      (a.song.seconds - b.song.seconds).abs() <= sameSongLengthTolerance &&
      aSeconds != null &&
      bSeconds != null &&
      (aSeconds - bSeconds).abs() <= likelyRealTolerance;
}

/// Whether [a] and [b] are stored as one song now.
bool _mergedNow(MergeRow a, MergeRow b) {
  final (aHome, bHome) = (a.song.sameAs, b.song.sameAs);
  return aHome == b.id || bHome == a.id || (aHome != null && aHome == bHome);
}

/// How [a] and [b] may be one song, or null when they stay two rows.
/// With [mergeLikely] off only the certain rule merges.
MergeKind? mergeKindOf(MergeRow a, MergeRow b, {required bool mergeLikely}) {
  if (a.song.sourceId == b.song.sourceId) return null;
  if (a.song.sourceKey == b.song.sourceKey) return MergeKind.certain;
  // A stored merge is judged by its files even when VK changed a title or
  // a length since: the same file is the same song.
  final mergedNow = _mergedNow(a, b);
  if (!mergedNow && !isSameSong(a.song, b.song)) return null;
  final (aPrint, bPrint) = (a.print, b.print);
  if (aPrint != null && bPrint != null) {
    if (aPrint.sameFileAs(bPrint)) return MergeKind.certain;
    if (mergeLikely && isLikelySame(a, b)) return MergeKind.likely;
    return null;
  }
  // A file not read yet (the account did not sync, or the line failed)
  // leaves a stored merge as it is until the next sync can read it.
  if (!mergedNow) return null;
  if (a.likely || b.likely) return mergeLikely ? MergeKind.likely : null;
  return MergeKind.certain;
}

/// Rows that are one song: the listed row first, then its copies.
class _Group {
  _Group(MergeRow first) : members = [first], sources = {first.song.sourceId};

  final List<MergeRow> members;
  final Set<int> sources;

  int get id => members.first.id;
}

/// The shelves [planMerges] and [rowsToPrint] look partners up on: rows can
/// only be one song when they share a key, a `track_id` or a text, or are
/// stored as one song now (the same listed row: their "home").
class _Shelves<T> {
  final _byKey = <String, List<T>>{};
  final _byTrackId = <int, List<T>>{};
  final _byText = <String, List<T>>{};
  final _byHome = <int, List<T>>{};

  Iterable<List<T>> of(SongRow row) => [
    _byKey[row.sourceKey] ??= [],
    _byHome[row.sameAs ?? row.id] ??= [],
    if (row.vkTrackId case final id?) _byTrackId[id] ??= [],
    if (row.text.isNotEmpty) _byText[row.text] ??= [],
  ];

  void put(SongRow row, T item) {
    for (final shelf in of(row)) {
      shelf.add(item);
    }
  }
}

/// Decides from scratch which rows of [rows] are copies of another row.
///
/// Only rows of different accounts merge, one row per account in each
/// group: a song twice in one VK list stays twice, as VK shows it. The row
/// listed is the oldest of its group, so a song that is new in one account
/// never takes over the row the other account's History and Stacks point
/// at. [rows] must be in id order; lookups go through shelves, so this stays
/// linear in the library's size.
MergePlan planMerges(List<MergeRow> rows, {required bool mergeLikely}) {
  final shelves = _Shelves<_Group>();
  final copies = <int, int>{};
  final likely = <int>{};
  for (final row in rows) {
    final partners = <_Group>{
      for (final shelf in shelves.of(row.song)) ...shelf,
    }.toList()..sort((a, b) => a.id.compareTo(b.id));
    _Group? home;
    MergeKind? kind;
    for (final group in partners) {
      if (group.sources.contains(row.song.sourceId)) continue;
      for (final member in group.members) {
        final found = mergeKindOf(member, row, mergeLikely: mergeLikely);
        if (found == null) continue;
        kind = kind == MergeKind.certain ? kind : found;
      }
      if (kind != null) {
        home = group;
        break;
      }
    }
    if (home == null) {
      shelves.put(row.song, _Group(row));
      continue;
    }
    home.members.add(row);
    home.sources.add(row.song.sourceId);
    copies[row.id] = home.id;
    if (kind == MergeKind.likely) likely.add(row.id);
    shelves.put(row.song, home);
  }
  return MergePlan(copies, likely);
}

/// The ids of [rows] whose VK file is worth printing: each has a partner in
/// another account under another key that is a candidate ([isSameSong]) or
/// stored as the same song now. Rows with the same key are one upload and
/// need no print.
Set<int> rowsToPrint(List<SongRow> rows) {
  final shelves = _Shelves<SongRow>();
  final wanted = <int>{};
  for (final row in rows) {
    for (final shelf in shelves.of(row)) {
      for (final other in shelf) {
        final sameHome = (other.sameAs ?? other.id) == (row.sameAs ?? row.id);
        if (other.sourceId == row.sourceId ||
            other.sourceKey == row.sourceKey ||
            !(sameHome || isSameSong(other, row))) {
          continue;
        }
        wanted
          ..add(other.id)
          ..add(row.id);
      }
    }
    shelves.put(row, row);
  }
  return wanted;
}
