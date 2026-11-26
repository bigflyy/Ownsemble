// Plan 10 I2j: the languages Hear the words can be told, and their search.
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/hear_languages.dart';

void main() {
  test('Whisper large-v3 languages: 99 and Cantonese, Russian among them', () {
    expect(hearLanguageNames, hasLength(100));
    expect(hearLanguageNames['ru'], 'Russian');
    expect(hearLanguageNames['yue'], 'Cantonese');
  });

  test('the searchable list leaves out Russian and English, by name', () {
    expect(otherHearLanguages, isNot(contains('ru')));
    expect(otherHearLanguages, isNot(contains('en')));
    expect(otherHearLanguages, hasLength(98));
    final names = [
      for (final code in otherHearLanguages) hearLanguageNames[code]!,
    ];
    expect(names, [...names]..sort());
    expect(names.first, 'Afrikaans');
  });

  test('search: a word start of the name, or the exact code, any case', () {
    expect(searchHearLanguages('ukr', otherHearLanguages), ['uk']);
    expect(searchHearLanguages('UK', otherHearLanguages), ['uk']);
    expect(searchHearLanguages('creole', otherHearLanguages), ['ht']);
    expect(searchHearLanguages('  ', otherHearLanguages), otherHearLanguages);
    expect(searchHearLanguages('kraine', otherHearLanguages), isEmpty);
    expect(searchHearLanguages('ru', ['ru', 'en']), ['ru']);
  });

  test('a code this build does not know shows as itself', () {
    expect(hearLanguageName('xx'), 'xx');
    expect(hearLanguageName('uk'), 'Ukrainian');
  });
}
