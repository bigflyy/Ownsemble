// Unit tests for plan 10 I2e: the rules that turn heard words into a heard
// version (loudness, word count, lines, outcome, rough mark) and its row in
// the library. The words are made up; Cyrillic and CJK round trip.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/lyrics/gigaam.dart' show HeardWord;
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics.dart';

/// Words of [text] split at spaces, [step] s apart from [start], each
/// lasting 0.3 s.
List<HeardWord> said(
  String text, {
  double start = 0,
  double step = 0.5,
  double confidence = 0.95,
}) => [
  for (final (i, word) in text.split(' ').indexed)
    HeardWord(start + i * step, start + i * step + 0.3, word, confidence),
];

/// [seconds] of a sine at [db] dB of full scale RMS, 16 kHz.
Float32List tone(double seconds, double db) {
  final amplitude = math.pow(10, db / 20) * math.sqrt2;
  return Float32List.fromList([
    for (var i = 0; i < (seconds * 16000).round(); i++)
      amplitude * math.sin(2 * math.pi * 440 * i / 16000),
  ]);
}

HeardLyrics judged(
  List<HeardWord> words, {
  HeardModel? model = HeardModel.gigaam,
  double confidence = 0.95,
  double loud = 100,
}) => judgeHeard(
  model: model,
  words: words,
  confidence: confidence,
  russianConfidence: 0.9,
  language: model == HeardModel.gigaam ? 'ru' : 'en',
  loud: loud,
  songMs: 200000,
  heardAtMs: 1,
);

void main() {
  group('loudSeconds', () {
    test('counts 100 ms windows above -35 dB', () {
      expect(loudSeconds(Float32List(16000 * 3)), 0);
      expect(loudSeconds(tone(2, -20)), closeTo(2, 1e-9));
      expect(loudSeconds(tone(2, -40)), 0);
      final mixed = Float32List.fromList([
        ...tone(1, -40),
        ...tone(1.5, -30),
        ...Float32List(16000),
      ]);
      expect(loudSeconds(mixed), closeTo(1.5, 1e-9));
    });

    test('leaves out a last partial window', () {
      expect(loudSeconds(tone(0.05, -10)), 0);
      expect(loudSeconds(tone(0.15, -10)), closeTo(0.1, 1e-9));
    });
  });

  group('countHeardWords', () {
    test('counts words in their own text, any script', () {
      expect(countHeardWords(said('Привет как дела')), 3);
      expect(countHeardWords(said('Hello, world!')), 2);
      // A word of punctuation only is no word.
      expect(countHeardWords(said('... - !')), 0);
      // Each Han character and kana is a word; hangul words by spaces.
      expect(countHeardWords(said('我爱你')), 3);
      expect(countHeardWords(said('ありがとう')), 5);
      expect(countHeardWords(said('사랑해 너를')), 2);
      // Mixed text: the Latin run is one word beside each character.
      expect(countHeardWords(said('OK我们')), 3);
      // Joined by an apostrophe or hyphen: each run of letters counts.
      expect(countHeardWords(said("don't")), 2);
      expect(countHeardWords(said('Café')), 1);
    });
  });

  group('cutHeardLines', () {
    test('breaks before capitals and after . ! ?, not at commas', () {
      final words = said('Я иду домой, тихо. потом снова Ты здесь! и всё? да');
      expect(
        [for (final line in cutHeardLines(words)) line.text],
        ['Я иду домой, тихо.', 'потом снова', 'Ты здесь!', 'и всё?', 'да'],
      );
    });

    test('passes opening marks before the capital test', () {
      final words = said('one two "Three four (Five six -Seven');
      expect(
        [for (final line in cutHeardLines(words)) line.text],
        ['one two', '"Three four', '(Five six', '-Seven'],
      );
    });

    test('lines run from the first word start to the last word end', () {
      final lines = cutHeardLines(said('one two. Three', start: 10));
      expect(lines.map((line) => (line.startMs, line.endMs)), [
        (10000, 10800),
        (11000, 11300),
      ]);
    });

    test('a line over 12 words splits at its widest pause', () {
      // 16 words; the widest pause sits after word 11.
      final words = [
        for (var i = 0; i < 16; i++)
          HeardWord(
            i * 0.5 + (i >= 11 ? 1.0 : 0),
            i * 0.5 + 0.3 + (i >= 11 ? 1.0 : 0),
            'w$i',
            0.9,
          ),
      ];
      final lines = cutHeardLines(words);
      expect([for (final line in lines) line.text.split(' ').length], [11, 5]);
    });

    test('a split keeps 2 words on each side and recurses', () {
      // 26 words, widest pause after word 1 (not allowed) then evenly.
      final words = [
        for (var i = 0; i < 26; i++)
          HeardWord(
            i + (i >= 1 ? 5.0 : 0),
            i + 0.5 + (i >= 1 ? 5.0 : 0),
            'w$i',
            0.9,
          ),
      ];
      final sizes = [
        for (final line in cutHeardLines(words)) line.text.split(' ').length,
      ];
      expect(sizes.every((size) => size >= 2 && size <= 12), isTrue);
      expect(sizes.fold(0, (a, b) => a + b), 26);
    });

    test('a tie between pauses takes the later one, as the research', () {
      final words = [
        for (var i = 0; i < 13; i++)
          HeardWord(i * 1.0, i * 1.0 + 0.5, 'w$i', 0.9),
      ];
      final lines = cutHeardLines(words);
      expect([for (final line in lines) line.text.split(" ").length], [11, 2]);
    });

    test('long pauses and the end of the song get gap lines', () {
      final words = [
        ...said('First line.', start: 5),
        ...said('Second line', start: 20),
      ];
      final lines = cutHeardLines(words, songMs: 40000);
      expect(lines.map((line) => (line.text, line.startMs, line.endMs)), [
        ('First line.', 5000, 5800),
        ('', 5800, 20000),
        ('Second line', 20000, 20800),
        ('', 20800, 40000),
      ]);
      // A pause under 8 s and an end under 8 s away: no gap.
      final close = cutHeardLines([
        ...said('A b.', start: 0),
        ...said('C d', start: 8),
      ], songMs: 15000);
      expect(close.where((line) => line.isGap), isEmpty);
    });

    test('CJK sentence ends break lines; empty words are dropped', () {
      final words = [
        HeardWord(1, 2, '我爱你。', 0.9),
        HeardWord(2, 3, ' ', null),
        HeardWord(3, 4, '你好', 0.9),
      ];
      expect(
        [for (final line in cutHeardLines(words)) line.text],
        ['我爱你。', '你好'],
      );
    });

    test('nothing heard gives no lines', () {
      expect(cutHeardLines(const []), isEmpty);
    });

    test('the 12-word limit counts words in the text, as the research', () {
      // 11 entries, one of them two words joined by a hyphen: 12 words,
      // no split. One more joined entry makes 13: split.
      final twelve = said('a b c d e f g h i j well-known');
      expect(cutHeardLines(twelve), hasLength(1));
      final thirteen = said('a b c d e f g h i well-known so-so');
      expect(cutHeardLines(thirteen), hasLength(2));
      // One long unspaced entry cannot be split: it stays whole.
      final long = [HeardWord(0, 1, '我' * 20, 0.9), HeardWord(1, 2, '你', 0.9)];
      expect(cutHeardLines(long), hasLength(1));
    });

    test('words starting at the same time keep their order', () {
      final words = [
        for (var i = 0; i < 40; i++) HeardWord(1, 1.2, 'w$i', 0.9),
      ];
      final text = cutHeardLines(words).map((line) => line.text).join(' ');
      expect(text, [for (var i = 0; i < 40; i++) 'w$i'].join(' '));
    });
  });

  group('heard word times (plan 10 J2)', () {
    test('every line carries the times of its own words', () {
      final lines = cutHeardLines(said('one two. Three', start: 10));
      expect(lines[0].words, const [
        WordTime(10000, 10300),
        WordTime(10500, 10800),
      ]);
      expect(lines[1].words, const [WordTime(11000, 11300)]);
    });

    test('a model word with a space inside gives each piece its time', () {
      final lines = cutHeardLines([
        HeardWord(1, 1.4, 'New York', 0.9),
        HeardWord(1.5, 2, 'nights', 0.9),
      ]);
      expect(lines.single.text, 'New York nights');
      expect(lines.single.words, const [
        WordTime(1000, 1400),
        WordTime(1000, 1400),
        WordTime(1500, 2000),
      ]);
    });

    test('lines kept without word times get them from the words', () {
      final words = said('Ночь улица. Фонарь аптека', start: 2);
      final bare = [
        for (final line in cutHeardLines(words, songMs: 60000))
          LyricLine(line.text, startMs: line.startMs, endMs: line.endMs),
      ];
      expect(bare.any((line) => line.hasWordTimes), isFalse);
      final timed = withHeardWordTimes(bare, words);
      expect(timed, cutHeardLines(words, songMs: 60000));
      expect(timed.last.isGap, isTrue);
    });

    test('words that do not match the lines leave the lines as they were', () {
      final words = said('Ночь улица. Фонарь аптека');
      final bare = [LyricLine('Ночь другая.', startMs: 0)];
      expect(identical(withHeardWordTimes(bare, words), bare), isTrue);
    });

    test('a kept heard row without word times shows them', () {
      final words = said('Привет ёлка. Как дела', start: 1);
      final heard = judged(words);
      final old = HeardLyrics(
        outcome: heard.outcome,
        lines: [
          for (final line in heard.lines)
            LyricLine(line.text, startMs: line.startMs, endMs: line.endMs),
        ],
        words: heard.words,
        model: heard.model,
        language: heard.language,
        confidence: heard.confidence,
        russianConfidence: heard.russianConfidence,
        rough: heard.rough,
        wordCount: heard.wordCount,
        loudSeconds: heard.loudSeconds,
        heardAtMs: heard.heardAtMs,
      );
      expect(old.lyrics!.lines, heard.lyrics!.lines);
      expect(old.lyrics!.hasWordTimes, isTrue);
    });
  });

  group('judgeHeard', () {
    final many = said(List.filled(25, 'слово').join(' '));
    final few = said('один два три');

    test('enough words show as lines', () {
      final heard = judged(many);
      expect(heard.outcome, HeardOutcome.words);
      expect(heard.rough, isFalse);
      expect(heard.wordCount, 25);
      expect(heard.lyrics!.source, heardSource);
      expect(heard.lyrics!.timed, isTrue);
    });

    test('few words and quiet vocals: no singing found', () {
      final heard = judged(few, loud: 0.4);
      expect(heard.outcome, HeardOutcome.noSinging);
      expect(heard.lines, isEmpty);
      expect(heard.words, isEmpty);
      expect(heard.lyrics, isNull);
      expect(heard.wordCount, 3);
    });

    test('a short loud sung passage is singing: shown, rough', () {
      // Four sure words in 3 s of loud vocals (Codex review).
      final heard = judged(said('Я здесь и там'), loud: 3);
      expect(heard.outcome, HeardOutcome.words);
      expect(heard.rough, isTrue);
      // The instrumental of the research: 0.4 s.
      expect(judged(few, loud: 0.4).outcome, HeardOutcome.noSinging);
    });

    test('few words over loud vocals show, marked rough', () {
      final heard = judged(few, loud: 90);
      expect(heard.outcome, HeardOutcome.words);
      expect(heard.rough, isTrue);
    });

    test('many words over quiet vocals still show', () {
      expect(judged(many, loud: 1).outcome, HeardOutcome.words);
    });

    test('no words over loud vocals: none made out', () {
      final heard = judged(const [], model: null, loud: 80);
      expect(heard.outcome, HeardOutcome.noWords);
      expect(heard.lyrics, isNull);
      expect(
        judged(const [], model: null, loud: 0).outcome,
        HeardOutcome.noSinging,
      );
    });

    test('rough below each model mark', () {
      expect(judged(many, confidence: 0.929).rough, isTrue);
      expect(judged(many, confidence: 0.93).rough, isFalse);
      expect(
        judged(many, model: HeardModel.whisper, confidence: 0.919).rough,
        isTrue,
      );
      expect(
        judged(many, model: HeardModel.whisper, confidence: 0.92).rough,
        isFalse,
      );
    });

    test('Chinese words count in their own text, not as nothing', () {
      // 21 characters in 3 words: past the floor, so not "no singing".
      final words = said('我爱你我爱你我 爱你我爱你我爱 你我爱你我爱你');
      final heard = judged(words, model: HeardModel.whisper, loud: 0);
      expect(heard.wordCount, 21);
      expect(heard.outcome, HeardOutcome.words);
    });
  });

  group('stored heard lyrics', () {
    late LibraryStore store;
    setUp(() => store = LibraryStore.open(':memory:'));
    tearDown(() => store.close());

    test('round trip with Cyrillic and CJK', () {
      final words = [
        ...said('Привет, ёлка. Как дела', start: 1),
        HeardWord(10, 11.5, '我爱你。', 0.81234),
        HeardWord(11.5, 12, '?', null),
        HeardWord(12.25, 13, 'ありがとう', 0.7),
      ];
      final heard = judgeHeard(
        model: HeardModel.whisper,
        words: words,
        confidence: 0.83,
        russianConfidence: 0.61,
        language: 'ru',
        loud: 42.5,
        songMs: 30000,
        heardAtMs: 1234,
        audioBytes: 5555,
        bundles: 'hear-words-1 whisper-turbo-1',
        askedLanguage: 'ru',
      );
      store.saveHeardLyrics('1_2', heard);
      final back = store.heardLyricsOf('1_2')!;
      expect(back.outcome, HeardOutcome.words);
      expect(back.lines, heard.lines);
      expect(back.lines.first.text, 'Привет, ёлка.');
      expect(back.lines.any((line) => line.text.contains('我爱你。')), isTrue);
      expect(
        [for (final word in back.words) word.text],
        [for (final word in words) word.text],
      );
      expect(back.words[4].start, 10);
      expect(back.words[4].confidence, 0.812);
      expect(back.words[5].confidence, isNull);
      expect(back.words[6].start, 12.25);
      expect(back.model, HeardModel.whisper);
      expect(back.language, 'ru');
      expect(back.confidence, 0.83);
      expect(back.russianConfidence, 0.61);
      expect(back.rough, heard.rough);
      expect(back.wordCount, heard.wordCount);
      expect(back.loudSeconds, 42.5);
      expect(back.audioBytes, 5555);
      expect(back.bundles, 'hear-words-1 whisper-turbo-1');
      expect(back.heardAtMs, 1234);
      expect(back.askedLanguage, 'ru');
      expect(back.lyrics, heard.lyrics);
      // Heard on the app's own choice: no language asked for.
      store.saveHeardLyrics('1_5', judged(many()));
      expect(store.heardLyricsOf('1_5')!.askedLanguage, isNull);
    });

    test('the language picked for a song is kept until Automatic '
        '(plan 10 I2j)', () {
      expect(store.hearLanguageOf('1_2'), isNull);
      store.saveHearLanguage('1_2', 'ru');
      store.saveHearLanguage('1_3', 'uk');
      expect(store.hearLanguageOf('1_2'), 'ru');
      store.saveHearLanguage('1_2', 'en');
      expect(store.hearLanguageOf('1_2'), 'en');
      expect(store.hearLanguageOf('1_3'), 'uk');
      store.saveHearLanguage('1_2', null);
      expect(store.hearLanguageOf('1_2'), isNull);
      expect(store.hearLanguageOf('1_3'), 'uk');
      // Forgetting the heard words keeps the pick.
      store.saveHeardLyrics('1_3', judged(many()));
      store.saveHeardLyrics('1_3', null);
      expect(store.hearLanguageOf('1_3'), 'uk');
    });

    test('no singing found keeps no lines; null forgets', () {
      store.saveHeardLyrics('1_3', judged(said('ох'), loud: 0));
      final back = store.heardLyricsOf('1_3')!;
      expect(back.outcome, HeardOutcome.noSinging);
      expect(back.lines, isEmpty);
      expect(back.words, isEmpty);
      expect(back.model, isNull);
      expect(back.lyrics, isNull);
      store.saveHeardLyrics('1_3', null);
      expect(store.heardLyricsOf('1_3'), isNull);
      expect(store.heardLyricsOf('never'), isNull);
    });

    test('a newer row replaces the older; sources stay apart', () {
      store.saveLyrics(
        'vk',
        '1_4',
        const Lyrics(source: 'vk', lines: [LyricLine('Слова')]),
      );
      store.saveHeardLyrics('1_4', judged(said('ох'), loud: 0));
      store.saveHeardLyrics('1_4', judged(many()));
      expect(store.heardLyricsOf('1_4')!.outcome, HeardOutcome.words);
      // The sources' rows know nothing of it, and it of them.
      expect(store.lyricsOf('heard', '1_4'), isNull);
      expect(store.lyricsOf('vk', '1_4')!.lyrics!.lines.single.text, 'Слова');
      store.saveLyrics('vk', '1_4', null);
      expect(store.heardLyricsOf('1_4'), isNotNull);
    });
  });
}

List<HeardWord> many() => said(List.filled(25, 'word').join(' '));
