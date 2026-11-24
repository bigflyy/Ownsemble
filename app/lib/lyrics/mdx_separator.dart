/// The vocals of a song by MDX-Net Kim Vocal 2 (plan 10 I2b), computed the
/// way audio-separator 0.48.0 does it (architectures/mdx_separator.py with
/// its defaults: hop 1024, segment 256, overlap 0.25, batch 1, no denoise;
/// the model's own n_fft 7680, dim_f 3072, dim_t 256), so the app's vocals
/// are the research's vocals (I1b2, I1e).
///
/// The steps, as there:
///  1. peak = the mix's largest absolute sample; a mix louder than 0.9 is
///     scaled down to 0.9 (spec_utils.normalize).
///  2. The mix gets trim = n_fft / 2 zeros in front and pad zeros behind,
///     and is cut into chunks of hop * (segment - 1) = 261120 samples that
///     start every int(0.75 * chunk) = 195840 samples.
///  3. Each chunk: torch.stft (Hann periodic window, center with reflect
///     padding, 256 frames), the first 3072 of 3841 bins kept, the first 3
///     bins zeroed, laid out [1, 4, 3072, 256] as L re, L im, R re, R im;
///     the model; torch.istft back (bins above 3072 as zeros).
///  4. Each chunk's output is weighted by np.hanning(chunk length) (the
///     symmetric window) and summed; the sum is divided by the sum of the
///     weights; the trim and pad are cut off again.
///  5. The vocals are that times peak; louder than 0.9 is scaled to 0.9
///     (the output normalize of write_audio).
///
/// Memory stays small: the mix is read from a file a chunk at a time and
/// the finished vocals are written out as soon as no later chunk can add to
/// them (the overlap is only 65280 samples).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

/// Kim Vocal 2's numbers (mdx_model_data.json for its hash, and
/// audio-separator's MDX defaults).
const mdxSampleRate = 44100;
const mdxFftSize = 7680;
const mdxHop = 1024;
const mdxBins = 3072; // dim_f
const mdxFrames = 256; // dim_t = segment size
const mdxChunk = mdxHop * (mdxFrames - 1); // 261120
const mdxTrim = mdxFftSize ~/ 2; // 3840
const mdxGen = mdxChunk - 2 * mdxTrim; // 253440
const mdxOverlap = 0.25;
final mdxStep = ((1 - mdxOverlap) * mdxChunk).toInt(); // 195840
const mdxPeakLimit = 0.9; // normalization_threshold

/// The model input's element count: [1, 4, mdxBins, mdxFrames].
const mdxInputLength = 4 * mdxBins * mdxFrames;

/// Where each chunk starts, in samples of the padded mix, for a mix of
/// [samples] per channel; and the padded length.
({List<int> starts, int padded}) mdxChunks(int samples) {
  final pad = mdxGen + mdxTrim - samples % mdxGen;
  final padded = mdxTrim + samples + pad;
  return (
    starts: [for (var i = 0; i < padded; i += mdxStep) i],
    padded: padded,
  );
}

/// np.hanning(m): the symmetric Hann window (zero at both ends).
Float64List symmetricHann(int m) {
  final w = Float64List(m);
  if (m == 1) {
    w[0] = 1;
    return w;
  }
  for (var i = 0; i < m; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (m - 1));
  }
  return w;
}

/// torch.stft and torch.istft for one stereo chunk, with Kim Vocal 2's
/// sizes. One per isolate (it keeps its buffers).
class MdxSpectrum {
  MdxSpectrum() {
    for (var i = 0; i < mdxFftSize; i++) {
      // torch.hann_window(periodic=True)
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / mdxFftSize);
    }
    // The istft's window-square sum over the frames, as torch divides.
    for (var t = 0; t < mdxFrames; t++) {
      for (var i = 0; i < mdxFftSize; i++) {
        _envelope[t * mdxHop + i] += _window[i] * _window[i];
      }
    }
  }

  final _fft = Fft(mdxFftSize);
  final _window = Float64List(mdxFftSize);
  final _buffer = Float64List(2 * mdxFftSize);
  final _padded = Float64List(2 * (mdxChunk + mdxFftSize));
  final _envelope = Float64List(mdxFftSize + mdxHop * (mdxFrames - 1));
  final _sum = Float64List(2 * (mdxFftSize + mdxHop * (mdxFrames - 1)));

  /// The model input for [left] and [right] ([mdxChunk] samples each):
  /// [1, 4, mdxBins, mdxFrames], channels L re, L im, R re, R im, with the
  /// first 3 bins zero.
  Float32List forward(Float32List left, Float32List right) {
    assert(left.length == mdxChunk && right.length == mdxChunk);
    // center=True, pad_mode='reflect': n_fft / 2 on each side, mirrored
    // without repeating the edge sample.
    const half = mdxFftSize ~/ 2;
    const length = mdxChunk + mdxFftSize;
    final padded = _padded; // L at [0, length), R at [length, 2 length)
    for (var j = 0; j < length; j++) {
      final int source;
      if (j < half) {
        source = half - j;
      } else if (j < half + mdxChunk) {
        source = j - half;
      } else {
        source = 2 * (mdxChunk - 1) - (j - half);
      }
      padded[j] = left[source];
      padded[length + j] = right[source];
    }
    final out = Float32List(mdxInputLength);
    const plane = mdxBins * mdxFrames;
    final z = _buffer;
    for (var t = 0; t < mdxFrames; t++) {
      // Both channels in one complex FFT: z = l + i r.
      final from = t * mdxHop;
      for (var i = 0; i < mdxFftSize; i++) {
        final w = _window[i];
        z[2 * i] = padded[from + i] * w;
        z[2 * i + 1] = padded[length + from + i] * w;
      }
      _fft.transform(z);
      for (var k = 3; k < mdxBins; k++) {
        final m = mdxFftSize - k; // k >= 3, so never 0
        final zr = z[2 * k], zi = z[2 * k + 1];
        final cr = z[2 * m], ci = z[2 * m + 1];
        // L_k = (Z_k + conj Z_-k) / 2, R_k = (Z_k - conj Z_-k) / 2i
        final at = k * mdxFrames + t;
        out[at] = 0.5 * (zr + cr);
        out[plane + at] = 0.5 * (zi - ci);
        out[2 * plane + at] = 0.5 * (zi + ci);
        out[3 * plane + at] = 0.5 * (cr - zr);
      }
    }
    return out;
  }

  /// torch.istft of the model output [spectrum] (laid out as [forward]
  /// gives) into [left] and [right], [mdxChunk] samples each.
  void inverse(Float32List spectrum, Float32List left, Float32List right) {
    assert(spectrum.length == mdxInputLength);
    const plane = mdxBins * mdxFrames;
    final sum = _sum;
    final total = _envelope.length;
    sum.fillRange(0, sum.length, 0);
    final y = _buffer;
    for (var t = 0; t < mdxFrames; t++) {
      // Y_k = L_k + i R_k over the whole circle, L and R Hermitian; the
      // imaginary parts of the DC and Nyquist bins are dropped, as irfft
      // drops them; bins from mdxBins up are zero.
      y.fillRange(0, y.length, 0);
      for (var k = 0; k < mdxBins; k++) {
        final at = k * mdxFrames + t;
        final lr = spectrum[at].toDouble();
        final li = k == 0 ? 0.0 : spectrum[plane + at].toDouble();
        final rr = spectrum[2 * plane + at].toDouble();
        final ri = k == 0 ? 0.0 : spectrum[3 * plane + at].toDouble();
        // Y_k = (lr - ri) + i (li + rr)
        y[2 * k] = lr - ri;
        y[2 * k + 1] = li + rr;
        if (k > 0) {
          // Y_-k = conj L_k + i conj R_k = (lr + ri) + i (rr - li)
          final m = mdxFftSize - k;
          y[2 * m] = lr + ri;
          y[2 * m + 1] = rr - li;
        }
      }
      _fft.transform(y, inverse: true);
      final from = t * mdxHop;
      for (var i = 0; i < mdxFftSize; i++) {
        final w = _window[i] / mdxFftSize;
        sum[2 * (from + i)] += y[2 * i] * w;
        sum[2 * (from + i) + 1] += y[2 * i + 1] * w;
      }
    }
    const half = mdxFftSize ~/ 2;
    for (var i = 0; i < mdxChunk; i++) {
      final at = half + i;
      assert(at < total);
      final e = _envelope[at];
      left[i] = sum[2 * at] / e;
      right[i] = sum[2 * at + 1] / e;
    }
  }
}

/// Reads stereo float samples (interleaved, as mpv's PCM writer gives)
/// from a file a piece at a time.
class StereoFloatFile {
  StereoFloatFile(String path)
    : _file = File(path).openSync(),
      frames = File(path).lengthSync() ~/ 8;

  final RandomAccessFile _file;

  /// Samples per channel.
  final int frames;

  /// Reads frames [from, from + count) into [left] and [right] (the first
  /// [count] places), times [scale].
  void read(
    int from,
    int count,
    Float32List left,
    Float32List right, {
    double scale = 1,
  }) {
    _file.setPositionSync(from * 8);
    final bytes = Uint8List(count * 8);
    final got = _file.readIntoSync(bytes);
    final samples = Float32List.sublistView(bytes, 0, got ~/ 4 * 4);
    final have = got ~/ 8;
    for (var i = 0; i < count; i++) {
      if (i < have) {
        left[i] = samples[2 * i] * scale;
        right[i] = samples[2 * i + 1] * scale;
      } else {
        left[i] = 0;
        right[i] = 0;
      }
    }
  }

  /// The largest absolute sample of both channels.
  double peak() {
    var peak = 0.0;
    const piece = 1 << 18;
    final bytes = Uint8List(piece * 8);
    _file.setPositionSync(0);
    while (true) {
      final got = _file.readIntoSync(bytes);
      if (got <= 0) break;
      final samples = Float32List.sublistView(bytes, 0, got ~/ 4 * 4);
      for (final s in samples) {
        final a = s.abs();
        if (a > peak) peak = a;
      }
    }
    return peak;
  }

  void close() => _file.closeSync();
}

/// The model: one chunk's spectrum in, the vocals' spectrum out.
typedef MdxModel = Float32List Function(Float32List spectrum);

/// What [separateVocals] measured.
class MdxResult {
  const MdxResult({
    required this.frames,
    required this.chunks,
    required this.scale,
    this.modelMs = 0,
    this.spectrumMs = 0,
  });

  /// Time inside the model, and in the STFT and its inverse.
  final int modelMs;
  final int spectrumMs;

  /// Samples per channel written.
  final int frames;
  final int chunks;

  /// What the written samples must still be multiplied by (step 5): the
  /// mix's peak, and the output limit. Applied by the caller after
  /// resampling, so the vocals are never held whole at 44.1 kHz.
  final double scale;
}

/// Separates the vocals of the 44.1 kHz stereo float file [mixPath]
/// (interleaved) into [vocalsPath] (the same form), all but the final
/// scale ([MdxResult.scale]). [model] runs one chunk; [onChunk] hears each
/// chunk done and may throw to stop between chunks.
MdxResult separateVocals(
  String mixPath,
  String vocalsPath,
  MdxModel model, {
  void Function(int done, int total)? onChunk,
}) {
  final mix = StereoFloatFile(mixPath);
  final sink = File(vocalsPath).openSync(mode: FileMode.writeOnly);
  try {
    final n = mix.frames;
    final peak = mix.peak();
    if (n == 0 || peak == 0) {
      // Silence: no vocals (audio-separator gives zeros times peak 0).
      return const MdxResult(frames: 0, chunks: 0, scale: 0);
    }
    final scaleIn = peak > mdxPeakLimit ? mdxPeakLimit / peak : 1.0;
    final (:starts, :padded) = mdxChunks(n);
    final spectrum = MdxSpectrum();
    final left = Float32List(mdxChunk);
    final right = Float32List(mdxChunk);
    final outLeft = Float32List(mdxChunk);
    final outRight = Float32List(mdxChunk);
    // Sums and weights for padded positions [base, base + mdxChunk).
    final sumL = Float64List(mdxChunk);
    final sumR = Float64List(mdxChunk);
    final weight = Float64List(mdxChunk);
    var base = 0;
    var written = 0; // padded positions finished
    var loudest = 0.0;
    var modelUs = 0;
    var spectrumUs = 0;

    // Writes padded positions [written, upTo) (only those that are the
    // mix, not the trim or pad), then moves the window up.
    void finish(int upTo) {
      final out = Float32List(2 * (upTo - written));
      var count = 0;
      for (var at = written; at < upTo; at++) {
        final i = at - base;
        final w = weight[i];
        final l = w == 0 ? 0.0 : sumL[i] / w;
        final r = w == 0 ? 0.0 : sumR[i] / w;
        final m = at - mdxTrim;
        if (m < 0 || m >= n) continue;
        out[2 * count] = l;
        out[2 * count + 1] = r;
        count++;
        final a = math.max(l.abs(), r.abs());
        if (a > loudest) loudest = a;
      }
      sink.writeFromSync(Uint8List.sublistView(out, 0, 2 * count));
      final shift = upTo - base;
      sumL.setRange(0, mdxChunk - shift, sumL, shift);
      sumR.setRange(0, mdxChunk - shift, sumR, shift);
      weight.setRange(0, mdxChunk - shift, weight, shift);
      sumL.fillRange(mdxChunk - shift, mdxChunk, 0);
      sumR.fillRange(mdxChunk - shift, mdxChunk, 0);
      weight.fillRange(mdxChunk - shift, mdxChunk, 0);
      base = upTo;
      written = upTo;
    }

    for (var c = 0; c < starts.length; c++) {
      final start = starts[c];
      final end = math.min(start + mdxChunk, padded);
      final actual = end - start;
      // The padded mix: trim zeros, the mix, pad zeros.
      left.fillRange(0, mdxChunk, 0);
      right.fillRange(0, mdxChunk, 0);
      final mixFrom = math.max(start, mdxTrim);
      final mixTo = math.min(end, mdxTrim + n);
      if (mixTo > mixFrom) {
        final l = Float32List(mixTo - mixFrom);
        final r = Float32List(mixTo - mixFrom);
        mix.read(mixFrom - mdxTrim, mixTo - mixFrom, l, r, scale: scaleIn);
        left.setRange(mixFrom - start, mixTo - start, l);
        right.setRange(mixFrom - start, mixTo - start, r);
      }
      final clock = Stopwatch()..start();
      final input = spectrum.forward(left, right);
      spectrumUs += clock.elapsedMicroseconds;
      clock.reset();
      final output = model(input);
      modelUs += clock.elapsedMicroseconds;
      clock.reset();
      spectrum.inverse(output, outLeft, outRight);
      spectrumUs += clock.elapsedMicroseconds;
      final window = symmetricHann(actual);
      assert(start >= base && start + actual <= base + mdxChunk);
      for (var i = 0; i < actual; i++) {
        final w = window[i];
        final at = start - base + i;
        sumL[at] += outLeft[i] * w;
        sumR[at] += outRight[i] * w;
        weight[at] += w;
      }
      onChunk?.call(c + 1, starts.length);
      final next = c + 1 < starts.length ? starts[c + 1] : padded;
      finish(next);
    }
    final scaled = loudest * peak;
    final scaleOut = scaled > mdxPeakLimit ? mdxPeakLimit / scaled : 1.0;
    return MdxResult(
      frames: n,
      chunks: starts.length,
      scale: peak * scaleOut,
      modelMs: modelUs ~/ 1000,
      spectrumMs: spectrumUs ~/ 1000,
    );
  } finally {
    mix.close();
    sink.closeSync();
  }
}
