/// GigaAM v3 RNNT (int8) in Dart: the Russian recogniser of "Hear the
/// words" (plan 10 I2c).
///
/// A port of GigaAmTranscriber's gigaam_app/asr.py (v0.7.0), which the
/// research ran. The encoder graph (encoder.onnx) takes raw 16 kHz samples
/// and their count, computes the log-mel features itself and gives one
/// 768-float frame per 40 ms. The small prediction network (one LSTM layer)
/// and the joint network run here from head.npz, greedily: the encoder half
/// of the joint is computed for all frames at once, and the prediction
/// network only runs after a token is emitted (its output does not change
/// on blank steps, and most frames are blank).
///
/// Word confidence is gigaam_app's: GigaAM writes case and punctuation
/// itself, so a token's probability is shared between spellings of the
/// same letters ("Vy" and "vy,"); the probabilities of all tokens with the
/// same letters are summed, blank is left out (in RNNT it also means "one
/// frame later"), and a word gets its weakest token's value.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'npz.dart';
import 'speech_chunks.dart';

/// SentencePiece's mark on the first piece of every word (U+2581).
const wordStartMark = '▁';

/// At or above this mean word confidence a song is Russian and GigaAM's
/// words are kept; below it Whisper hears the song (plan 10 I1c: all 53
/// Russian research songs were 0.82-0.99, the others 0.00-0.78 but one).
const russianConfidence = 0.80;

/// One emitted token: its vocabulary id, the encoder frame it came at and
/// how sure the model was of its letters (null for punctuation).
typedef HeardToken = ({int token, int frame, double? confidence});

/// One heard word with its time in seconds from the start of the song.
class HeardWord {
  const HeardWord(this.start, this.end, this.text, this.confidence);

  final double start;
  final double end;
  final String text;

  /// The lowest letter confidence among its tokens, 0..1; null for a word
  /// of punctuation only.
  final double? confidence;
}

final _alphanumeric = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// A vocabulary piece without punctuation and letter case, the word-start
/// mark kept (gigaam_app's letter_key).
String letterKey(String piece) {
  final lower = piece.toLowerCase().replaceAll('ё', 'е');
  final letters = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    if (_alphanumeric.hasMatch(char)) letters.write(char);
  }
  return '${piece.startsWith(wordStartMark) ? wordStartMark : ''}$letters';
}

/// For every token id of [vocab]: the ids of the tokens spelling the same
/// letters, or null for a token without letters (punctuation, the bare
/// word-start mark) and for [blankId].
List<Int32List?> letterGroups(List<String> vocab, int blankId) {
  final byKey = <String, List<int>>{};
  for (var token = 0; token < vocab.length; token++) {
    if (token != blankId) {
      byKey.putIfAbsent(letterKey(vocab[token]), () => []).add(token);
    }
  }
  return [
    for (var token = 0; token < vocab.length; token++)
      switch (letterKey(vocab[token])) {
        _ when token == blankId => null,
        '' || wordStartMark => null,
        final key => Int32List.fromList(byKey[key]!),
      },
  ];
}

/// The RNNT prediction and joint networks for greedy decoding.
class RnntHead {
  RnntHead._(
    this._embed,
    this._wIh,
    this._wHh,
    this._bias,
    this._encW,
    this._encB,
    this._predW,
    this._predB,
    this._outW,
    this._outB, {
    required this.hidden,
    required this.encoderDim,
    required this.jointDim,
    required this.outputs,
    required this.blankId,
    required this.maxSymbols,
  });

  /// The weights in head.npz ([readNpz]), PyTorch's [out, in] layout:
  /// embed (vocab + 1, hidden), w_ih and w_hh (4 hidden, hidden), bias (4
  /// hidden; both LSTM biases summed), enc_w (joint, encoder), pred_w
  /// (joint, hidden), out_w (vocab + 1, joint) and their biases.
  factory RnntHead.fromArrays(
    Map<String, NpyArray> weights, {
    required int blankId,
    int maxSymbols = 10,
  }) {
    NpyArray take(String name, int rank) {
      final array = weights[name];
      if (array == null) throw FormatException('head.npz lacks $name');
      if (array.shape.length != rank) {
        throw FormatException('$name has shape ${array.shape}');
      }
      return array;
    }

    final embed = take('embed', 2);
    final wIh = take('w_ih', 2);
    final wHh = take('w_hh', 2);
    final bias = take('bias', 1);
    final encW = take('enc_w', 2);
    final encB = take('enc_b', 1);
    final predW = take('pred_w', 2);
    final predB = take('pred_b', 1);
    final outW = take('out_w', 2);
    final outB = take('out_b', 1);
    final hidden = wHh.shape[1];
    final jointDim = encW.shape[0];
    final outputs = outW.shape[0];
    bool fits(NpyArray array, List<int> shape) =>
        array.shape.length == shape.length &&
        Iterable.generate(shape.length)
            .every((i) => array.shape[i] == shape[i]);
    if (!fits(wIh, [4 * hidden, embed.shape[1]]) ||
        embed.shape[1] != hidden ||
        !fits(wHh, [4 * hidden, hidden]) ||
        !fits(bias, [4 * hidden]) ||
        !fits(encB, [jointDim]) ||
        !fits(predW, [jointDim, hidden]) ||
        !fits(predB, [jointDim]) ||
        !fits(outW, [outputs, jointDim]) ||
        !fits(outB, [outputs]) ||
        embed.shape[0] != outputs ||
        blankId >= outputs ||
        hidden % 4 != 0 ||
        jointDim % 4 != 0 ||
        encW.shape[1] % 4 != 0) {
      throw const FormatException('head.npz shapes do not fit together');
    }
    return RnntHead._(
      embed.values,
      wIh.values,
      wHh.values,
      bias.values,
      encW.values,
      encB.values,
      predW.values,
      predB.values,
      outW.values,
      outB.values,
      hidden: hidden,
      encoderDim: encW.shape[1],
      jointDim: jointDim,
      outputs: outputs,
      blankId: blankId,
      maxSymbols: maxSymbols,
    );
  }

  final Float32List _embed;
  final Float32List _wIh;
  final Float32List _wHh;
  final Float32List _bias;
  final Float32List _encW;
  final Float32List _encB;
  final Float32List _predW;
  final Float32List _predB;
  final Float32List _outW;
  final Float32List _outB;

  final int hidden;
  final int encoderDim;
  final int jointDim;

  /// Vocabulary size plus blank.
  final int outputs;
  final int blankId;

  /// At most this many tokens per encoder frame.
  final int maxSymbols;

  /// Greedy decoding of one chunk's [encoded] frames (frames x
  /// [encoderDim], row-major). With [groups] ([letterGroups]) each token
  /// gets its letter confidence; without, confidence is null.
  List<HeardToken> decode(Float32List encoded, {List<Int32List?>? groups}) {
    if (encoded.length % encoderDim != 0) {
      throw ArgumentError('encoded is not whole frames of $encoderDim');
    }
    final frames = encoded.length ~/ encoderDim;
    final encoded4 = encoded.buffer.asFloat32x4List(
      encoded.offsetInBytes,
      encoded.length ~/ 4,
    );
    final encW4 = _encW.buffer.asFloat32x4List();
    // The encoder half of the joint for all frames.
    final encoderPart = Float32List(frames * jointDim);
    final encoderRow4 = encoderDim ~/ 4;
    for (var f = 0; f < frames; f++) {
      for (var j = 0; j < jointDim; j++) {
        encoderPart[f * jointDim + j] =
            _dot(
              encW4,
              j * encoderRow4,
              encoded4,
              f * encoderRow4,
              encoderRow4,
            ) +
            _encB[j];
      }
    }
    final h = Float32List(hidden);
    final c = Float32List(hidden);
    final gates = Float32List(4 * hidden);
    final prediction = Float32List(jointDim);
    final joint = Float32List(jointDim);
    final logits = Float32List(outputs);
    // The first prediction step sees an all-zero input, as in GigaAM.
    _lstmStep(Float32List(hidden), 0, h, c, gates);
    _predict(h, prediction);
    final joint4 = joint.buffer.asFloat32x4List();
    final outW4 = _outW.buffer.asFloat32x4List();
    final jointRow4 = jointDim ~/ 4;
    final tokens = <HeardToken>[];
    for (var frame = 0; frame < frames; frame++) {
      for (var symbol = 0; symbol < maxSymbols; symbol++) {
        final base = frame * jointDim;
        for (var j = 0; j < jointDim; j++) {
          final value = encoderPart[base + j] + prediction[j];
          joint[j] = value > 0 ? value : 0;
        }
        var best = 0;
        var bestValue = double.negativeInfinity;
        for (var v = 0; v < outputs; v++) {
          final value =
              _dot(outW4, v * jointRow4, joint4, 0, jointRow4) + _outB[v];
          logits[v] = value;
          // The first of equal maxima, as numpy's argmax.
          if (value > bestValue) {
            bestValue = value;
            best = v;
          }
        }
        if (best == blankId) break;
        tokens.add((
          token: best,
          frame: frame,
          confidence: groups == null ? null : _confidence(logits, best, groups),
        ));
        _lstmStep(_embed, best * hidden, h, c, gates);
        _predict(h, prediction);
      }
    }
    return tokens;
  }

  /// The emitted [token]'s letter probability without blank.
  double? _confidence(Float32List logits, int token, List<Int32List?> groups) {
    final group = token < groups.length ? groups[token] : null;
    if (group == null) return null;
    // Softmax only for emitted tokens: a few per second of audio.
    final top = logits[token];
    var sum = 0.0;
    for (var v = 0; v < outputs; v++) {
      sum += math.exp(logits[v] - top);
    }
    final blank = math.exp(logits[blankId] - top) / sum;
    final rest = 1.0 - blank;
    if (rest <= 0) return null;
    var letters = 0.0;
    for (final member in group) {
      letters += math.exp(logits[member] - top);
    }
    return math.min(1.0, letters / sum / rest);
  }

  /// One LSTM step on the input row at [inputs][offset..offset+hidden);
  /// PyTorch packs the gates as input, forget, cell, output.
  void _lstmStep(
    Float32List inputs,
    int offset,
    Float32List h,
    Float32List c,
    Float32List gates,
  ) {
    final row4 = hidden ~/ 4;
    final x4 = inputs.buffer.asFloat32x4List(
      inputs.offsetInBytes + offset * 4,
      row4,
    );
    final h4 = h.buffer.asFloat32x4List(h.offsetInBytes, row4);
    final wIh4 = _wIh.buffer.asFloat32x4List();
    final wHh4 = _wHh.buffer.asFloat32x4List();
    for (var g = 0; g < 4 * hidden; g++) {
      gates[g] =
          _dot(wIh4, g * row4, x4, 0, row4) +
          _dot(wHh4, g * row4, h4, 0, row4) +
          _bias[g];
    }
    for (var k = 0; k < hidden; k++) {
      final input = _sigmoid(gates[k]);
      final forget = _sigmoid(gates[hidden + k]);
      final cell = _tanh(gates[2 * hidden + k]);
      final output = _sigmoid(gates[3 * hidden + k]);
      c[k] = forget * c[k] + input * cell;
      h[k] = output * _tanh(c[k]);
    }
  }

  void _predict(Float32List h, Float32List prediction) {
    final row4 = hidden ~/ 4;
    final h4 = h.buffer.asFloat32x4List(h.offsetInBytes, row4);
    final predW4 = _predW.buffer.asFloat32x4List();
    for (var j = 0; j < jointDim; j++) {
      prediction[j] = _dot(predW4, j * row4, h4, 0, row4) + _predB[j];
    }
  }
}

double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

double _tanh(double x) {
  if (x > 20) return 1.0;
  if (x < -20) return -1.0;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// The dot product of [length] lanes-of-four from [a] at [aAt] and [b] at
/// [bAt], in float32 lanes as a BLAS sgemm would sum them.
double _dot(Float32x4List a, int aAt, Float32x4List b, int bAt, int length) {
  var sum0 = Float32x4.zero();
  var sum1 = Float32x4.zero();
  var i = 0;
  for (; i + 1 < length; i += 2) {
    sum0 += a[aAt + i] * b[bAt + i];
    sum1 += a[aAt + i + 1] * b[bAt + i + 1];
  }
  if (i < length) sum0 += a[aAt + i] * b[bAt + i];
  final sum = sum0 + sum1;
  return sum.x + sum.y + sum.z + sum.w;
}

/// The files of a GigaAM model folder (model.json, vocab.json, head.npz)
/// read and checked; the encoder is opened by the caller.
class GigaamModel {
  GigaamModel._({
    required this.name,
    required this.frameSeconds,
    required this.blankId,
    required this.vocab,
    required this.head,
    required this.encoderPath,
  }) : groups = letterGroups(vocab, blankId);

  /// Reads the model in [folder]; throws [FormatException] or
  /// [FileSystemException] for a folder that is not an RNNT model with
  /// files of the sizes model.json gives.
  factory GigaamModel.load(String folder) {
    final meta = jsonDecode(
      File('$folder/model.json').readAsStringSync(),
    ) as Map<String, Object?>;
    if (meta['type'] != 'rnnt') {
      throw FormatException('not an RNNT model: ${meta['type']}');
    }
    final files = (meta['files'] as Map).cast<String, Object?>();
    String path(String role) {
      final entry = (files[role] as Map).cast<String, Object?>();
      final file = File('$folder/${entry['name']}');
      if (file.lengthSync() != entry['size']) {
        throw FormatException('model file is damaged: ${file.path}');
      }
      return file.path;
    }

    final blankId = meta['blank_id'] as int;
    final vocab = (jsonDecode(File(path('vocab')).readAsStringSync()) as List)
        .cast<String>();
    final head = RnntHead.fromArrays(
      readNpz(File(path('head')).readAsBytesSync()),
      blankId: blankId,
    );
    return GigaamModel._(
      name: meta['name'] as String,
      frameSeconds: (meta['frame_seconds'] as num).toDouble(),
      blankId: blankId,
      vocab: vocab,
      head: head,
      encoderPath: path('encoder'),
    );
  }

  final String name;

  /// Seconds per encoder frame (0.04).
  final double frameSeconds;
  final int blankId;
  final List<String> vocab;
  final RnntHead head;
  final List<Int32List?> groups;

  /// encoder.onnx.
  final String encoderPath;

  /// Greedy decoding of one chunk's encoder frames.
  List<HeardToken> decode(Float32List encoded) =>
      head.decode(encoded, groups: groups);

  /// [tokens] of a chunk starting [offsetSeconds] into the song as words
  /// (gigaam_app's AsrModel.words): a word starts at a piece with the
  /// word-start mark; it runs from its first token's frame to one frame
  /// past its last; times rounded to milliseconds as gigaam_app does.
  List<HeardWord> words(List<HeardToken> tokens, double offsetSeconds) {
    final words = <HeardWord>[];
    final pieces = <String>[];
    int? first;
    var last = 0;
    double? lowest;

    void flush() {
      final text = pieces.join().trim();
      if (text.isEmpty) return;
      words.add(
        HeardWord(
          pythonRound(offsetSeconds + first! * frameSeconds, 3),
          pythonRound(offsetSeconds + (last + 1) * frameSeconds, 3),
          text,
          lowest == null ? null : pythonRound(lowest, 3),
        ),
      );
    }

    for (final (:token, :frame, :confidence) in tokens) {
      var piece = vocab[token];
      final startsWord = piece.startsWith(wordStartMark) || piece == ' ';
      if (startsWord && pieces.isNotEmpty) {
        flush();
        pieces.clear();
        lowest = null;
      }
      piece = piece.replaceAll(wordStartMark, ' ');
      if (pieces.isEmpty) first = frame;
      if (piece.trim().isNotEmpty) {
        pieces.add(piece);
        last = frame;
        if (confidence != null) {
          lowest = lowest == null ? confidence : math.min(lowest, confidence);
        }
      } else if (pieces.isEmpty) {
        first = null;
      }
    }
    if (pieces.isNotEmpty) flush();
    return words;
  }
}

/// One recognised chunk: its sample range, its encoder frame count, the
/// tokens and the words.
typedef HeardChunk = ({
  SampleRange range,
  int frames,
  List<HeardToken> tokens,
  List<HeardWord> words,
});

/// What GigaAM heard in a song.
class GigaamResult {
  const GigaamResult({
    required this.samples,
    required this.speechSeconds,
    required this.chunks,
  });

  /// Length of the audio in 16 kHz samples.
  final int samples;

  /// Singing the speech gate found (padded regions).
  final double speechSeconds;
  final List<HeardChunk> chunks;

  /// Every word in time order.
  List<HeardWord> get words => [for (final c in chunks) ...c.words];

  /// The mean confidence of the words with letters; 0 when there are none.
  double get meanConfidence {
    var sum = 0.0;
    var count = 0;
    for (final chunk in chunks) {
      for (final word in chunk.words) {
        final confidence = word.confidence;
        if (confidence == null) continue;
        sum += confidence;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  /// GigaAM's words are the song's: it is sure enough that the song is
  /// Russian ([russianConfidence]).
  bool get isRussian => meanConfidence >= russianConfidence;
}

/// The encoder on one chunk of 16 kHz samples: its frames (frames x 768,
/// row-major).
typedef GigaamEncode = Float32List Function(Float32List samples);

/// Hears [audio] (16 kHz mono vocals): Silero through [scan] first over
/// the whole song (so its model can be closed before the encoder opens),
/// then each chunk through [encode] and the decoder. [onVadDone] runs
/// between the two (the worker closes Silero there), [onChunk] after each
/// chunk (progress and cancel). [onProbabilities] sees Silero's output, for
/// checks.
GigaamResult hearRussian(
  Float32List audio,
  GigaamModel model, {
  required SileroScan scan,
  required GigaamEncode encode,
  VadOptions options = hearWordsVad,
  void Function()? onVadDone,
  void Function(int done, int total)? onChunk,
  void Function(int first, Float32List probabilities)? onProbabilities,
}) {
  final finder = ChunkFinder(audio.length, options);
  final ranges = <SampleRange>[];
  sileroBlocks(audio, scan, (first, probabilities) {
    onProbabilities?.call(first, probabilities);
    for (var i = 0; i < probabilities.length; i++) {
      ranges.addAll(finder.feed(first + i, probabilities[i]));
    }
  });
  ranges.addAll(finder.finish());
  onVadDone?.call();
  final chunks = <HeardChunk>[];
  for (final range in ranges) {
    final encoded = encode(
      Float32List.sublistView(audio, range.start, range.end),
    );
    final tokens = model.decode(encoded);
    chunks.add((
      range: range,
      frames: encoded.length ~/ model.head.encoderDim,
      tokens: tokens,
      words: model.words(tokens, range.start / 16000),
    ));
    onChunk?.call(chunks.length, ranges.length);
  }
  return GigaamResult(
    samples: audio.length,
    speechSeconds: finder.speechSeconds,
    chunks: chunks,
  );
}
