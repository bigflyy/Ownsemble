// Plan 10 I2d real check: Whisper turbo through whisper.cpp and the
// ownsemble_whisper bridge, on the worker, on 16 kHz vocals; written for
// experiments/f2-timing/check_whisper.py to compare with gigaam_app's
// WhisperModel (experiments/f2-timing/whisper_ref.py).
//
// Run from app/ (a model run: through agg-queue):
//   dart run tool/check_whisper.dart --vocals DIR --models DIR --out DIR
//       --bridge DLL [--threads 8] [--language CODE] [--tag dart]
//       [--model FILE] [--libs DIR] [--cancel-in-chunk N] NAMES...
//
// For each NAME (DIR/NAME.vocals16.f32): OUT/NAME.TAG.json (chunks with
// their language, tokens as hex bytes with times and probabilities, words,
// confidences, times, memory) and one line of numbers per song (no words).
// --model / --libs use another model file or whisper.cpp folder than the
// bundle's (the non-ASCII path check). --cancel-in-chunk N cancels the
// first song's job one second into chunk N (inside whisper.cpp's call) and
// logs how long the stop took (exit code 1 unless it stopped inside that
// chunk); the other names then run as usual.
// --load-only prints whisper.cpp's version, backends and CPU features.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/whisper_cpp.dart';
import 'package:ownsemble/lyrics/whisper_job.dart';
import 'package:path/path.dart' as p;

String _hex(Uint8List bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Future<void> main(List<String> args) async {
  final names = <String>[];
  final values = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--load-only') {
      flags.add(arg);
    } else if (arg.startsWith('--') && i + 1 < args.length) {
      values[arg] = args[++i];
    } else {
      names.add(arg);
    }
  }
  final modelsDir = values['--models'];
  final bridge = values['--bridge'];
  if (modelsDir == null || bridge == null) {
    print(
      'usage: --vocals DIR --models DIR --out DIR --bridge DLL [--threads N] '
      '[--language CODE] [--tag T] [--model FILE] [--libs DIR] '
      '[--cancel-in-chunk N] [--load-only] NAMES...',
    );
    exit(2);
  }
  final root = Directory(modelsDir);
  if (!bundleReady(root, whisperBundle) ||
      !bundleReady(root, hearWordsBundle)) {
    print('whisper-turbo or hear-words bundle not ready in $modelsDir');
    exit(1);
  }
  final libs =
      values['--libs'] ??
      bundleFile(root, whisperBundle, 'whisper.cpp/whisper.dll').parent.path;
  final modelPath =
      values['--model'] ??
      bundleFile(root, whisperBundle, 'ggml-large-v3-turbo-q5_0.bin').path;
  if (flags.contains('--load-only')) {
    final library = WhisperLibrary.load(bridge, libs);
    print('whisper_version: ${library.version}');
    print('backends: ${library.backends}');
    print('system: ${library.systemInfo}');
    return;
  }
  final vocalsDir = values['--vocals'];
  final outDir = values['--out'];
  if (vocalsDir == null || outDir == null || names.isEmpty) {
    print('--vocals, --out and NAMES are needed');
    exit(2);
  }
  final threads = int.tryParse(values['--threads'] ?? '') ?? 8;
  final language = values['--language'];
  final tag = values['--tag'] ?? 'dart';
  final cancelIn = int.tryParse(values['--cancel-in-chunk'] ?? '');
  final sileroPath = bundleFile(
    root,
    hearWordsBundle,
    'silero_vad_scan.onnx',
  ).path;
  final release = p.join('build', 'windows', 'x64', 'runner', 'Release');
  final onnxPath = p.absolute(release, 'onnxruntime.dll');
  final out = Directory(outDir)..createSync(recursive: true);

  final worker = SttWorker(onnxRuntimePath: onnxPath, log: print);
  try {
    for (final (index, name) in names.indexed) {
      final task = worker.run(
        WhisperJob(
          vocalsPath: p.join(vocalsDir, '$name.vocals16.f32'),
          bridgePath: bridge,
          libraryFolder: libs,
          modelPath: modelPath,
          sileroPath: sileroPath,
          threads: threads,
          language: language,
        ),
      );
      final clock = Stopwatch()..start();
      if (index == 0 && cancelIn != null) {
        await _cancelInChunk(task, cancelIn, name, clock);
        continue;
      }
      final job = await task.result;
      final totalMs = clock.elapsedMilliseconds;
      final memory = task.memory!;
      final result = job.result;
      final words = result.words;
      final summary = {
        'name': name,
        'tag': tag,
        'seconds': result.samples / 16000,
        'chunks': result.chunks.length,
        'words': words.length,
        'languages': {
          for (final chunk in result.chunks)
            chunk.language: result.chunks
                .where((c) => c.language == chunk.language)
                .length,
        },
        'mean_confidence': result.meanConfidence,
        'total_ms': totalMs,
        'load_ms': job.loadMs,
        'vad_ms': job.vadMs,
        'open_ms': job.openMs,
        'transcribe_ms': job.transcribeMs,
        'threads': threads,
        'language': language ?? 'auto',
        'peak_ws_mb': memory.peakWorkingSet ~/ (1 << 20),
        'peak_private_mb': memory.peakPrivate ~/ (1 << 20),
        'after_ws_mb': memory.afterWorkingSet ~/ (1 << 20),
        'after_private_mb': memory.afterPrivate ~/ (1 << 20),
      };
      print(jsonEncode(summary));
      File(p.join(out.path, 'dart-runs.jsonl'))
          .writeAsStringSync('${jsonEncode(summary)}\n', mode: FileMode.append);
      final detail = {
        ...summary,
        'speech_seconds': result.speechSeconds,
        'chunk_ms': job.chunkMs,
        'chunks': [
          for (final chunk in result.chunks)
            {
              'start': chunk.range.start,
              'end': chunk.range.end,
              'language': chunk.language,
              'tokens': [
                for (final t in chunk.tokens)
                  [_hex(t.bytes), t.start, t.end, t.probability],
              ],
              'words': [
                for (final w in chunk.words)
                  [w.start, w.end, w.text, w.confidence],
              ],
            },
        ],
      };
      File(p.join(out.path, '$name.$tag.json'))
          .writeAsStringSync(jsonEncode(detail));
    }
  } finally {
    await worker.close();
  }
}

/// Cancels [task] one second into chunk [chunk] (1-based) and prints how
/// long the job took to stop.
Future<void> _cancelInChunk(
  WorkerTask<WhisperJobResult> task,
  int chunk,
  String name,
  Stopwatch clock,
) async {
  var cancelledAt = -1;
  var lastProgress = '';
  final subscription = task.progress.listen((progress) {
    lastProgress = '${progress.stage} ${progress.done}/${progress.total}';
    // Chunk 1 starts once the model is open, chunk N after chunk N - 1.
    final started = chunk == 1
        ? progress.stage == 'open'
        : progress.stage == 'hear' && progress.done == chunk - 1;
    if (started && cancelledAt < 0) {
      Timer(const Duration(seconds: 1), () {
        cancelledAt = clock.elapsedMilliseconds;
        task.cancel();
      });
    }
  });
  String outcome;
  try {
    await task.result;
    outcome = 'finished';
  } on WorkerCancelled {
    outcome = 'cancelled';
  }
  await subscription.cancel();
  final stoppedAt = clock.elapsedMilliseconds;
  final line = {
    'name': name,
    'cancel_in_chunk': chunk,
    'outcome': outcome,
    'last_progress': lastProgress,
    'cancelled_at_ms': cancelledAt,
    'stop_ms': cancelledAt < 0 ? null : stoppedAt - cancelledAt,
    'after_ws_mb': (task.memory?.afterWorkingSet ?? 0) ~/ (1 << 20),
  };
  print(jsonEncode(line));
  // The check holds only if the job stopped inside the chunk asked for.
  final inside = chunk == 1
      ? lastProgress.startsWith('open')
      : lastProgress == 'hear ${chunk - 1}/${lastProgress.split('/').last}';
  if (outcome != 'cancelled' || cancelledAt < 0 || !inside) {
    print('cancel check FAILED');
    exitCode = 1;
  }
}
