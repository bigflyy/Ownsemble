/// The song without its voice for the karaoke export (plan 11 D1d), by
/// UVR-MDX-NET Inst HQ 4 on the hear helper's worker: the CPU way (user
/// 2026-11-28: "for cpu we can use small models").
///
/// Units: decode the song at 44.1 kHz stereo (mpv); the separator chunk by
/// chunk (about 6 s of song each), the same steps as Kim Vocal 2's with Inst
/// HQ 4's sizes; the model closed. The model's output is the instrumental
/// itself (its primary stem). The written samples are divided by the factor
/// the mix got before the model (0.9 / peak for a loud song), so the
/// instrumental keeps the song's own level; the export then brings the
/// whole track under full scale with one gain. The output file appears only
/// whole (written beside, then renamed), and the decoded mix goes in any
/// case.
library;

import 'dart:io';

import '../lyrics/audio_decode.dart';
import '../lyrics/mdx_separator.dart';
import '../lyrics/stt_worker.dart';
import 'karaoke_audio.dart';

/// What [InstrumentalJob] gives back.
class InstrumentalResult {
  const InstrumentalResult({
    required this.frames,
    required this.chunks,
    required this.decodeMs,
    required this.separateMs,
    required this.inputScale,
    this.modelMs = 0,
    this.spectrumMs = 0,
  });

  /// Stereo frames written (the song's length at 44.1 kHz).
  final int frames;
  final int chunks;
  final int decodeMs;
  final int separateMs;

  /// Of [separateMs]: inside the model, and in the STFT and its inverse.
  final int modelMs;
  final int spectrumMs;

  /// What the mix was multiplied by before the model (1 for a quiet song).
  final double inputScale;
}

/// Writes the instrumental of [audioPath] to [outPath]: 44.1 kHz stereo
/// raw floats, interleaved, little endian, at the song's level.
class InstrumentalJob extends WorkerJob<InstrumentalResult> {
  const InstrumentalJob({
    required this.audioPath,
    required this.outPath,
    required this.modelPath,
    required this.mpvPath,
    required this.tempDir,
    required this.threads,
    this.memoryArena = false,
    this.directMlDevice,
  });

  final String audioPath;
  final String outPath;

  /// UVR-MDX-NET-Inst_HQ_4.onnx.
  final String modelPath;

  /// libmpv-2.dll beside the app.
  final String mpvPath;
  final String tempDir;

  /// Threads inside each model operation.
  final int threads;

  /// ONNX Runtime's memory arena (off, as for Kim Vocal 2: with it the
  /// separator kept about 4.5 GB private memory, session 51).
  final bool memoryArena;

  /// The DirectML adapter to separate on, or null for the CPU.
  final int? directMlDevice;

  @override
  String get name => 'instrumental';

  @override
  InstrumentalResult run(WorkerContext context) {
    final clock = Stopwatch()..start();
    final partial = File('$outPath.part');
    File? mix;
    try {
      mix = decodeToFile(
        mpvPath,
        audioPath,
        tempDir,
        sampleRate: mdxSampleRate,
        channels: 2,
        timeout: const Duration(minutes: 3),
      );
      final decodeMs = clock.elapsedMilliseconds;
      context.unitDone('decode', 1, 1);

      final session = context.model(
        modelPath,
        threads: threads,
        memoryArena: memoryArena,
        directMlDevice: directMlDevice,
      );
      partial.parent.createSync(recursive: true);
      if (partial.existsSync()) partial.deleteSync();
      const spec = instHq4Spec;
      final separated = separateVocals(
        mix.path,
        partial.path,
        (spectrum) =>
            session.run('input', spectrum, spec.inputShape, 'output').values,
        onChunk: (done, total) => context.unitDone('separate', done, total),
        spec: spec,
      );
      context.freeModel();
      final separateMs = clock.elapsedMilliseconds - decodeMs;
      if (separated.frames == 0) {
        // A silent song: its instrumental is the same silence.
        mix.copySync(partial.path);
      } else {
        applyGain(partial, 1 / separated.inputScale);
      }
      if (File(outPath).existsSync()) File(outPath).deleteSync();
      partial.renameSync(outPath);
      return InstrumentalResult(
        frames: File(outPath).lengthSync() ~/ 8,
        chunks: separated.chunks,
        decodeMs: decodeMs,
        separateMs: separateMs,
        inputScale: separated.inputScale,
        modelMs: separated.modelMs,
        spectrumMs: separated.spectrumMs,
      );
    } finally {
      for (final file in [?mix, partial]) {
        try {
          if (file.existsSync()) file.deleteSync();
        } on FileSystemException {
          // Removed with the job folder later.
        }
      }
    }
  }
}
