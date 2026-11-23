import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/line_fit.dart';

import 'line_fit_test.dart' show fakeEmission;

/// An emission where line k's two letters ("ab", "cd", ...) are said at
/// frames 10 + 20k and 11 + 20k: six evenly paced lines.
const _letters = 'abcdefghijkl';
final _even = fakeEmission(140, {
  for (var k = 0; k < 6; k++) ...{
    10 + 20 * k: _letters[2 * k],
    11 + 20 * k: _letters[2 * k + 1],
  },
});
final _lines = [
  for (var k = 0; k < 6; k++) _letters.substring(2 * k, 2 * k + 2),
];

void main() {
  group('fitPlainLines', () {
    test('places every line where its letters are said, no times needed', () {
      final fitted = fitPlainLines(_even, _lines, 0.02);
      expect([for (final line in fitted) line.index], [0, 1, 2, 3, 4, 5]);
      expect(
        [for (final line in fitted) line.start],
        [for (var k = 0; k < 6; k++) closeTo((10 + 20 * k) * 0.02, 1e-9)],
      );
      expect(fitted.first.end, closeTo(12 * 0.02, 1e-9));
      expect([for (final line in fitted) line.at], [0, 2, 4, 6, 8, 10]);
      expect(fitted.first.score, closeTo(0.98, 1e-6));
    });

    test('evenly paced lines have no pace or rate miss and are sure', () {
      final fitted = fitPlainLines(_even, _lines, 0.02);
      for (final line in fitted) {
        expect(line.rateDev, closeTo(0, 1e-9));
        expect(line.paceOne, closeTo(0, 1e-9));
        expect(line.sure, greaterThan(sureAt));
      }
    });

    test(
      'a line out of pace with both neighbour sides misses by its offset',
      () {
        // Line 3 ("gh") is sung 0.2 s (10 frames) later than the pace says.
        final late = fakeEmission(160, {
          for (var k = 0; k < 6; k++) ...{
            10 + 20 * k + (k == 3 ? 10 : 0): _letters[2 * k],
            11 + 20 * k + (k == 3 ? 10 : 0): _letters[2 * k + 1],
          },
        });
        final fitted = fitPlainLines(late, _lines, 0.02);
        expect(fitted[3].paceOne, closeTo(0.2, 1e-9));
      },
    );

    test('lines without letters the aligner knows are left out', () {
      final fitted = fitPlainLines(_even, ['ab', '', '...', 'cd', 'ef'], 0.02);
      expect([for (final line in fitted) line.index], [0, 3, 4]);
    });

    test('the sure value is H1 formula', () {
      final line =
          PlainFittedLine(
              index: 0,
              start: 1,
              end: 2,
              letters: 10,
              at: 0,
              score: 0.4,
              starAgree: 0.5,
            )
            ..rateDev = 0.3
            ..paceOne = 1.2;
      final z =
          1.599 +
          5.473 * 0.4 -
          2.561 * math.log(1.5) -
          1.082 * math.log(2.2) -
          1.013 * math.log(1.3);
      expect(line.sure, closeTo(1 / (1 + math.exp(-z)), 1e-12));
    });
  });

  group('shuffleGain', () {
    test('the song own words beat their shuffled order', () {
      final fitted = fitPlainLines(_even, _lines, 0.02);
      final gain = shuffleGain(_even, _lines, fitted, seed: 7);
      expect(gain, isNotNull);
      expect(gain!, greaterThan(plainGainAt));
    });

    test('words of another song gain nothing over their shuffle', () {
      // Letters the recording never says: any order scores as badly.
      final other = ['mn', 'op', 'rs', 'tu', 'vw', 'yz'];
      final fitted = fitPlainLines(_even, other, 0.02);
      final gain = shuffleGain(_even, other, fitted, seed: 7);
      expect(gain, isNotNull);
      expect(gain!, lessThan(plainGainAt));
    });

    test('too few different lines cannot be checked', () {
      // A chorus sung over and over: every shuffle is the same order.
      final repeated = ['ab', 'ab', 'cd', 'ab', 'cd', 'ab'];
      final fitted = fitPlainLines(_even, repeated, 0.02);
      expect(shuffleGain(_even, repeated, fitted, seed: 1), isNull);
    });

    test(
      'lines whose every order gives the same letters cannot be checked',
      () {
        // "ha", "haha", "hahaha": any order is "hahahahahaha" to the aligner.
        final same = ['ha', 'haha', 'hahaha'];
        final fitted = fitPlainLines(_even, same, 0.02);
        expect(shuffleGain(_even, same, fitted, seed: 1), isNull);
      },
    );

    test('the seed comes from the words', () {
      expect(plainSeedOf(_lines), plainSeedOf([..._lines]));
      expect(plainSeedOf(_lines), isNot(plainSeedOf(_lines.reversed.toList())));
    });

    test('the same seed gives the same gain', () {
      final fitted = fitPlainLines(_even, _lines, 0.02);
      expect(
        shuffleGain(_even, _lines, fitted, seed: 3),
        shuffleGain(_even, _lines, fitted, seed: 3),
      );
    });
  });
}
