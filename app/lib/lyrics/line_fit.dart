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
  const SungLine(this.start, this.end, this.text, {this.lineIndex = -1});

  /// Seconds.
  final double start;
  final double end;
  final String text;

  /// The line's place in the list [sungLines] read it from (-1 when made
  /// by hand).
  final int lineIndex;
}

/// The lines that have words and a start, as the research read them: a
/// line without its own end ends where the next begins, and at most 8 s
/// after its start, so a long instrumental does not count as singing.
List<SungLine> sungLines(
  List<({int? startMs, int? endMs, String text})> lines,
) {
  final timed = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startMs != null) (index: i, line: lines[i]),
  ];
  final result = <SungLine>[];
  for (var i = 0; i < timed.length; i++) {
    final start = timed[i].line.startMs! / 1000;
    final following = i + 1 < timed.length
        ? timed[i + 1].line.startMs! / 1000
        : start + 8;
    var end = timed[i].line.endMs != null
        ? timed[i].line.endMs! / 1000
        : following;
    end = [end, following, start + 8].reduce(math.min);
    if (timed[i].line.text.trim().isNotEmpty && end > start) {
      result.add(
        SungLine(start, end, timed[i].line.text, lineIndex: timed[i].index),
      );
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

// Plain words carry notes that are not sung (Codex review of H2): section
// headers, alone or with a number, a name or ":", and repeat marks.
final _header = RegExp(
  r'^(chorus|verse|bridge|intro|outro|pre-?chorus|post-?chorus|hook|refrain|'
  r'interlude|instrumental|solo|breakdown|'
  r'припев|куплет|бридж|проигрыш|вступление|интро|аутро|кода|'
  r'предприпев|пред-припев|соло)'
  r'(\s*\d+)?(\s*:.*)?$',
  caseSensitive: false,
  unicode: true,
);
final _repeatMark = RegExp(
  r'^[(\[]?\s*([xх×]\s*\d+|\d+\s*[xх×])\s*[)\]]?$',
  caseSensitive: false,
  unicode: true,
);
// A repeat mark after the words: in brackets ("(x2)", "[X3]"), or bare
// only in lower case ("x2"), since "an X2" may be sung (Codex review).
final _trailingRepeat = RegExp(
  r'\s+([(\[]\s*([xхX×Х]\s*\d+|\d+\s*[xхX×Х])\s*[)\]]|[xх×]\d+|\d+[xх×])$',
  unicode: true,
);
// A whole line that is one note in [ ]: "[Chorus]", "[Verse 2: Name]";
// not "[Oh] I won't go [oh]", which has words outside the brackets.
final _bracketNote = RegExp(r'^\[[^\[\]]*\]$');

/// Whether a line of plain words is a note rather than words sung: a whole
/// line in [ ], a section header ("Chorus:", "Verse 2", in brackets too),
/// or a repeat mark ("x2"). A line in ( ) is sung (backing vocals) unless
/// it is a header such as "(Instrumental)".
bool isUnsungLine(String text) {
  final line = text.trim();
  if (line.isEmpty) return false;
  if (_bracketNote.hasMatch(line)) return true;
  if (_repeatMark.hasMatch(line)) return true;
  final bare = line.startsWith('(') && line.endsWith(')')
      ? line.substring(1, line.length - 1).trim()
      : line;
  return _header.hasMatch(bare);
}

/// A sung line's words without a trailing repeat mark ("Hello x2").
String sungText(String text) => text.replaceFirst(_trailingRepeat, '').trim();

/// Plain words (H1): the song-level check passes when the words' mean
/// letter score beats the same lines in shuffled order by this much (H1:
/// no words of another song passed, 1 of 130 fitting pairs failed).
const plainGainAt = 0.03;

/// What the fit found for one line of plain words (no times of its own):
/// the signals of H1 ("H1 findings" in docs/plans/10-lyrics.md, mirrored
/// from experiments/f2-timing/plain_words.py).
class PlainFittedLine {
  PlainFittedLine({
    required this.index,
    required this.start,
    required this.end,
    required this.letters,
    required this.at,
    required this.score,
    required this.starAgree,
  });

  /// The line's place in the list of texts fitted.
  final int index;

  /// Seconds, as the aligner placed the line's first and last letters.
  final double start;
  final double end;

  /// The line's letters as the aligner reads them, and those of the placed
  /// lines before it.
  final int letters;
  final int at;

  /// Mean letter probability of the line's letters.
  final double score;

  /// How far the start moves (s) when the "*" token may absorb the audio
  /// between lines.
  final double starAgree;

  /// |ln(the line's letters per second / the placed lines' median)|.
  double rateDev = 0;

  /// The start against a straight line (start by letters sung) through the
  /// 3 placed lines before, and through the 3 after: the smaller miss (s).
  double paceOne = 0;

  /// 0..1: how likely the aligner's start is within 1 s of the singing
  /// (H1's logistic formula, no source times needed).
  double get sure {
    final z =
        1.599 +
        5.473 * score -
        2.561 * math.log(1 + starAgree) -
        1.082 * math.log(1 + paceOne) -
        1.013 * math.log(1 + rateDev);
    return 1 / (1 + math.exp(-z));
  }
}

/// Places plain [texts] (one per line; a line without letters the aligner
/// knows is left out) on [emission], twice (plain and with "*"), and
/// returns the placed lines with H1's signals.
List<PlainFittedLine> fitPlainLines(
  Emission emission,
  List<String> texts,
  double secondsPerFrame,
) {
  final words = [for (final text in texts) romanize(text).words];
  final plain = alignLines(emission, words);
  final starred = alignLines(emission, words, star: true);
  final fitted = <PlainFittedLine>[];
  var at = 0;
  for (var i = 0; i < texts.length; i++) {
    final placed = plain[i];
    if (placed == null) continue;
    var sum = 0.0;
    var count = 0;
    for (final word in placed) {
      sum += word.score * word.letters;
      count += word.letters;
    }
    final start = placed.first.start * secondsPerFrame;
    fitted.add(
      PlainFittedLine(
        index: i,
        start: start,
        // The research's frame end is past the last letter's frame
        // (torchaudio's merge_tokens), as [PlacedWord.end] is.
        end: placed.last.end * secondsPerFrame,
        letters: count,
        at: at,
        score: sum / count,
        starAgree: (starred[i]!.first.start * secondsPerFrame - start).abs(),
      ),
    );
    at += count;
  }
  if (fitted.isEmpty) return fitted;
  // The rate uses at least one frame, as the research's max(end - start,
  // spf) does.
  double rateOf(PlainFittedLine line) =>
      line.letters / math.max(line.end - line.start, secondsPerFrame);
  final songRate = _median([for (final line in fitted) rateOf(line)]);
  for (var p = 0; p < fitted.length; p++) {
    final line = fitted[p];
    line.rateDev = math.log(rateOf(line) / songRate).abs();
    final misses = <double>[
      for (final side in [
        fitted.sublist(math.max(0, p - 3), p),
        fitted.sublist(p + 1, math.min(fitted.length, p + 4)),
      ])
        ?_paceMiss(side, line),
    ];
    line.paceOne = misses.isEmpty ? 0 : misses.reduce(math.min);
  }
  return fitted;
}

/// How far [line]'s start is from the least-squares straight line (start
/// by letters sung) through [side]; null with fewer than 2 lines or no
/// spread in letters (numpy.polyfit's degree-1 fit in the research).
double? _paceMiss(List<PlainFittedLine> side, PlainFittedLine line) {
  if (side.length < 2) return null;
  final n = side.length;
  var sx = 0.0, sy = 0.0;
  for (final s in side) {
    sx += s.at;
    sy += s.start;
  }
  final mx = sx / n, my = sy / n;
  var sxx = 0.0, sxy = 0.0;
  for (final s in side) {
    sxx += (s.at - mx) * (s.at - mx);
    sxy += (s.at - mx) * (s.start - my);
  }
  if (sxx == 0) return null;
  final b = sxy / sxx;
  return (line.start - (my + b * (line.at - mx))).abs();
}

/// A seed for [shuffleGain] from the words themselves (32-bit FNV-1a over
/// the lines), so the same words get the same shuffles on every fit.
int plainSeedOf(List<String> texts) {
  var hash = 0x811c9dc5;
  for (final text in texts) {
    for (final unit in '$text\n'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
  }
  return hash;
}

/// The song-level check for plain words (H1): the mean (over placed lines)
/// of the lines' letter scores, minus the same mean for the same lines in
/// shuffled order on the same recording, averaged over [shuffles] orders
/// drawn from [seed] (so a refit gives the same verdict). Words of another
/// song score as badly in any order; the song's own words lose much of
/// their score when shuffled.
///
/// Every shuffle must change the order of the words (a song of one line
/// sung over and over has no other order: Codex review of H2). Null when
/// that cannot be told: fewer than 3 different lines, or no changed order
/// in 20 tries.
double? shuffleGain(
  Emission emission,
  List<String> texts,
  List<PlainFittedLine> fitted, {
  required int seed,
  int shuffles = 3,
}) {
  if (fitted.isEmpty) return null;
  final own =
      fitted.map((line) => line.score).reduce((a, b) => a + b) / fitted.length;
  final words = [
    for (final text in texts)
      if (romanize(text).words case final w when w.isNotEmpty) w,
  ];
  if ({for (final line in words) line.join(' ')}.length < 3) return null;
  // What the aligner reads: the letters in a row, with no line breaks. A
  // shuffle counts only when it changes them ("ha", "haha", "hahaha" read
  // the same in any order: Codex review of H2).
  String lettersOf(List<List<String>> lines) =>
      [for (final line in lines) ...line].join();
  final asSung = lettersOf(words);
  final random = math.Random(seed);
  var nullSum = 0.0;
  var nullCount = 0;
  for (var k = 0; k < shuffles; k++) {
    List<List<String>>? order;
    for (var attempt = 0; attempt < 20 && order == null; attempt++) {
      final drawn = [...words]..shuffle(random);
      if (lettersOf(drawn) != asSung) order = drawn;
    }
    if (order == null) return null;
    final placed = alignLines(emission, order);
    var sum = 0.0;
    var lines = 0;
    for (final line in placed) {
      if (line == null) continue;
      var s = 0.0;
      var c = 0;
      for (final word in line) {
        s += word.score * word.letters;
        c += word.letters;
      }
      sum += s / c;
      lines++;
    }
    if (lines == 0) continue;
    nullSum += sum / lines;
    nullCount++;
  }
  return nullCount == 0 ? null : own - nullSum / nullCount;
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
