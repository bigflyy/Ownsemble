/// Text normalization shared by the search index and search queries.
///
/// Both sides go through [normalizeForSearch], so "Ёлка", "ёлка" and "елка"
/// all find each other.
library;

final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Lowercases [text] and folds "ё" into "е".
String normalizeForSearch(String text) =>
    text.toLowerCase().replaceAll('ё', 'е');

/// Builds an FTS5 MATCH expression from what the user typed.
///
/// Every word must match the start of some word in the song (prefix search),
/// in any order. Returns null when [input] has no letters or digits, which
/// means "no filter".
String? buildMatchQuery(String input) {
  final words = _wordPattern
      .allMatches(normalizeForSearch(input))
      .map((match) => match.group(0)!)
      .toList();
  if (words.isEmpty) return null;
  // Words contain only letters and digits, so quoting needs no escaping.
  return words.map((word) => '"$word"*').join(' ');
}
