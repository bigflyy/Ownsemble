// Unit tests for plan 10 J4 and J5: the fit's word times (the aligner's
// word spans mapped onto the words shown, kept with the fit in the library,
// put on the shown lines in place of a source's own word times) and word
// times through the user's edits.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/lyrics/fitted_lines.dart';
import 'package:ownsemble/lyrics/line_fit.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_edit.dart';
import 'package:ownsemble/lyrics/lyrics_editor.dart';

void main() {
  group('wordTimesOnText', () {
    test('one aligner word per word shown, punctuation kept on screen', () {
      expect(
        wordTimesOnText('Hello, world!', 'Hello, world!', const [
          (1.0, 1.4),
          (1.5, 2.25),
        ]),
        const [WordTime(1000, 1400), WordTime(1500, 2250)],
      );
    });

    test('Cyrillic words map through their romanized letters', () {
      expect(
        wordTimesOnText('Ночь, улица', 'Ночь, улица', const [
          (0.5, 0.9),
          (1.0, 1.6),
        ]),
        const [WordTime(500, 900), WordTime(1000, 1600)],
      );
    });

    test('a word the aligner splits runs from its first to its last part', () {
      // romanize("rock-n-roll") is three aligner words.
      expect(
        wordTimesOnText('rock-n-roll baby', 'rock-n-roll baby', const [
          (1.0, 1.2),
          (1.2, 1.3),
          (1.3, 1.7),
          (1.8, 2.0),
        ]),
        const [WordTime(1000, 1700), WordTime(1800, 2000)],
      );
    });

    test('digits and dashes get no time; the words around them do', () {
      expect(
        wordTimesOnText('go 99 - go', 'go 99 - go', const [
          (1.0, 1.2),
          (2.0, 2.2),
        ]),
        const [WordTime(1000, 1200), null, null, WordTime(2000, 2200)],
      );
    });

    test('a repeat mark the fit left out gets no time', () {
      expect(
        wordTimesOnText('Hello again x2', 'Hello again', const [
          (1.0, 1.2),
          (1.3, 1.6),
        ]),
        const [WordTime(1000, 1200), WordTime(1300, 1600), null],
      );
    });

    test('words that do not line up give none', () {
      expect(wordTimesOnText('one two', 'one two', const [(1.0, 1.2)]), isNull);
      expect(
        wordTimesOnText('one two', 'other words', const [
          (1.0, 1.2),
          (1.3, 1.5),
        ]),
        isNull,
      );
      expect(wordTimesOnText('99', '99', const []), isNull);
    });
  });

  group('kept fit words', () {
    const lyrics = Lyrics(
      source: 'lrclib',
      lines: [
        LyricLine('Ночь улица', startMs: 1000),
        LyricLine('', startMs: 3000),
        LyricLine('фонарь аптека', startMs: 5000),
      ],
    );
    final fit = StoredFit(
      lyricsHash: lyricsHashOf(lyrics),
      audioBytes: 4000000,
      starts: const [1500, 3500, 5600],
      sureShare: 0.66,
      fittedAtMs: 9,
      words: const [
        [WordTime(1500, 1900), WordTime(2000, 2600)],
        null,
        null,
      ],
    );

    test('words round trip through the library; old fits have none', () {
      final store = LibraryStore.open(':memory:');
      addTearDown(store.close);
      store.saveLyricsFit('1_1', 'lrclib', fit);
      final kept = store.lyricsFitOf('1_1', 'lrclib')!;
      expect(kept.hasWords, isTrue);
      expect(sameFitWords(kept.words, fit.words), isTrue);
      store.saveLyricsFit(
        '1_1',
        'vk',
        const StoredFit(
          lyricsHash: 'x',
          audioBytes: 1,
          starts: [1, 2, 3],
          sureShare: 1,
          fittedAtMs: 1,
        ),
      );
      final old = store.lyricsFitOf('1_1', 'vk')!;
      expect(old.words, isNull);
      expect(old.hasWords, isFalse);
    });

    test('a fit with only null lines has no words', () {
      const empty = StoredFit(
        lyricsHash: 'x',
        audioBytes: 1,
        starts: [1],
        sureShare: 1,
        fittedAtMs: 1,
        words: [null],
      );
      expect(empty.hasWords, isFalse);
      expect(empty.wordsToJson(), isNull);
    });

    test('the fit\'s words replace the line\'s own; others move along', () {
      const own = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine(
            'Ночь улица',
            startMs: 1000,
            words: [WordTime(1000, 1300), WordTime(1400, 1800)],
          ),
          LyricLine('', startMs: 3000),
          LyricLine(
            'фонарь аптека',
            startMs: 5000,
            words: [WordTime(5000, 5300), WordTime(5400, 5900)],
          ),
        ],
      );
      final shown = withStarts(own, fit.starts!, words: fit.words);
      expect(shown.lines[0].words, fit.words![0]);
      // The third line has no fit words: its own move with its start.
      expect(shown.lines[2].words, const [
        WordTime(5600, 5900),
        WordTime(6000, 6500),
      ]);
      expect(shown.lines[2].startMs, 5600);
    });

    test('the fit\'s hash does not change when lyrics gain word times', () {
      const stamped = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine(
            'Ночь улица',
            startMs: 1000,
            words: [WordTime(1000, 1300), WordTime(1400, 1800)],
          ),
          LyricLine('', startMs: 3000),
          LyricLine('фонарь аптека', startMs: 5000),
        ],
      );
      expect(fit.isFor(stamped), isTrue);
    });
  });

  group('edits keep word times (J5)', () {
    const start = [
      LyricLine(
        'Ночь улица',
        startMs: 1000,
        words: [WordTime(1000, 1400), WordTime(1500, 2000)],
      ),
      LyricLine(
        'фонарь аптека',
        startMs: 3000,
        words: [WordTime(3000, 3400), WordTime(3500, 4000)],
      ),
      LyricLine('', startMs: 5000),
    ];

    test('untouched lines keep them; a changed text drops them', () {
      final editor = LyricsEditor(start)..setText(1, 'фонарь, аптека');
      expect(editor.result[0].words, start[0].words);
      expect(editor.result[1].words, isNull);
    });

    test('a moved start moves the words; a cleared one drops them', () {
      final editor = LyricsEditor(start)..nudge(0, 500);
      expect(editor.result[0].startMs, 1500);
      expect(editor.result[0].words, const [
        WordTime(1500, 1900),
        WordTime(2000, 2500),
      ]);
      editor.setStart(0, null);
      expect(editor.result[0].words, isNull);
    });

    test('pasted text keeps the words of lines left as they were', () {
      final editor = LyricsEditor(start)
        ..applyText('Ночь улица\nфонарь аптека!\n');
      expect(editor.result[0].words, start[0].words);
      expect(editor.result[1].words, isNull, reason: 'corrected line');
    });

    test('stored and shown edits keep words of lines lit on their own', () {
      final stored = storableEditLines(start);
      expect(stored[0].words, start[0].words);
      final shown = editForShow([
        ...stored,
        const LyricLine(
          'late line',
          startMs: 500,
          words: [WordTime(500, 600), WordTime(600, 700)],
        ),
      ]);
      expect(shown.lines[0].words, start[0].words);
      expect(shown.lines[3].passed, isTrue);
      expect(shown.lines[3].words, isNull, reason: 'lit with the line above');
    });
  });
}
