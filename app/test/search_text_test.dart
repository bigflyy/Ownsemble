import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/search_text.dart';

void main() {
  test('normalization lowercases and folds ё into е', () {
    expect(normalizeForSearch('Ёлка ЁЖ Всё'), 'елка еж все');
    expect(normalizeForSearch('Metallica'), 'metallica');
  });

  test('search words are normalized letters and digits', () {
    expect(searchWords('Кино  звЁзд'), ['кино', 'звезд']);
    expect(searchWords('AC/DC 2'), ['ac', 'dc', '2']);
    expect(searchWords('  "*- '), isEmpty);
  });

  test('every word must occur somewhere, also inside words', () {
    const text = 'metallica\nnothing else matters';
    expect(matchesAllWords(text, ['tallica']), isTrue);
    expect(matchesAllWords(text, ['matters', 'meta']), isTrue);
    expect(matchesAllWords(text, ['tallica', 'kino']), isFalse);
  });
}
