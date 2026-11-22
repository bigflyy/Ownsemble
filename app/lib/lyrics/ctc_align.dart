// CTC forced alignment: places a known letter sequence on a speech model's
// per-frame letter probabilities (plan 10 G1).
//
// The model (MMS_FA, wav2vec2) gives, for every 20 ms frame, a log
// probability for each of its letters and for the CTC "blank" (no new
// letter here). Forced alignment finds the single most likely way to read
// the given letters in order across all frames (the Viterbi path), which
// tells where each letter, and so each word and line, is sung. This is the
// same computation as torchaudio.functional.forced_align plus merge_tokens,
// which the Python research used (experiments/f2-timing).
import 'dart:math' as math;
import 'dart:typed_data';

/// One letter of the target sequence as placed on the frames: it covers
/// frames [start, end) and [score] is its mean probability there (0..1).
class TokenSpan {
  const TokenSpan(this.token, this.start, this.end, this.score);

  /// The letter's column in the emission.
  final int token;
  final int start;
  final int end;
  final double score;
}

/// The model's output for a stretch of audio: [frames] rows of [columns]
/// log probabilities each, row after row.
class Emission {
  Emission(this.values, this.columns)
    : assert(values.length % columns == 0),
      frames = values.length ~/ columns;

  final Float32List values;
  final int columns;
  final int frames;

  /// The first [count] frames only (a view, nothing copied).
  Emission head(int count) => Emission(
    Float32List.sublistView(values, 0, math.min(count, frames) * columns),
    columns,
  );
}

/// Thrown when the letters cannot fit the frames (each letter needs at least
/// one frame, and two equal letters in a row need a blank frame between).
class AlignmentTooLong implements Exception {
  const AlignmentTooLong(this.letters, this.frames);
  final int letters;
  final int frames;

  @override
  String toString() => 'AlignmentTooLong: $letters letters, $frames frames';
}

/// The Viterbi path of [targets] (letter columns, none of them [blank])
/// through [emission], merged into one span per target letter, in order.
///
/// A target equal to `emission.columns` is the "*" token: a letter that
/// matches any frame with the log probability [starLogProb] (MMS_FA's
/// with_star, used between lines so audio the lyrics do not cover need not
/// be forced onto words).
List<TokenSpan> forcedAlign(
  Emission emission,
  List<int> targets, {
  int blank = 0,
  double starLogProb = 0,
}) {
  final frames = emission.frames;
  final columns = emission.columns;
  final values = emission.values;
  final letters = targets.length;
  var repeats = 0;
  for (var i = 1; i < letters; i++) {
    if (targets[i] == targets[i - 1]) repeats++;
  }
  if (letters == 0 || letters + repeats > frames) {
    throw AlignmentTooLong(letters, frames);
  }

  // The extended sequence: blank, letter 1, blank, letter 2, ..., blank.
  final states = 2 * letters + 1;
  final label = Int32List(states);
  for (var s = 0; s < states; s++) {
    label[s] = s.isOdd ? targets[s ~/ 2] : blank;
  }
  // Whether state s may be reached by skipping the blank before it (only a
  // letter that differs from the letter two states back).
  final canSkip = Uint8List(states);
  for (var s = 2; s < states; s++) {
    if (s.isOdd && label[s] != label[s - 2]) canSkip[s] = 1;
  }

  double logProb(int frame, int column) =>
      column == columns ? starLogProb : values[frame * columns + column];

  const minusInfinity = double.negativeInfinity;
  var previous = Float64List(states)..fillRange(0, states, minusInfinity);
  var current = Float64List(states);
  // Which step led to each state: 0 stay, 1 from s - 1, 2 from s - 2.
  // Two bits per state and frame, so a long song stays a few megabytes.
  final rowBytes = (states + 3) >> 2;
  final steps = Uint8List(rowBytes * frames);

  previous[0] = logProb(0, label[0]);
  if (states > 1) previous[1] = logProb(0, label[1]);
  for (var t = 1; t < frames; t++) {
    // States that can still reach the end in the frames left, and that
    // can have been reached in the frames so far.
    final first = math.max(0, states - 2 * (frames - t));
    final last = math.min(states - 1, 2 * t + 1);
    current.fillRange(0, states, minusInfinity);
    final row = t * rowBytes;
    for (var s = first; s <= last; s++) {
      final stay = previous[s];
      final step = s > 0 ? previous[s - 1] : minusInfinity;
      final skip = canSkip[s] == 1 ? previous[s - 2] : minusInfinity;
      double best;
      int from;
      if (skip > step && skip > stay) {
        best = skip;
        from = 2;
      } else if (step > stay) {
        best = step;
        from = 1;
      } else {
        best = stay;
        from = 0;
      }
      if (best == minusInfinity) continue;
      current[s] = best + logProb(t, label[s]);
      steps[row + (s >> 2)] |= from << ((s & 3) * 2);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }

  var s = states > 1 && previous[states - 1] <= previous[states - 2]
      ? states - 2
      : states - 1;
  final path = Int32List(frames);
  final probability = Float64List(frames);
  for (var t = frames - 1; t >= 0; t--) {
    path[t] = label[s];
    probability[t] = math.exp(logProb(t, label[s]));
    if (t > 0) {
      s -= (steps[t * rowBytes + (s >> 2)] >> ((s & 3) * 2)) & 3;
    }
  }

  // Runs of one letter become spans; a letter that occurs twice in a row
  // in the targets is always split by a blank, so runs map to targets.
  final spans = <TokenSpan>[];
  var start = 0;
  for (var t = 1; t <= frames; t++) {
    if (t < frames && path[t] == path[start]) continue;
    if (path[start] != blank) {
      var sum = 0.0;
      for (var k = start; k < t; k++) {
        sum += probability[k];
      }
      spans.add(TokenSpan(path[start], start, t, sum / (t - start)));
    }
    start = t;
  }
  return spans;
}
