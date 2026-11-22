// Fitting timed lyric lines to one recording (plan 10 G1, research in
// docs/plans/10-lyrics.md "F2 findings", "F2 addendum" and "G0b findings").
//
// The lines' words are placed on the recording by forced alignment
// (ctc_align.dart). Each line then gets a new start and a "sure" value
// from four signals the research found to tell right lines from wrong
// ones. Sure lines keep the aligner's start; the others are moved by the
// shift of their sure neighbours. Everything here mirrors
// experiments/f2-timing/timing_probe.py and line_confidence.py, so the
// app reproduces the measured numbers.
import 'dart:math' as math;

import 'ctc_align.dart';

/// MMS_FA's letters in the order of the model's output columns; column 0
/// is the CTC blank.
const mmsLabels = [
  '-', 'a', 'i', 'e', 'n', 'o', 'u', 't', 's', 'r', 'm', 'k', 'l', 'd', //
  'g', 'h', 'y', 'b', 'p', 'w', 'c', 'v', 'j', 'z', 'f', "'", 'q', 'x',
];

/// Seconds of audio per emission frame for MMS_FA (320 samples at 16 kHz).
const mmsSecondsPerFrame = 0.02;

/// A line is sure at or above this value (G0b: keeps 88% of studio lines,
/// 97% of them right; 83% of live lines, 93% right).
const sureAt = 0.7;

// Cyrillic to Latin as the research had it (timing_probe.py CYRILLIC);
// not the app's search transliteration, whose spellings differ.
const _cyrillic = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo', //
  'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
  'ф': 'f', 'х': 'h', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
  'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
  'і': 'i', 'ї': 'yi', 'є': 'ye', 'ґ': 'g',
};

final _letter = RegExp(r'\p{L}', unicode: true);

/// A line's words in the aligner's letters (a-z and the apostrophe), and
/// the share of the line's letters that could be kept.
({List<String> words, int letters, int kept}) romanize(String text) {
  var letters = 0;
  var kept = 0;
  final out = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    if (_letter.hasMatch(char)) {
      letters++;
      if (rune >= 0x61 && rune <= 0x7a) {
        out.write(char);
        kept++;
      } else if (_cyrillic.containsKey(char)) {
        out.write(_cyrillic[char]);
        kept++;
      } else {
        out.write(' ');
      }
    } else if (char == "'" || char == '’') {
      out.write("'");
    } else {
      out.write(' ');
    }
  }
  final words = [
    for (final word in out.toString().split(RegExp(r'\s+')))
      if (_stripApostrophes(word).isNotEmpty) _stripApostrophes(word),
  ];
  return (words: words, letters: letters, kept: kept);
}

String _stripApostrophes(String word) {
  var a = 0;
  var b = word.length;
  while (a < b && word[a] == "'") {
    a++;
  }
  while (b > a && word[b - 1] == "'") {
    b--;
  }
  return word.substring(a, b);
}

/// A timed lyric line as the fit reads it.
class SungLine {
  const SungLine(this.start, this.end, this.text);

  /// Seconds.
  final double start;
  final double end;
  final String text;
}

/// The lines that have words and a start, as the research read them: a
/// line without its own end ends where the next begins, and at most 8 s
/// after its start, so a long instrumental does not count as singing.
List<SungLine> sungLines(
  List<({int? startMs, int? endMs, String text})> lines,
) {
  final timed = [
    for (final line in lines)
      if (line.startMs != null) line,
  ];
  final result = <SungLine>[];
  for (var i = 0; i < timed.length; i++) {
    final start = timed[i].startMs! / 1000;
    final following = i + 1 < timed.length
        ? timed[i + 1].startMs! / 1000
        : start + 8;
    var end = timed[i].endMs != null ? timed[i].endMs! / 1000 : following;
    end = [end, following, start + 8].reduce(math.min);
    if (timed[i].text.trim().isNotEmpty && end > start) {
      result.add(SungLine(start, end, timed[i].text));
    }
  }
  return result;
}

/// One word as placed: frames [start, end), mean letter probability, and
/// how many letters it has.
class PlacedWord {
  const PlacedWord(this.start, this.end, this.score, this.letters);
  final int start;
  final int end;
  final double score;
  final int letters;
}

/// Aligns every line's words; returns, per line, its placed words (null for
/// a line without words). With [star], a "*" token sits before every line
/// and after the last one (G0b: log probability 0).
List<List<PlacedWord>?> alignLines(
  Emission emission,
  List<List<String>> lineWords, {
  bool star = false,
}) {
  final starColumn = emission.columns;
  final targets = <int>[];
  // For every target: line and word, or -1 for a "*".
  final ownerLine = <int>[];
  final ownerWord = <int>[];
  for (var line = 0; line < lineWords.length; line++) {
    final words = lineWords[line];
    if (words.isEmpty) continue;
    if (star) {
      targets.add(starColumn);
      ownerLine.add(-1);
      ownerWord.add(-1);
    }
    for (var w = 0; w < words.length; w++) {
      for (final rune in words[w].runes) {
        targets.add(mmsLabels.indexOf(String.fromCharCode(rune)));
        ownerLine.add(line);
        ownerWord.add(w);
      }
    }
  }
  if (star) {
    targets.add(starColumn);
    ownerLine.add(-1);
    ownerWord.add(-1);
  }
  final result = List<List<PlacedWord>?>.filled(lineWords.length, null);
  if (targets.isEmpty) return result;
  final spans = forcedAlign(emission, targets);
  if (spans.length != targets.length) {
    throw StateError('${spans.length} spans for ${targets.length} letters');
  }
  // Letters gathered per line and word, in order.
  var k = 0;
  while (k < spans.length) {
    final line = ownerLine[k];
    if (line < 0) {
      k++;
      continue;
    }
    final word = ownerWord[k];
    final first = spans[k];
    var sum = 0.0;
    var count = 0;
    var last = first;
    while (k < spans.length && ownerLine[k] == line && ownerWord[k] == word) {
      sum += spans[k].score;
      last = spans[k];
      count++;
      k++;
    }
    (result[line] ??= []).add(
      PlacedWord(first.start, last.end, sum / count, count),
    );
  }
  return result;
}

/// What the fit found for one line.
class FittedLine {
  FittedLine({
    required this.index,
    required this.lyricStart,
    required this.start,
    required this.score,
    required this.starAgree,
  });

  /// The line's place in the [sungLines] list.
  final int index;

  /// Seconds, as the lyrics have it.
  final double lyricStart;

  /// Seconds, as the aligner placed it.
  final double start;

  /// Mean letter probability of the line's letters.
  final double score;

  /// How far the start moves (s) when the "*" token may absorb the audio
  /// between lines.
  final double starAgree;

  /// The line's shift against the median shift of the 3 lines before and
  /// the 3 after.
  double localDev = 0;

  /// The smaller jump in shift to the line before or after.
  double stepDev = 0;

  double get delta => start - lyricStart;

  /// 0..1: how likely the aligner's start is within 1 s of the singing
  /// (G0b's logistic formula).
  double get sure {
    final z =
        1.80 +
        5.287 * score -
        1.128 * math.log(1 + localDev) -
        1.170 * math.log(1 + stepDev) -
        2.138 * math.log(1 + starAgree);
    return 1 / (1 + math.exp(-z));
  }
}

/// Places [lines] on [emission] twice (plain and with "*") and returns the
/// placed lines with their signals. [secondsPerFrame] is the audio length
/// over the frame count.
List<FittedLine> fitLines(
  Emission emission,
  List<SungLine> lines,
  double secondsPerFrame,
) {
  final words = [for (final line in lines) romanize(line.text).words];
  final plain = alignLines(emission, words);
  final starred = alignLines(emission, words, star: true);
  final fitted = <FittedLine>[];
  for (var i = 0; i < lines.length; i++) {
    final placed = plain[i];
    if (placed == null) continue;
    var sum = 0.0;
    var count = 0;
    for (final word in placed) {
      sum += word.score * word.letters;
      count += word.letters;
    }
    final start = placed.first.start * secondsPerFrame;
    final starStart = starred[i]!.first.start * secondsPerFrame;
    fitted.add(
      FittedLine(
        index: i,
        lyricStart: lines[i].start,
        start: start,
        score: sum / count,
        starAgree: (starStart - start).abs(),
      ),
    );
  }
  for (var p = 0; p < fitted.length; p++) {
    final around = [
      for (var k = math.max(0, p - 3); k < math.min(fitted.length, p + 4); k++)
        if (k != p) fitted[k].delta,
    ];
    fitted[p].localDev = around.isEmpty
        ? 0
        : (fitted[p].delta - _median(around)).abs();
    final steps = [
      if (p > 0) (fitted[p].delta - fitted[p - 1].delta).abs(),
      if (p + 1 < fitted.length) (fitted[p].delta - fitted[p + 1].delta).abs(),
    ];
    fitted[p].stepDev = steps.isEmpty ? 0 : steps.reduce(math.min);
  }
  return fitted;
}

/// Final starts (s) per fitted line: a sure line keeps the aligner's start;
/// another gets its lyrics start moved by the shift of its sure neighbours
/// (interpolated by lyrics time between the one before and the one after,
/// the nearest one at the ends). No sure line: the lyrics as they are.
List<double> fittedStarts(List<FittedLine> fitted, {double at = sureAt}) {
  final sure = [
    for (final line in fitted)
      if (line.sure >= at) line,
  ];
  if (sure.isEmpty) return [for (final line in fitted) line.lyricStart];
  return [
    for (final line in fitted)
      line.sure >= at
          ? line.start
          : line.lyricStart + _interpolate(line.lyricStart, sure),
  ];
}

/// numpy.interp of the sure lines' shifts at lyrics time [t].
double _interpolate(double t, List<FittedLine> sure) {
  if (t <= sure.first.lyricStart) return sure.first.delta;
  if (t >= sure.last.lyricStart) return sure.last.delta;
  for (var k = 1; k < sure.length; k++) {
    final a = sure[k - 1];
    final b = sure[k];
    if (t <= b.lyricStart) {
      final span = b.lyricStart - a.lyricStart;
      if (span <= 0) return b.delta;
      return a.delta + (b.delta - a.delta) * (t - a.lyricStart) / span;
    }
  }
  return sure.last.delta;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
