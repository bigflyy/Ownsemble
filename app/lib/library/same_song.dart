/// How one song in two accounts becomes one row in the library.
///
/// A wrong merge hides a song and a missed one only shows it twice, so the key
/// leans to not merging. Measured on two real accounts (2745 songs): VK's own
/// `track_id` alone is not safe, 29 of 252 groups sharing one had other text.
library;

/// How far apart two lengths may be for one `track_id` to mean one recording.
/// Pairs 5-15 s apart were seen: probably other cuts of the song.
const sameSongLengthTolerance = 2;

final _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The text two rows must share for [findSameSongs]: lower case, ё as е, and
/// every run of other characters as one space.
String songMatchText(String artist, String title) => '$artist $title'
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(_notLetterOrDigit, ' ')
    .trim();

/// The fields of a library row the duplicate key reads.
class SongRow {
  const SongRow({
    required this.id,
    required this.sourceId,
    required this.sourceKey,
    required this.text,
    required this.seconds,
    this.vkTrackId,
    this.sameAs,
  });

  final int id;
  final int sourceId;
  final String sourceKey;

  /// See [songMatchText].
  final String text;
  final int seconds;

  /// VK's id of the recording; null when VK gives none.
  final int? vkTrackId;

  /// The row this one is a copy of, when it is merged already.
  final int? sameAs;
}

/// Whether two rows of different accounts are one song:
/// 1. the same VK key;
/// 2. the same `track_id` and a length within [sameSongLengthTolerance];
/// 3. the same text and exact length, unless both have a `track_id`: different
///    ids mean VK says they differ.
bool isSameSong(SongRow a, SongRow b) {
  if (a.sourceKey == b.sourceKey) return true;
  final (first, second) = (a.vkTrackId, b.vkTrackId);
  if (first != null && second != null) {
    return first == second &&
        (a.seconds - b.seconds).abs() <= sameSongLengthTolerance;
  }
  return a.text.isNotEmpty &&
      a.seconds > 0 &&
      a.text == b.text &&
      a.seconds == b.seconds;
}

/// Rows that are one song: the first row and its copies.
class _Group {
  _Group(SongRow first) : members = [first];

  final List<SongRow> members;

  int get id => members.first.id;

  bool takes(_Group other) {
    final sources = {for (final row in members) row.sourceId};
    if (other.members.any((row) => sources.contains(row.sourceId))) {
      return false;
    }
    return members.any(
      (mine) => other.members.any((theirs) => isSameSong(mine, theirs)),
    );
  }
}

/// Which rows of [rows] are new copies of another row, as copy id to the id of
/// the row that stays in the lists.
///
/// Only rows of different accounts merge: a song twice in one VK list stays
/// twice, as VK shows it. The row that stays is the oldest of its group, so
/// a song that is new in one account never takes over the row the other
/// account's History and Stacks already point at. A merge is kept once made,
/// even if VK changes the song's details later.
///
/// [rows] must be in id order. Each lookup goes through the maps below, so this
/// stays linear in the library's size.
Map<int, int> findSameSongs(List<SongRow> rows) {
  final groups = <int, _Group>{};
  for (final row in rows) {
    final primary = row.sameAs;
    if (primary == null) {
      groups[row.id] = _Group(row);
    } else {
      groups[primary]?.members.add(row);
    }
  }

  final byKey = <String, List<_Group>>{};
  final byTrackId = <int, List<_Group>>{};
  final byText = <String, List<_Group>>{};
  Iterable<List<_Group>> shelves(SongRow row) => [
    byKey[row.sourceKey] ??= [],
    if (row.vkTrackId case final id?) byTrackId[id] ??= [],
    byText[row.text] ??= [],
  ];

  final found = <int, int>{};
  for (final group in groups.values) {
    final partners = <_Group>{
      for (final row in group.members)
        for (final shelf in shelves(row)) ...shelf,
    };
    final older = partners.where((other) => other.takes(group)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final home = older.firstOrNull;
    if (home == null) {
      for (final row in group.members) {
        for (final shelf in shelves(row)) {
          shelf.add(group);
        }
      }
      continue;
    }
    for (final row in group.members) {
      found[row.id] = home.id;
      for (final shelf in shelves(row)) {
        shelf.add(home);
      }
    }
    home.members.addAll(group.members);
  }
  return found;
}
