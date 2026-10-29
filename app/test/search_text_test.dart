import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/search_text.dart';

void main() {
  test('normalization lowercases and folds ё into е', () {
    expect(normalizeForSearch('Ёлка ЁЖ Всё'), 'елка еж все');
    expect(normalizeForSearch('Metallica'), 'metallica');
  });

  test('match query makes every word a prefix term', () {
    expect(buildMatchQuery('Кино  звЁзд'), '"кино"* "звезд"*');
    expect(buildMatchQuery('AC/DC'), '"ac"* "dc"*');
  });

  test('input without letters or digits means no filter', () {
    expect(buildMatchQuery(''), isNull);
    expect(buildMatchQuery('  "*- '), isNull);
  });
}
