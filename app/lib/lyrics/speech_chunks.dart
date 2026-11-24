/// Where the singing is, and the chunks GigaAM hears it in (plan 10 I2c).
///
/// A port of GigaAmTranscriber's gigaam_app/vad.py (v0.7.0), which the
/// research used: Silero VAD gives a speech probability for each 512-sample
/// window of 16 kHz audio, and [ChunkFinder] turns those into speech
/// regions (silero-vad 6.2.1's get_speech_timestamps, MIT licence, Silero
/// Team, with use_max_poss_sil_at_max_speech) and packs the regions into
/// chunks of at most 25 s. The arithmetic follows the Python line by line,
/// including its float and integer mix and round(x, 1), so the chunks are
/// the same sample ranges and GigaAM hears the same audio.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Samples per Silero window at 16 kHz.
const sileroWindow = 512;

/// Samples of the previous window Silero v5+ wants in front of each one.
const sileroContext = 64;

/// Floats in Silero's recurrent state, shape [2, 1, 128].
const sileroStateSize = 2 * 128;

/// Windows per call of silero_vad_scan.onnx (about 33 s of audio; the
/// fastest block size in gigaam_app).
const sileroBlock = 1024;

const _rate = 16000;

/// Segmentation settings, as gigaam_app's VadOptions (its defaults).
class VadOptions {
  const VadOptions({
    this.threshold = 0.5,
    this.minSpeechMs = 300,
    this.maxSpeechSeconds = 25.0,
    this.minSilenceMs = 2000,
    this.speechPadMs = 250,
    this.maxDuration = 25.0,
    this.strictLimitDuration = 25.0,
    this.newChunkThreshold = 0.2,
  });

  /// A window at or above this probability is speech.
  final double threshold;

  /// Shorter speech regions are dropped.
  final int minSpeechMs;

  /// Longer regions are split at the longest pause inside.
  final double maxSpeechSeconds;

  /// A pause must last this long to end a region.
  final int minSilenceMs;

  /// Padding on both sides of each region.
  final int speechPadMs;

  /// Regions are merged into chunks up to this length (seconds).
  final double maxDuration;

  /// Longer chunks are split into equal parts.
  final double strictLimitDuration;

  /// Chunks this short or shorter are dropped (seconds).
  final double newChunkThreshold;
}

/// "Hear the words": the research's setting (plan 10 I1b), a low threshold
/// because sung vowels score lower than speech.
const hearWordsVad = VadOptions(threshold: 0.15);

/// One call of silero_vad_scan.onnx: the [state] (256 floats) and
/// [count] windows of 576 samples each in [windows]; gives the new state
/// and one probability per window.
typedef SileroScan = ({Float32List state, Float32List probabilities}) Function(
  Float32List state,
  Float32List windows,
  int count,
);

/// Runs Silero over [audio] (16 kHz mono) block by block, in order, and
/// calls [onBlock] with the first window's index and the block's
/// probabilities. The audio is zero-padded in front by the context and at
/// the end to whole windows, as gigaam_app's SileroVad.blocks.
void sileroBlocks(
  Float32List audio,
  SileroScan scan,
  void Function(int first, Float32List probabilities) onBlock, {
  int block = sileroBlock,
}) {
  final windowCount = math.max(
    1,
    (audio.length + sileroWindow - 1) ~/ sileroWindow,
  );
  const span = sileroContext + sileroWindow;
  var state = Float32List(sileroStateSize);
  for (var first = 0; first < windowCount; first += block) {
    final count = math.min(block, windowCount - first);
    final windows = Float32List(count * span);
    for (var w = 0; w < count; w++) {
      // Window i covers audio[i * 512 - 64, i * 512 + 512).
      final from = (first + w) * sileroWindow - sileroContext;
      for (var k = 0; k < span; k++) {
        final at = from + k;
        if (at >= 0 && at < audio.length) windows[w * span + k] = audio[at];
      }
    }
    final out = scan(state, windows, count);
    state = out.state;
    onBlock(first, out.probabilities);
  }
}

/// A chunk of audio to recognise: samples [start, end).
typedef SampleRange = ({int start, int end});

/// Turns window probabilities into recognition chunks as they arrive (see
/// gigaam_app's ChunkFinder): [feed] one probability at a time; chunks come
/// back once nothing later can change them; [finish] at the end.
class ChunkFinder {
  ChunkFinder(this.samples, VadOptions options)
    : _minSpeech = _rate * options.minSpeechMs / 1000,
      _pad = _rate * options.speechPadMs / 1000,
      _maxSpeech =
          _rate * options.maxSpeechSeconds -
          sileroWindow -
          2 * (_rate * options.speechPadMs / 1000),
      _minSilence = _rate * options.minSilenceMs / 1000,
      _threshold = options.threshold,
      _negThreshold = math.max(options.threshold - 0.15, 0.01),
      _maxLength = options.maxDuration * _rate,
      _hardLimit = options.strictLimitDuration * _rate,
      _minLength = options.newChunkThreshold * _rate;

  /// Length of the audio in samples.
  final int samples;

  final double _minSpeech;
  final double _pad;
  final double _maxSpeech;
  final double _minSilence;
  static const double _minSilenceAtMaxSpeech = _rate * 98 / 1000;
  final double _threshold;
  final double _negThreshold;
  final double _maxLength;
  final double _hardLimit;
  final double _minLength;

  // Stage 1, named as in silero-vad. The current region is open while
  // _currentStart is set (Python: a non-empty dict).
  var _triggered = false;
  int? _currentStart;
  var _tempEnd = 0;
  var _prevEnd = 0;
  var _nextStart = 0;
  final _possibleEnds = <(int, int)>[];

  // Stage 2: the last raw region, waiting for its successor.
  _Region? _waiting;

  // Stage 3: the chunk being built.
  (int, int)? _chunk;

  /// Final padded regions (for the speech time).
  final regions = <SampleRange>[];

  /// Adds the probability of window [index]; returns chunks now final.
  List<SampleRange> feed(int index, double probability) {
    final closed = _hysteresis(index, probability);
    return closed == null ? const [] : _padRegion(closed);
  }

  /// End of audio: every stage flushed; returns the remaining chunks.
  List<SampleRange> finish() {
    final chunks = <SampleRange>[];
    final start = _currentStart;
    if (start != null && samples - start > _minSpeech) {
      chunks.addAll(_padRegion(_Region(start, samples)));
    }
    _currentStart = null;
    final last = _waiting;
    if (last != null) {
      _waiting = null;
      last.end = math.min(samples, last.end + _pad).toInt();
      chunks.addAll(_group(last));
    }
    final chunk = _chunk;
    if (chunk != null && chunk.$2 - chunk.$1 > _minLength) {
      chunks.addAll(_split(chunk.$1, chunk.$2));
    }
    _chunk = null;
    return chunks;
  }

  /// Total speech in seconds; padded regions never overlap.
  double get speechSeconds =>
      regions.fold(0, (sum, r) => sum + r.end - r.start) / _rate;

  _Region? _hysteresis(int index, double probability) {
    final sample = sileroWindow * index;
    _Region? closed;
    // Speech is back after a pause: the pause may become a cut point.
    if (probability >= _threshold && _tempEnd != 0) {
      final silence = sample - _tempEnd;
      if (silence > _minSilenceAtMaxSpeech) {
        _possibleEnds.add((_tempEnd, silence));
      }
      _tempEnd = 0;
      if (_nextStart < _prevEnd) _nextStart = sample;
    }
    // Start of speech.
    if (probability >= _threshold && !_triggered) {
      _triggered = true;
      _currentStart = sample;
      return null;
    }
    // Region too long: cut at the longest pause seen inside it.
    if (_triggered && sample - _currentStart! > _maxSpeech) {
      if (_possibleEnds.isNotEmpty) {
        // Python's max() keeps the first of equal lengths.
        var best = _possibleEnds.first;
        for (final candidate in _possibleEnds) {
          if (candidate.$2 > best.$2) best = candidate;
        }
        final (end, length) = best;
        _prevEnd = end;
        closed = _Region(_currentStart!, _prevEnd);
        _currentStart = null;
        _nextStart = _prevEnd + length;
        if (_nextStart < _prevEnd + sample) {
          _currentStart = _nextStart;
        } else {
          _triggered = false;
        }
      } else {
        closed = _Region(_currentStart!, sample);
        _currentStart = null;
        _triggered = false;
      }
      _prevEnd = 0;
      _nextStart = 0;
      _tempEnd = 0;
      _possibleEnds.clear();
      if (!_triggered) return closed;
    }
    // Silence while in speech: the region ends once the pause is long.
    if (probability < _negThreshold && _triggered) {
      if (_tempEnd == 0) _tempEnd = sample;
      if (sample - _tempEnd < _minSilence) return closed;
      // Reached only with closed null: a forced cut above resets _tempEnd.
      final start = _currentStart!;
      if (_tempEnd - start > _minSpeech) closed = _Region(start, _tempEnd);
      _currentStart = null;
      _prevEnd = 0;
      _nextStart = 0;
      _tempEnd = 0;
      _triggered = false;
      _possibleEnds.clear();
    }
    return closed;
  }

  List<SampleRange> _padRegion(_Region region) {
    final previous = _waiting;
    if (previous == null) {
      region.start = math.max(0, region.start - _pad).toInt();
      _waiting = region;
      return const [];
    }
    _waiting = region;
    final gap = region.start - previous.end;
    if (gap < 2 * _pad) {
      // Close neighbours share the gap (Python's // floors).
      final half = _floorDiv(gap, 2);
      previous.end += half;
      region.start = math.max(0, region.start - half);
    } else {
      previous.end = math.min(samples, previous.end + _pad).toInt();
      region.start = math.max(0, region.start - _pad).toInt();
    }
    return _group(previous);
  }

  List<SampleRange> _group(_Region region) {
    // Silero reports seconds rounded to 0.1 s; the same rounding keeps the
    // chunks identical to gigaam_app's.
    final total = samples / _rate;
    final startSeconds = math.max(pythonRoundTenth(region.start / _rate), 0);
    final endSeconds = math.min(pythonRoundTenth(region.end / _rate), total);
    final start = (startSeconds * _rate).toInt();
    final end = (endSeconds * _rate).toInt();
    regions.add((start: start, end: end));
    final chunk = _chunk;
    if (chunk == null) {
      _chunk = (start, end);
      return const [];
    }
    var (chunkStart, chunkEnd) = chunk;
    var done = const <SampleRange>[];
    if (chunkEnd - chunkStart > _minLength && end - chunkStart > _maxLength) {
      done = _split(chunkStart, chunkEnd);
      chunkStart = start;
    }
    _chunk = (chunkStart, end);
    return done;
  }

  List<SampleRange> _split(int start, int end) {
    final length = end - start;
    if (length <= _hardLimit) return [(start: start, end: end)];
    final parts = (length / _hardLimit).toInt() + 1;
    final step = length / parts;
    return [
      for (var part = 0; part < parts; part++)
        (
          start: (start + part * step).toInt(),
          end: part < parts - 1 ? (start + (part + 1) * step).toInt() : end,
        ),
    ];
  }
}

class _Region {
  _Region(this.start, this.end);
  int start;
  int end;
}

int _floorDiv(int a, int b) => (a / b).floor();

/// Python's round(x, digits) for x >= 0: the nearest multiple of
/// 10^-digits to the exact binary value, an exact tie to the even one.
/// Dart's toStringAsFixed rounds exact ties up instead. A double is an
/// exact tie only when x * 2^(digits + 1) is an odd whole number (0.25 for
/// one digit, 0.0625 for three): the tie (2k + 1) / (2 * 10^digits) is a
/// binary fraction only when 5^digits divides 2k + 1.
double pythonRound(double x, int digits) {
  final scaled = x * (1 << (digits + 1)); // exact: a power of two
  if (scaled == scaled.truncateToDouble() && scaled.toInt().isOdd) {
    final units = x * math.pow(10, digits); // exact: an odd multiple of 0.5
    final low = units.floor();
    final even = low.isEven ? low : low + 1;
    return even / math.pow(10, digits);
  }
  return double.parse(x.toStringAsFixed(digits));
}

/// [pythonRound] to one digit: Silero's 0.1 s time resolution.
double pythonRoundTenth(double x) => pythonRound(x, 1);
