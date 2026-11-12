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
/// 2. has the same VK `track_id` and a length within
///    [sameSongLengthTolerance]: VK says it is the same recording, and the
///    length guards against VK reusing one id for other songs (seen on real
///    VK, 2026-11-12: one id on two titles, a 1380 s concert's id on many);
/// 3. has the same artist and title ([songMatchText]) and a length within
///    [sameSongLengthTolerance]: another upload of the same recording. The
///    length keeps a live or other cut with the same name addable.
///
/// Built once from [LibraryStore.songRows] after the library changes, so
/// each found song is matched in constant time while results come in.
class FoundMatcher {
  FoundMatcher(Iterable<SongRow> rows) {
    for (final row in rows) {
      (_byKey[row.sourceKey] ??= []).add(row);
      if (row.vkTrackId case final trackId?) {
        (_byTrackId[trackId] ??= []).add(row);
      }
      if (row.text.isNotEmpty) (_byText[row.text] ??= []).add(row);
    }
  }

  final _byKey = <String, List<SongRow>>{};
  final _byTrackId = <int, List<SongRow>>{};
  final _byText = <String, List<SongRow>>{};

  /// The id of the listed song [found] is, or null when the library does not
  /// have it. A merged copy answers with the song it is listed under.
  ///
  /// Listed songs in [except] (and rows merged into them) are passed over:
  /// in a song's Versions every other upload has that song's name and
  /// often its length or VK track id, so the song itself must not count as
  /// "already in the library" for them (C4).
  int? listedIdOf(NewTrack found, {Set<int> except = const {}}) {
    bool usable(SongRow row) =>
        except.isEmpty || !except.contains(row.sameAs ?? row.id);
    SongRow? firstOf(Iterable<SongRow>? rows) =>
        rows?.where(usable).firstOrNull;
    final row =
        firstOf(_byKey[found.sourceKey]) ??
        (found.vkTrackId == null
            ? null
            : firstOf(
                _byTrackId[found.vkTrackId]?.where(
                  (row) => _closeLength(row, found),
                ),
              )) ??
        _sameTextAndLength(found, usable);
    return row == null ? null : row.sameAs ?? row.id;
  }

  /// The listed song that has [found]'s artist and title but is another
  /// recording (another length), for the hint "you have another version"
  /// (C4e); null when the library has [found] itself ([listedIdOf]) or no
  /// song of that name. Of several, the one closest in length.
  int? otherVersionIdOf(NewTrack found, {Set<int> except = const {}}) {
    if (listedIdOf(found, except: except) != null) return null;
    final rows = _byText[songMatchText(found.artist, found.title)];
    if (rows == null) return null;
    SongRow? best;
    for (final row in rows) {
      if (except.contains(row.sameAs ?? row.id)) continue;
      final gap = (row.seconds - found.durationSec).abs();
      if (best == null || gap < (best.seconds - found.durationSec).abs()) {
        best = row;
      }
    }
    return best == null ? null : best.sameAs ?? best.id;
  }

  static bool _closeLength(SongRow row, NewTrack found) =>
      (row.seconds - found.durationSec).abs() <= sameSongLengthTolerance;

  SongRow? _sameTextAndLength(NewTrack found, bool Function(SongRow) usable) {
    final rows = _byText[songMatchText(found.artist, found.title)];
    if (rows == null) return null;
    for (final row in rows) {
      if (usable(row) && _closeLength(row, found)) return row;
    }
    return null;
  }
}
