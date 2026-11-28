/// The level of a karaoke video's audio (plan 11 D1g).
///
/// Decoded songs often peak above full scale (1.02-1.32 in the Stage A
/// songs) and the song without its voice can peak higher still (up to
/// 1.42), so the AAC encoder would clip them. The whole track gets one gain
/// that brings its peak down to [karaokePeakLimit]; a track already below
/// it is left as it is, never made louder. The trimmed ffmpeg has no volume
/// filter, so the gain is applied here, in place, to the raw float file.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../lyrics/audio_decode.dart';
import 'karaoke_render.dart' show renderSampleRate;

/// The highest sample the video's audio may have: -1 dBFS, a little room
/// for the AAC encoder's own overshoot.
const karaokePeakLimit = 0.891;

/// Samples per piece read and written (1 MB of floats).
const _piece = 1 << 18;

/// The largest absolute sample in the raw float file [file] (any number of
/// channels, little endian).
double floatFilePeak(File file) {
  final raf = file.openSync();
  try {
    var peak = 0.0;
    final bytes = Uint8List(_piece * 4);
    while (true) {
      final got = raf.readIntoSync(bytes);
      if (got <= 0) break;
      final samples = Float32List.sublistView(bytes, 0, got ~/ 4 * 4);
      for (final s in samples) {
        // NaN and the infinities never count as loud (one infinite sample
        // would make the gain 0); [applyGain] clears them.
        if (!s.isFinite) continue;
        final a = s.abs();
        if (a > peak) peak = a;
      }
    }
    return peak;
  } finally {
    raf.closeSync();
  }
}

/// The one gain for a track whose largest sample is [peak].
double karaokeGain(double peak) =>
    peak > karaokePeakLimit ? karaokePeakLimit / peak : 1.0;

/// Multiplies every sample of the raw float file [file] by [gain], in
/// place, a piece at a time; NaN and infinite samples become 0. Nothing is
/// written when [gain] is 1 and [clearNaN] is false.
void applyGain(File file, double gain, {bool clearNaN = true}) {
  if (gain == 1 && !clearNaN) return;
  final raf = file.openSync(mode: FileMode.append);
  try {
    final bytes = Uint8List(_piece * 4);
    var at = 0;
    raf.setPositionSync(0);
    while (true) {
      raf.setPositionSync(at);
      final got = raf.readIntoSync(bytes);
      if (got <= 0) break;
      final whole = got ~/ 4 * 4;
      final samples = Float32List.sublistView(bytes, 0, whole);
      var changed = false;
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        final v = s.isFinite ? s * gain : 0.0;
        if (v != s) {
          samples[i] = v;
          changed = true;
        }
      }
      if (changed) {
        raf.setPositionSync(at);
        raf.writeFromSync(bytes, 0, whole);
      }
      at += whole;
      if (whole < got || got < bytes.length) break;
    }
  } finally {
    raf.closeSync();
  }
}

/// Brings the raw float file at [path] to the karaoke level in place, on a
/// background isolate: its peak, and the one gain it got.
Future<(double, double)> levelFloatFile(String path) => Isolate.run(() {
  final file = File(path);
  final peak = floatFilePeak(file);
  final gain = karaokeGain(peak);
  applyGain(file, gain);
  return (peak, gain);
});

/// Decodes [audioPath] to 44.1 kHz stereo raw floats at [outPath] with the
/// libmpv at [mpvPath] (the app's own, beside ownsemble.exe), on a
/// background isolate; mpv's temporary file goes beside [outPath]. Throws
/// [DecodeError].
Future<void> decodeForKaraoke(
  String mpvPath,
  String audioPath,
  String outPath,
) => Isolate.run(() {
  final file = decodeToFile(
    mpvPath,
    audioPath,
    p.dirname(outPath),
    sampleRate: renderSampleRate,
    channels: 2,
    timeout: const Duration(minutes: 3),
  );
  file.renameSync(outPath);
});
