// Plan 10 I2c real check: GigaAM RNNT int8 and Silero VAD in Dart on the
// worker, on the 16 kHz vocals tool/check_separator.dart kept, written for
// experiments/f2-timing/check_gigaam.py to compare with gigaam_app (the
// research's recogniser, experiments/f2-timing/gigaam_ref.py).
//
// Run from app/ (a model run: through agg-queue):
//   dart run tool/check_gigaam.dart --vocals DIR --models DIR --out DIR
//       [--threads 8] [--arena] [--repeat N] [--gpu-onnx DLL] [--dml N] NAMES...
// --gpu-onnx is the DirectML build's onnxruntime.dll (plan 10 I2i),
// --dml N runs the encoder on DirectML adapter N.
//
// For each NAME (DIR/NAME.vocals16.f32): OUT/NAME.dart.json (chunks,
// tokens, words, confidences, times, memory), OUT/NAME.dart.vad.f32 and
// OUT/NAME.dart.enc0.f32, as gigaam_ref.py writes them; one line of
// numbers per run (no words). OUT/groups.dart.json holds the letter groups.
// --repeat N runs every name N times (timing; files from the last run).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/lyrics/gigaam.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final names = <String>[];
  final values = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--arena') {
      flags.add(arg);
    } else if (arg.startsWith('--') && i + 1 < args.length) {
      values[arg] = args[++i];
    } else {
      names.add(arg);
    }
  }
  final vocalsDir = values['--vocals'];
  final modelsDir = values['--models'];
  final outDir = values['--out'];
  if (vocalsDir == null ||
      modelsDir == null ||
      outDir == null ||
      names.isEmpty) {
    print(
      'usage: --vocals DIR --models DIR --out DIR [--threads N] [--arena] '
      '[--repeat N] NAMES...',
    );
    exit(2);
  }
  final threads = int.tryParse(values['--threads'] ?? '') ?? 8;
  final repeat = int.tryParse(values['--repeat'] ?? '') ?? 1;
  final arena = flags.contains('--arena');
  final root = Directory(modelsDir);
  if (!bundleReady(root, hearWordsBundle)) {
    print('hear-words bundle not ready in $modelsDir');
    exit(1);
  }
  final gigaamFolder = p.dirname(
    bundleFile(root, hearWordsBundle, 'gigaam/model.json').path,
  );
  final sileroPath = bundleFile(
    root,
    hearWordsBundle,
    'silero_vad_scan.onnx',
  ).path;
  final release = p.join('build', 'windows', 'x64', 'runner', 'Release');
  final onnxPath = p.absolute(release, 'onnxruntime.dll');
  final gpuOnnx = values['--gpu-onnx'];
  final directMl = int.tryParse(values['--dml'] ?? '');
  final out = Directory(outDir)..createSync(recursive: true);

  final model = GigaamModel.load(gigaamFolder);
  File(p.join(out.path, 'groups.dart.json')).writeAsStringSync(
    jsonEncode([for (final group in model.groups) group?.toList()]),
  );

  final worker = SttWorker(
    onnxRuntimePath: onnxPath,
    gpuOnnxRuntimePath: gpuOnnx == null ? null : p.absolute(gpuOnnx),
    log: print,
  );
  try {
    for (var run = 0; run < repeat; run++) {
      for (final name in names) {
        final task = worker.run(
          GigaamJob(
            vocalsPath: p.join(vocalsDir, '$name.vocals16.f32'),
            modelFolder: gigaamFolder,
            sileroPath: sileroPath,
            threads: threads,
            memoryArena: arena,
            directMlDevice: directMl,
            keepForChecks: true,
          ),
        );
        final clock = Stopwatch()..start();
        final job = await task.result;
        final totalMs = clock.elapsedMilliseconds;
        final memory = task.memory!;
        final result = job.result;
        _writeFloats(p.join(out.path, '$name.dart.vad.f32'), job.probabilities);
        _writeFloats(p.join(out.path, '$name.dart.enc0.f32'), job.firstEncoded);
        final words = result.words;
        final summary = {
          'name': name,
          'run': run,
          'seconds': result.samples / 16000,
          'chunks': result.chunks.length,
          'words': words.length,
          'mean_confidence': result.meanConfidence,
          'russian': result.isRussian,
          'total_ms': totalMs,
          'load_ms': job.loadMs,
          'vad_ms': job.vadMs,
          'open_ms': job.openMs,
          'encode_ms': job.encodeMs,
          'decode_ms': job.decodeMs,
          'threads': threads,
          'arena': arena,
          'gpu_onnx': gpuOnnx,
          'dml': directMl,
          'peak_ws_mb': memory.peakWorkingSet ~/ (1 << 20),
          'peak_private_mb': memory.peakPrivate ~/ (1 << 20),
          'after_ws_mb': memory.afterWorkingSet ~/ (1 << 20),
          'after_private_mb': memory.afterPrivate ~/ (1 << 20),
        };
        print(jsonEncode(summary));
        File(
          p.join(out.path, 'dart-runs.jsonl'),
        ).writeAsStringSync('${jsonEncode(summary)}\n', mode: FileMode.append);
        final detail = {
          ...summary,
          'speech_seconds': result.speechSeconds,
          'chunks': [
            for (final chunk in result.chunks)
              {
                'start': chunk.range.start,
                'end': chunk.range.end,
                'frames': chunk.frames,
                'tokens': [
                  for (final t in chunk.tokens)
                    [t.token, t.frame, t.confidence],
                ],
                'words': [
                  for (final w in chunk.words)
                    [w.start, w.end, w.text, w.confidence],
                ],
              },
          ],
        };
        File(p.join(out.path, '$name.dart.json'))
            .writeAsStringSync(jsonEncode(detail));
      }
    }
  } finally {
    await worker.close();
  }
}

void _writeFloats(String path, Float32List? values) {
  if (values == null) return;
  File(path).writeAsBytesSync(Uint8List.sublistView(values));
}
