/// The first stage of "Hear the words" (plan 10 I2b): a song's vocals as
/// 16 kHz mono float samples, by Kim Vocal 2 on the worker.
///
/// Units: decode the song at 44.1 kHz stereo (mpv); the separator chunk
/// by chunk (about 6 s of song each); the model closed; the vocals to
/// 16 kHz mono with the same resampler the aligner's audio uses (mpv,
/// ffmpeg's filter); the final scale. The output file appears only whole
/// (written beside, then renamed), and the temporary files go in any case.
library;

import 'dart:io';
import 'dart:typed_data';

import 'audio_decode.dart';
import 'mdx_separator.dart';
import 'stt_worker.dart';

/// What [VocalsJob] gives back.
class VocalsResult {
  const VocalsResult({
    required this.samples,
    required this.chunks,
    required this.decodeMs,
    required this.separateMs,
    required this.resampleMs,
    required this.scale,
    this.modelMs = 0,
    this.spectrumMs = 0,
  });

  /// Of [separateMs]: inside the model, and in the STFT and its inverse.
  final int modelMs;
  final int spectrumMs;

  /// 16 kHz samples written (0 for a silent song).
  final int samples;
  final int chunks;
  final int decodeMs;
  final int separateMs;
  final int resampleMs;

  /// The factor the 44.1 kHz vocals got at the end ([MdxResult.scale]).
  final double scale;
}

/// Separates the vocals of [audioPath] into [outPath] (16 kHz mono float,
/// little endian, no header).
class VocalsJob extends WorkerJob<VocalsResult> {
  const VocalsJob({
    required this.audioPath,
    required this.outPath,
    required this.modelPath,
    required this.mpvPath,
    required this.tempDir,
    required this.threads,
    this.memoryArena = false,
    this.directMlDevice,
    this.keepStereoAt,
  });

  final String audioPath;
  final String outPath;

  /// Kim_Vocal_2.onnx.
  final String modelPath;

  /// libmpv-2.dll beside the app.
  final String mpvPath;
  final String tempDir;

  /// Threads inside each model operation.
  final int threads;

  /// ONNX Runtime's memory arena (off by default: with it the separator
  /// kept about 4.5 GB private memory, session 51).
  final bool memoryArena;

  /// The DirectML adapter to separate on, or null for the CPU (plan 10
  /// I2i; the worker's runtime must be the DirectML build).
  final int? directMlDevice;

  /// For checks only: the decoded mix and the 44.1 kHz stereo vocals
  /// before the final scale are kept as `<keepStereoAt>.mix.f32` and
  /// `<keepStereoAt>.vocals.f32`.
  final String? keepStereoAt;

  @override
  String get name => 'separate';

  @override
  VocalsResult run(WorkerContext context) {
    final clock = Stopwatch()..start();
    final temps = <File>[];
    try {
      final mix = decodeToFile(
        mpvPath,
        audioPath,
        tempDir,
        sampleRate: mdxSampleRate,
        channels: 2,
        timeout: const Duration(minutes: 3),
      );
      temps.add(mix);
      final decodeMs = clock.elapsedMilliseconds;
      context.unitDone('decode', 1, 1);

      final session = context.model(
        modelPath,
        threads: threads,
        memoryArena: memoryArena,
        directMlDevice: directMlDevice,
      );
      final vocals44 = File('${mix.path}.vocals');
      temps.add(vocals44);
      final separated = separateVocals(
        mix.path,
        vocals44.path,
        (spectrum) => session.run('input', spectrum, const [
          1,
          4,
          mdxBins,
          mdxFrames,
        ], 'output').values,
        onChunk: (done, total) => context.unitDone('separate', done, total),
      );
      context.freeModel();
      final separateMs = clock.elapsedMilliseconds - decodeMs;
      final keep = keepStereoAt;
      if (keep != null) {
        mix.copySync('$keep.mix.f32');
        vocals44.copySync('$keep.vocals.f32');
      }

      final Float32List mono;
      if (separated.frames == 0) {
        mono = Float32List(0);
      } else {
        // Resampled by mpv still in stereo, then (L + R) / 2 here: mpv's
        // own downmix is 0.707 L + 0.707 R, a sqrt 2 louder than ffmpeg's
        // -ac 1 that made the research's vocals (session 51: 7.7 dB off,
        // exactly that gain), and the speech gate and GigaAM hear level.
        final file = decodeToFile(
          mpvPath,
          vocals44.path,
          tempDir,
          channels: 2,
          rawInput: (rate: mdxSampleRate, channels: 2),
          timeout: const Duration(minutes: 3),
        );
        temps.add(file);
        final bytes = file.readAsBytesSync();
        final stereo = Float32List.sublistView(bytes, 0, bytes.length ~/ 8 * 8);
        final half = 0.5 * separated.scale;
        mono = Float32List(stereo.length ~/ 2);
        for (var i = 0; i < mono.length; i++) {
          mono[i] = (stereo[2 * i] + stereo[2 * i + 1]) * half;
        }
      }
      final resampleMs = clock.elapsedMilliseconds - decodeMs - separateMs;
      final partial = File('$outPath.part');
      partial.parent.createSync(recursive: true);
      partial.writeAsBytesSync(Uint8List.sublistView(mono), flush: true);
      if (File(outPath).existsSync()) File(outPath).deleteSync();
      partial.renameSync(outPath);
      context.unitDone('resample', 1, 1);
      return VocalsResult(
        samples: mono.length,
        chunks: separated.chunks,
        decodeMs: decodeMs,
        separateMs: separateMs,
        resampleMs: resampleMs,
        scale: separated.scale,
        modelMs: separated.modelMs,
        spectrumMs: separated.spectrumMs,
      );
    } finally {
      for (final file in temps) {
        try {
          if (file.existsSync()) file.deleteSync();
        } on FileSystemException {
          // Removed with the temp folder later.
        }
      }
      final partial = File('$outPath.part');
      if (partial.existsSync()) partial.deleteSync();
    }
  }
}
