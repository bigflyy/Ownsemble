/// Text normalization and matching for library search.
///
/// Song text and queries both go through [normalizeForSearch], so "Ёлка",
/// "ёлка" and "елка" all find each other.
library;

final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Lowercases [text] and folds "ё" into "е".
String normalizeForSearch(String text) =>
    text.toLowerCase().replaceAll('ё', 'е');

/// The normalized words the user typed; empty means "no filter".
List<String> searchWords(String input) => _wordPattern
    .allMatches(normalizeForSearch(input))
    .map((match) => match.group(0)!)
    .toList();

/// Whether a word of [normalizedText] starts with [prefix], which may itself
/// run over several words ("about y" is found in "mad about you").
bool hasWordStartingWith(String normalizedText, String prefix) {
  var at = normalizedText.indexOf(prefix);
  while (at >= 0) {
    if (at == 0 || !_wordPattern.hasMatch(normalizedText[at - 1])) return true;
    at = normalizedText.indexOf(prefix, at + 1);
  }
  return false;
}

/// Whether every word of [words] occurs anywhere in [normalizedText], in any
/// order and also inside longer words ("tallica" matches "Metallica").
bool matchesAllWords(String normalizedText, List<String> words) {
  for (final word in words) {
    if (!normalizedText.contains(word)) return false;
  }
  return true;
}
