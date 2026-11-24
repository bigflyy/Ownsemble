/// A complex FFT of any length made of the factors 2, 3, 4 and 5 (plan 10
/// I2b: the vocal separator's STFT is 7680 points = 4^4 * 2 * 3 * 5).
///
/// Self-sorting (Stockham): every stage reads one buffer and writes the
/// other, and the result comes out in natural order, no bit reversal.
/// After the stage that has done sub-transforms of length s, the buffer
/// holds, at index f * R + k (R = n / s), the length-s DFT at frequency f
/// of the samples k, k + R, k + 2R, ... A stage of radix p combines p of
/// them into one of length s * p.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A planned FFT of one length. Not safe to share between isolates (it
/// keeps its work buffer); make one per isolate.
class Fft {
  Fft(this.length) : _stages = _plan(length) {
    _work = Float64List(2 * length);
  }

  /// The number of complex points.
  final int length;

  final List<_Stage> _stages;
  late final Float64List _work;

  /// Transforms [data] in place: [length] complex numbers as re, im pairs.
  /// Forward means e^(-2 pi i f t / n), no scaling; [inverse] uses
  /// e^(+2 pi i f t / n) and also no scaling (divide by [length] yourself).
  void transform(Float64List data, {bool inverse = false}) {
    assert(data.length == 2 * length);
    if (inverse) _conjugate(data);
    var from = data;
    var to = _work;
    for (final stage in _stages) {
      stage.run(from, to, length);
      final swap = from;
      from = to;
      to = swap;
    }
    if (!identical(from, data)) data.setAll(0, from);
    if (inverse) _conjugate(data);
  }

  static void _conjugate(Float64List data) {
    for (var i = 1; i < data.length; i += 2) {
      data[i] = -data[i];
    }
  }

  static List<_Stage> _plan(int n) {
    if (n < 1) throw ArgumentError.value(n, 'length');
    final radices = <int>[];
    var rest = n;
    for (final p in [4, 2, 3, 5]) {
      while (rest % p == 0) {
        radices.add(p);
        rest ~/= p;
      }
    }
    if (rest != 1) {
      throw ArgumentError.value(n, 'length', 'only factors 2, 3 and 5');
    }
    final stages = <_Stage>[];
    var s = 1;
    for (final p in radices) {
      stages.add(_Stage(p, s, n));
      s *= p;
    }
    return stages;
  }
}

/// One radix-p stage: from sub-transforms of length [s] to length s * p.
class _Stage {
  _Stage(this.p, this.s, int n) : twiddles = Float64List(2 * s * (p - 1)) {
    // twiddle(f, q) = exp(-2 pi i f q / (s p)), q = 1 .. p-1.
    final sp = s * p;
    for (var f = 0; f < s; f++) {
      for (var q = 1; q < p; q++) {
        final angle = -2 * math.pi * f * q / sp;
        final at = 2 * (f * (p - 1) + q - 1);
        twiddles[at] = math.cos(angle);
        twiddles[at + 1] = math.sin(angle);
      }
    }
  }

  final int p;
  final int s;
  final Float64List twiddles;

  static final _c3 = math.cos(2 * math.pi / 3); // -0.5
  static final _s3 = math.sin(2 * math.pi / 3);
  static final _c51 = math.cos(2 * math.pi / 5);
  static final _c52 = math.cos(4 * math.pi / 5);
  static final _s51 = math.sin(2 * math.pi / 5);
  static final _s52 = math.sin(4 * math.pi / 5);

  void run(Float64List x, Float64List y, int n) {
    final r = n ~/ s; // R before the stage
    final r2 = r ~/ p; // R after it
    final tw = twiddles;
    final a = Float64List(2 * p);
    for (var f = 0; f < s; f++) {
      final twAt = 2 * f * (p - 1);
      for (var k = 0; k < r2; k++) {
        // a_q = X_s[f][k + r2 q] * twiddle(f, q)
        for (var q = 0; q < p; q++) {
          final src = 2 * (f * r + k + r2 * q);
          final re = x[src];
          final im = x[src + 1];
          if (q == 0) {
            a[0] = re;
            a[1] = im;
          } else {
            final wr = tw[twAt + 2 * (q - 1)];
            final wi = tw[twAt + 2 * (q - 1) + 1];
            a[2 * q] = re * wr - im * wi;
            a[2 * q + 1] = re * wi + im * wr;
          }
        }
        // Y[g] = sum_q a_q exp(-2 pi i g q / p), stored at (f + s g) r2 + k.
        final out = 2 * (f * r2 + k);
        final gap = 2 * s * r2;
        switch (p) {
          case 2:
            y[out] = a[0] + a[2];
            y[out + 1] = a[1] + a[3];
            y[out + gap] = a[0] - a[2];
            y[out + gap + 1] = a[1] - a[3];
          case 4:
            final t0r = a[0] + a[4], t0i = a[1] + a[5];
            final t1r = a[0] - a[4], t1i = a[1] - a[5];
            final t2r = a[2] + a[6], t2i = a[3] + a[7];
            // (a1 - a3) * (-i)
            final t3r = a[3] - a[7], t3i = a[6] - a[2];
            y[out] = t0r + t2r;
            y[out + 1] = t0i + t2i;
            y[out + gap] = t1r + t3r;
            y[out + gap + 1] = t1i + t3i;
            y[out + 2 * gap] = t0r - t2r;
            y[out + 2 * gap + 1] = t0i - t2i;
            y[out + 3 * gap] = t1r - t3r;
            y[out + 3 * gap + 1] = t1i - t3i;
          case 3:
            final sr = a[2] + a[4], si = a[3] + a[5];
            final dr = a[2] - a[4], di = a[3] - a[5];
            final mr = a[0] + _c3 * sr, mi = a[1] + _c3 * si;
            // -i sin(2pi/3) (a1 - a2)
            final nr = _s3 * di, ni = -_s3 * dr;
            y[out] = a[0] + sr;
            y[out + 1] = a[1] + si;
            y[out + gap] = mr + nr;
            y[out + gap + 1] = mi + ni;
            y[out + 2 * gap] = mr - nr;
            y[out + 2 * gap + 1] = mi - ni;
          case 5:
            final s1r = a[2] + a[8], s1i = a[3] + a[9];
            final d1r = a[2] - a[8], d1i = a[3] - a[9];
            final s2r = a[4] + a[6], s2i = a[5] + a[7];
            final d2r = a[4] - a[6], d2i = a[5] - a[7];
            final m1r = a[0] + _c51 * s1r + _c52 * s2r;
            final m1i = a[1] + _c51 * s1i + _c52 * s2i;
            final m2r = a[0] + _c52 * s1r + _c51 * s2r;
            final m2i = a[1] + _c52 * s1i + _c51 * s2i;
            // -i (sin1 d1 + sin2 d2) and -i (sin2 d1 - sin1 d2)
            final n1r = _s51 * d1i + _s52 * d2i;
            final n1i = -(_s51 * d1r + _s52 * d2r);
            final n2r = _s52 * d1i - _s51 * d2i;
            final n2i = -(_s52 * d1r - _s51 * d2r);
            y[out] = a[0] + s1r + s2r;
            y[out + 1] = a[1] + s1i + s2i;
            y[out + gap] = m1r + n1r;
            y[out + gap + 1] = m1i + n1i;
            y[out + 2 * gap] = m2r + n2r;
            y[out + 2 * gap + 1] = m2i + n2i;
            y[out + 3 * gap] = m2r - n2r;
            y[out + 3 * gap + 1] = m2i - n2i;
            y[out + 4 * gap] = m1r - n1r;
            y[out + 4 * gap + 1] = m1i - n1i;
        }
      }
    }
  }
}
