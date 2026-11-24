// Plan 10 I2b: the FFT and the vocal separator's STFT, chunks and overlap.
// Parity with audio-separator on a real song is tool/check_separator.dart.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/fft.dart';
import 'package:ownsemble/lyrics/mdx_separator.dart';

/// The DFT by its definition, for a check.
Float64List directDft(Float64List x, {bool inverse = false}) {
  final n = x.length ~/ 2;
  final out = Float64List(2 * n);
  final sign = inverse ? 1 : -1;
  for (var f = 0; f < n; f++) {
    var re = 0.0, im = 0.0;
    for (var t = 0; t < n; t++) {
      final a = sign * 2 * math.pi * ((f * t) % n) / n;
      final c = math.cos(a), s = math.sin(a);
      re += x[2 * t] * c - x[2 * t + 1] * s;
      im += x[2 * t] * s + x[2 * t + 1] * c;
    }
    out[2 * f] = re;
    out[2 * f + 1] = im;
  }
  return out;
}

void main() {
  group('Fft', () {
    final random = math.Random(7);
    for (final n in [1, 2, 3, 4, 5, 6, 8, 12, 15, 16, 30, 60, 120, 480, 960]) {
      test('matches the DFT at length $n', () {
        final x = Float64List.fromList([
          for (var i = 0; i < 2 * n; i++) random.nextDouble() * 2 - 1,
        ]);
        final want = directDft(x);
        final got = Float64List.fromList(x);
        Fft(n).transform(got);
        for (var i = 0; i < 2 * n; i++) {
          expect(got[i], closeTo(want[i], 1e-9 * n));
        }
        final back = Float64List.fromList(got);
        Fft(n).transform(back, inverse: true);
        for (var i = 0; i < 2 * n; i++) {
          expect(back[i] / n, closeTo(x[i], 1e-12 * n));
        }
      });
    }

    test('the separator length 7680: some bins against the DFT', () {
      const n = mdxFftSize;
      final x = Float64List.fromList([
        for (var i = 0; i < 2 * n; i++) random.nextDouble() * 2 - 1,
      ]);
      final got = Float64List.fromList(x);
      Fft(n).transform(got);
      for (final f in [0, 1, 2, 3, 7, 1000, 3071, 3840, 3841, 7679]) {
        var re = 0.0, im = 0.0;
        for (var t = 0; t < n; t++) {
          final a = -2 * math.pi * ((f * t) % n) / n;
          re += x[2 * t] * math.cos(a) - x[2 * t + 1] * math.sin(a);
          im += x[2 * t] * math.sin(a) + x[2 * t + 1] * math.cos(a);
        }
        expect(got[2 * f], closeTo(re, 1e-8));
        expect(got[2 * f + 1], closeTo(im, 1e-8));
      }
    });

    test('lengths with other factors are refused', () {
      expect(() => Fft(7), throwsArgumentError);
    });
  });

  group('MdxSpectrum', () {
    test('forward then inverse gives back a chunk inside the kept band, '
        'each channel on its own (asymmetric stereo)', () {
      final spectrum = MdxSpectrum();
      final left = Float32List(mdxChunk);
      final right = Float32List(mdxChunk);
      for (var i = 0; i < mdxChunk; i++) {
        // 440 Hz on the left only; 1234 Hz and 3 kHz on the right.
        left[i] = 0.5 * math.sin(2 * math.pi * 440 * i / mdxSampleRate);
        right[i] =
            0.3 * math.sin(2 * math.pi * 1234 * i / mdxSampleRate) +
            0.1 * math.cos(2 * math.pi * 3000 * i / mdxSampleRate);
      }
      final spec = spectrum.forward(left, right);
      expect(spec.length, mdxInputLength);
      const plane = mdxBins * mdxFrames;
      // The first 3 bins are zero in every plane.
      for (var c = 0; c < 4; c++) {
        for (var k = 0; k < 3; k++) {
          expect(spec[c * plane + k * mdxFrames + 100], 0);
        }
      }
      final outL = Float32List(mdxChunk);
      final outR = Float32List(mdxChunk);
      spectrum.inverse(spec, outL, outR);
      var worst = 0.0;
      // Away from the chunk edges, where reflect padding meets the window.
      for (var i = 8000; i < mdxChunk - 8000; i++) {
        worst = math.max(worst, (outL[i] - left[i]).abs());
        worst = math.max(worst, (outR[i] - right[i]).abs());
      }
      expect(worst, lessThan(1e-4));
    });

    test('the spectrum of a left-only sine has nothing on the right', () {
      final spectrum = MdxSpectrum();
      final left = Float32List(mdxChunk);
      final right = Float32List(mdxChunk);
      for (var i = 0; i < mdxChunk; i++) {
        left[i] = math.sin(2 * math.pi * 1000 * i / mdxSampleRate);
      }
      final spec = spectrum.forward(left, right);
      const plane = mdxBins * mdxFrames;
      var leftEnergy = 0.0, rightEnergy = 0.0;
      for (var i = 0; i < plane; i++) {
        leftEnergy += spec[i] * spec[i] + spec[plane + i] * spec[plane + i];
        rightEnergy +=
            spec[2 * plane + i] * spec[2 * plane + i] +
            spec[3 * plane + i] * spec[3 * plane + i];
      }
      expect(rightEnergy / leftEnergy, lessThan(1e-12));
    });
  });

  group('chunks', () {
    test('as audio-separator cuts them', () {
      // A 3 minute song.
      const n = 180 * mdxSampleRate;
      final (:starts, :padded) = mdxChunks(n);
      expect(padded, mdxTrim + n + mdxGen + mdxTrim - n % mdxGen);
      expect(padded % mdxGen, mdxTrim * 2 % mdxGen);
      expect(starts.first, 0);
      expect(starts[1], 195840);
      expect(starts.last, lessThan(padded));
      expect(starts.length, (padded + mdxStep - 1) ~/ mdxStep);
    });

    test('np.hanning is symmetric with zero ends', () {
      final w = symmetricHann(5);
      expect(w, [0.0, 0.5, 1.0, 0.5, 0.0].map((v) => closeTo(v, 1e-12)));
      expect(symmetricHann(1), [1.0]);
    });
  });

  group('separateVocals', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mdx-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    File writeStereo(String name, int frames, double Function(int, int) at) {
      final data = Float32List(2 * frames);
      for (var i = 0; i < frames; i++) {
        data[2 * i] = at(0, i);
        data[2 * i + 1] = at(1, i);
      }
      return File('${dir.path}/$name')
        ..writeAsBytesSync(Uint8List.sublistView(data));
    }

    Float32List readStereo(File file) =>
        Float32List.sublistView(file.readAsBytesSync());

    test('an identity model gives the mix back across chunk seams and the '
        'last partial chunk, channels kept apart', () {
      // 14 s: three chunks, the last one partial.
      const frames = 14 * mdxSampleRate;
      double source(int channel, int i) => channel == 0
          ? 0.6 * math.sin(2 * math.pi * 220 * i / mdxSampleRate)
          : 0.2 * math.sin(2 * math.pi * 2500 * i / mdxSampleRate) +
                0.1 * math.sin(2 * math.pi * 90 * i / mdxSampleRate);
      final mix = writeStereo('mix.f32', frames, source);
      final out = File('${dir.path}/vocals.f32');
      final seen = <int>[];
      final result = separateVocals(
        mix.path,
        out.path,
        (spectrum) => spectrum,
        onChunk: (done, total) => seen.add(done),
      );
      expect(result.frames, frames);
      expect(result.chunks, mdxChunks(frames).starts.length);
      expect(seen.last, result.chunks);
      // Peak 0.6 < 0.9: the mix is not scaled; the output is multiplied by
      // the peak, as audio-separator does (separate: demix(mix) * peak).
      expect(result.scale, closeTo(0.6, 1e-3));
      final vocals = readStereo(out);
      expect(vocals.length, 2 * frames);
      var worst = 0.0;
      for (var i = 2000; i < frames - 2000; i++) {
        worst = math.max(worst, (vocals[2 * i] - source(0, i)).abs());
        worst = math.max(worst, (vocals[2 * i + 1] - source(1, i)).abs());
      }
      expect(worst, lessThan(2e-3));
    });

    test('a loud mix is scaled to 0.9 going in, and the scale says so', () {
      const frames = 7 * mdxSampleRate;
      final mix = writeStereo(
        'mix.f32',
        frames,
        (c, i) => 1.8 * math.sin(2 * math.pi * 300 * i / mdxSampleRate),
      );
      final out = File('${dir.path}/vocals.f32');
      final result = separateVocals(mix.path, out.path, (s) => s);
      final vocals = readStereo(out);
      var loudest = 0.0;
      for (final v in vocals) {
        loudest = math.max(loudest, v.abs());
      }
      // In: 1.8 -> 0.9 (ringing at the song's sharp start adds a little).
      // Out: 0.9 * peak 1.8 = 1.62 > 0.9 -> to 0.9.
      expect(loudest, closeTo(0.9, 0.02));
      expect(loudest * result.scale, closeTo(0.9, 1e-6));
    });

    test('silence gives no vocals', () {
      final mix = writeStereo('mix.f32', 50000, (c, i) => 0);
      final out = File('${dir.path}/vocals.f32');
      final result = separateVocals(mix.path, out.path, (s) => s);
      expect(result.frames, 0);
      expect(out.lengthSync(), 0);
    });

    test('a throw from onChunk stops between chunks', () {
      final mix = writeStereo(
        'mix.f32',
        14 * mdxSampleRate,
        (c, i) => 0.1 * math.sin(i / 10),
      );
      var runs = 0;
      expect(
        () => separateVocals(
          mix.path,
          '${dir.path}/vocals.f32',
          (s) {
            runs++;
            return s;
          },
          onChunk: (done, total) {
            if (done == 1) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(runs, 1);
    });
  });
}
