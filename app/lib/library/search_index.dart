import 'search_text.dart';
import 'track.dart';

/// In-memory substring search over the library.
///
/// Keeps one normalized string per song (artist, title and album). Checking
/// every song is a few milliseconds at 10,000 songs and needs no index upkeep.
class SearchIndex {
  SearchIndex(this._tracks)
    : _texts = [for (final track in _tracks) searchTextOf(track)];

  final List<Track> _tracks;
  final List<String> _texts;

  /// Songs matching [input] in library order, or null for "no filter".
  List<Track>? search(String input) {
    final words = searchWords(input);
    if (words.isEmpty) return null;
    return [
      for (var i = 0; i < _tracks.length; i++)
        if (matchesAllWords(_texts[i], words)) _tracks[i],
    ];
  }
}

/// The normalized text a search looks in for [track]: artist, title and
/// album.
String searchTextOf(Track track) =>
    normalizeForSearch('${track.artist}\n${track.title}\n${track.album ?? ''}');
