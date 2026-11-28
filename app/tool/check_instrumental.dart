// Plan 11 D1d real check: the karaoke instrumental (UVR-MDX-NET Inst HQ 4)
// in Dart on the worker, on real songs, kept for
// experiments/karaoke/check_instrumental.py to compare with audio-separator's
// output of the same model (plan 11 A3b, the files the user listened to).
//
// Run from app/ (a model run: through agg-queue):
//   dart run tool/check_instrumental.dart --audio DIR --songs 13,57
//       --model FILE --out DIR [--threads 8] [--gpu-onnx DLL --dml N]
//
// For each song DIR/<n>.mp3: OUT/<n>.inst.f32 (44.1 kHz stereo floats at
// the song's level) and one JSON line of times, chunks and memory.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/karaoke/instrumental_job.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final audioDir = valueOf('--audio');
  final songs = valueOf('--songs');
  final model = valueOf('--model');
  final outDir = valueOf('--out');
  if (audioDir == null || songs == null || model == null || outDir == null) {
    print('usage: --audio DIR --songs 1,2 --model FILE --out DIR');
    exit(2);
  }
  final threads = int.tryParse(valueOf('--threads') ?? '') ?? 8;
  final release = p.join('build', 'windows', 'x64', 'runner', 'Release');
  final gpuOnnx = valueOf('--gpu-onnx');
  final directMl = int.tryParse(valueOf('--dml') ?? '');
  final out = Directory(outDir)..createSync(recursive: true);
  final temp = Directory(p.join(outDir, 'tmp'))..createSync();
  final worker = SttWorker(
    onnxRuntimePath: p.absolute(release, 'onnxruntime.dll'),
    gpuOnnxRuntimePath: gpuOnnx == null ? null : p.absolute(gpuOnnx),
    log: print,
  );
  try {
    for (final name in songs.split(',')) {
      final task = worker.run(
        InstrumentalJob(
          audioPath: p.join(audioDir, '$name.mp3'),
          outPath: p.join(out.path, '$name.inst.f32'),
          modelPath: p.absolute(model),
          mpvPath: p.absolute(release, 'libmpv-2.dll'),
          tempDir: temp.path,
          threads: threads,
          directMlDevice: directMl,
        ),
      );
      final result = await task.result;
      final memory = task.memory!;
      final line = {
        'song': name,
        'seconds': result.frames / 44100,
        'chunks': result.chunks,
        'decode_ms': result.decodeMs,
        'separate_ms': result.separateMs,
        'model_ms': result.modelMs,
        'spectrum_ms': result.spectrumMs,
        'input_scale': result.inputScale,
        'threads': threads,
        'dml': directMl,
        'peak_ws_mb': memory.peakWorkingSet ~/ (1 << 20),
        'peak_private_mb': memory.peakPrivate ~/ (1 << 20),
      };
      print(jsonEncode(line));
      File(p.join(out.path, 'dart-runs.jsonl'))
          .writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append);
    }
  } finally {
    await worker.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}
