/// Which songs found on a source the library has already (plan 06, C2), so
/// Add is never offered for a song you have: VK makes another copy on every
/// add, even of a song the account has (A2).
library;

import 'library_store.dart';
import 'same_song.dart';

/// Tells for a found song which listed song of the library it is, if any.
///
/// A found song is in the library when a row that is not removed:
/// 1. has the same VK key (the account's own copy came up in the search, or
///    another account's row is that very upload);
/// 2. has the same VK `track_id`: VK says it is the same recording;
/// 3. has the same artist and title ([songMatchText]) and a length within
///    [sameSongLengthTolerance]: another upload of the same recording. The
///    length keeps a live or other cut with the same name addable.
///
/// Built once from [LibraryStore.songRows] after the library changes, so
/// each found song is matched in constant time while results come in.
class FoundMatcher {
  FoundMatcher(Iterable<SongRow> rows) {
    for (final row in rows) {
      _byKey.putIfAbsent(row.sourceKey, () => row);
      if (row.vkTrackId case final trackId?) {
        _byTrackId.putIfAbsent(trackId, () => row);
      }
      if (row.text.isNotEmpty) (_byText[row.text] ??= []).add(row);
    }
  }

  final _byKey = <String, SongRow>{};
  final _byTrackId = <int, SongRow>{};
  final _byText = <String, List<SongRow>>{};

  /// The id of the listed song [found] is, or null when the library does not
  /// have it. A merged copy answers with the song it is listed under.
  int? listedIdOf(NewTrack found) {
    final row =
        _byKey[found.sourceKey] ??
        (found.vkTrackId == null ? null : _byTrackId[found.vkTrackId]) ??
        _sameTextAndLength(found);
    return row == null ? null : row.sameAs ?? row.id;
  }

  SongRow? _sameTextAndLength(NewTrack found) {
    final rows = _byText[songMatchText(found.artist, found.title)];
    if (rows == null) return null;
    for (final row in rows) {
      if ((row.seconds - found.durationSec).abs() <= sameSongLengthTolerance) {
        return row;
      }
    }
    return null;
  }
}
