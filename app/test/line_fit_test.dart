import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/ctc_align.dart';
import 'package:ownsemble/lyrics/line_fit.dart';

/// A made-up emission of [frames] frames: every frame is blank (log
/// probability near 0) unless [letters] puts a letter there, e.g.
/// {5: 'a'} makes frame 5 an almost sure "a".
Emission fakeEmission(int frames, Map<int, String> letters) {
  final columns = mmsLabels.length;
  final values = Float32List(frames * columns);
  for (var t = 0; t < frames; t++) {
    final letter = letters[t];
    for (var c = 0; c < columns; c++) {
      final sure = letter == null ? c == 0 : mmsLabels[c] == letter;
      values[t * columns + c] = sure ? math.log(0.98) : math.log(0.02 / 27);
    }
  }
  return Emission(values, columns);
}

int column(String letter) => mmsLabels.indexOf(letter);

void main() {
  group('forcedAlign', () {
    test('puts each letter on the frame that says it', () {
      final emission = fakeEmission(20, {4: 'a', 9: 'b', 15: 'c'});
      final spans = forcedAlign(emission, [
        column('a'),
        column('b'),
        column('c'),
      ]);
      expect([for (final s in spans) s.start], [4, 9, 15]);
      expect([for (final s in spans) s.end], [5, 10, 16]);
      expect(spans.first.score, closeTo(0.98, 1e-6));
    });

    test('a doubled letter is read twice, with a blank between', () {
      final emission = fakeEmission(12, {3: 'l', 4: 'l', 6: 'l'});
      final spans = forcedAlign(emission, [column('l'), column('l')]);
      expect(spans, hasLength(2));
      expect(spans[0].end, lessThan(spans[1].start));
    });

    test('too many letters for the frames is refused', () {
      final emission = fakeEmission(3, {});
      expect(
        () => forcedAlign(emission, [column('a'), column('a'), column('b')]),
        throwsA(isA<AlignmentTooLong>()),
      );
    });

    test('the star token takes audio the letters do not need', () {
      // "ab" is sung at frames 30-31; frames 5-6 hold an "a" and "b" that
      // belong to something else. A star before the line may absorb them.
      final emission = fakeEmission(40, {5: 'a', 6: 'b', 30: 'a', 31: 'b'});
      final star = emission.columns;
      final spans = forcedAlign(emission, [
        star,
        column('a'),
        column('b'),
        star,
      ]);
      expect(spans, hasLength(4));
      expect(spans.first.token, star);
      // Either reading costs the same; both must be valid placements.
      expect([5, 30], contains(spans[1].start));
    });
  });

  group('romanize', () {
    test('Cyrillic becomes the research table letters', () {
      final r = romanize('Привет, мир! Ёлка и хлеб');
      expect(r.words, ['privet', 'mir', 'yolka', 'i', 'hleb']);
      expect(r.kept, r.letters);
    });

    test('apostrophes stay inside words only', () {
      expect(romanize("Don't 'cause rock’n’roll'").words, [
        "don't",
        'cause',
        "rock'n'roll",
      ]);
    });

    test('letters of other scripts are dropped and counted', () {
      final r = romanize('ab 東京');
      expect(r.words, ['ab']);
      expect(r.letters, 4);
      expect(r.kept, 2);
    });
  });

  test('sungLines ends a line at the next one, at most 8 s on', () {
    final lines = sungLines([
      (startMs: 1000, endMs: null, text: 'one'),
      (startMs: 3000, endMs: null, text: ' '),
      (startMs: 5000, endMs: null, text: 'two'),
      (startMs: 30000, endMs: 31000, text: 'three'),
      (startMs: null, endMs: null, text: 'untimed'),
    ]);
    expect([for (final l in lines) l.text], ['one', 'two', 'three']);
    expect(lines[0].end, 3);
    expect(lines[1].end, 13);
    expect(lines[2].end, 31);
  });

  test('alignLines and fitLines place each line where it is sung', () {
    // Three one-word lines, sung 1 s later than the lyrics say.
    final emission = fakeEmission(400, {
      100: 'a',
      101: 'b',
      200: 'c',
      201: 'd',
      300: 'e',
      301: 'f',
    });
    final fitted = fitLines(emission, const [
      SungLine(1, 2, 'ab'),
      SungLine(3, 4, 'cd'),
      SungLine(5, 6, 'ef'),
    ], 0.02);
    expect([for (final l in fitted) l.start], [2, 4, 6]);
    expect([for (final l in fitted) l.delta], [1, 1, 1]);
    for (final line in fitted) {
      expect(line.localDev, 0);
      expect(line.stepDev, 0);
      expect(line.starAgree, 0);
      expect(line.sure, greaterThan(sureAt));
    }
  });

  group('sure and fittedStarts', () {
    // A line with a low score is also made far off its neighbours, since a
    // zero score alone still leaves the formula at 0.86.
    FittedLine line(double lyric, double start, double score) => FittedLine(
      index: 0,
      lyricStart: lyric,
      start: start,
      score: score,
      starAgree: 0,
    )..localDev = score < 0.5 ? 100 : 0;

    test('the G0b formula', () {
      final l = line(0, 0, 0.5)
        ..localDev = 1
        ..stepDev = 0.5;
      final z =
          1.80 + 5.287 * 0.5 - 1.128 * math.log(2) - 1.170 * math.log(1.5);
      expect(l.sure, closeTo(1 / (1 + math.exp(-z)), 1e-12));
    });

    test('unsure lines take their sure neighbours shift', () {
      final lines = [
        line(10, 12, 0.9), // sure, shift 2
        line(20, 80, 0.0), // unsure: between shifts 2 and 4
        line(30, 34, 0.9), // sure, shift 4
        line(40, 0, 0.0), // unsure, after the last sure one
      ];
      expect(fittedStarts(lines), [12, 23, 34, 44]);
    });

    test('no sure line keeps the lyrics as they are', () {
      expect(fittedStarts([line(10, 50, 0), line(20, 60, 0)]), [10, 20]);
    });
  });
}
