/// Which rows of two accounts may be one song: the candidates whose files
/// `planMerges` compares (Stage L).
///
/// A wrong merge hides a song and a missed one only shows it twice, so the key
/// leans to not merging. Measured on two real accounts (2745 songs): VK's own
/// `track_id` alone is not safe, 29 of 252 groups sharing one had other text.
library;

/// How far apart two lengths may be for one `track_id` to mean one recording.
/// Pairs 5-15 s apart were seen: probably other cuts of the song.
const sameSongLengthTolerance = 2;

final _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The text two rows must share for [isSameSong]: lower case, ё as е, and
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

/// Whether two rows of different accounts may be one song, so their files
/// are worth comparing (see `planMerges`, which decides):
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
