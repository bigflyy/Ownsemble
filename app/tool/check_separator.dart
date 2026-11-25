// Plan 10 I2b real check: Kim Vocal 2 in Dart on the worker, on real songs,
// kept for experiments/f2-timing/check_separator.py to compare with
// audio-separator 0.48.0 (the research's separator).
//
// Run from app/ (a model run: through agg-queue):
//   dart run tool/check_separator.dart --audio DIR --songs 13,55,57
//       --models DIR --out DIR [--asym 13,55] [--threads 8] [--arena]
//       [--gpu-onnx DLL] [--dml N]
// --gpu-onnx is the DirectML build's onnxruntime.dll (plan 10 I2i),
// --dml N separates on DirectML adapter N.
//
// For each song DIR/<n>.mp3: OUT/<n>.mix.f32 (the decoded 44.1 kHz stereo
// mix), OUT/<n>.vocals.f32 (44.1 kHz stereo vocals before the last
// scale), OUT/<n>.vocals16.f32 (what the app keeps: 16 kHz mono), and one
// line of times, chunks, scale and memory. --asym A,B also makes a stereo
// test song from A's left and B's right channel (OUT/asym.wav), so a mixed
// up or shifted channel shows.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/lyrics/audio_decode.dart';
import 'package:ownsemble/lyrics/mdx_separator.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final audioDir = valueOf('--audio');
  final songs = valueOf('--songs');
  final modelsDir = valueOf('--models');
  final outDir = valueOf('--out');
  if (audioDir == null ||
      songs == null ||
      modelsDir == null ||
      outDir == null) {
    print(
      'usage: --audio DIR --songs 1,2 --models DIR --out DIR '
      '[--asym A,B] [--threads N]',
    );
    exit(2);
  }
  final threads = int.tryParse(valueOf('--threads') ?? '') ?? 8;
  final arena = args.contains('--arena');
  final root = Directory(modelsDir);
  if (!bundleReady(root, hearWordsBundle)) {
    print('hear-words bundle not ready in $modelsDir');
    exit(1);
  }
  final modelPath = bundleFile(root, hearWordsBundle, 'Kim_Vocal_2.onnx').path;
  final release = p.join('build', 'windows', 'x64', 'runner', 'Release');
  final mpvPath = p.absolute(release, 'libmpv-2.dll');
  final onnxPath = p.absolute(release, 'onnxruntime.dll');
  final gpuOnnx = valueOf('--gpu-onnx');
  final directMl = int.tryParse(valueOf('--dml') ?? '');
  final out = Directory(outDir)..createSync(recursive: true);
  final temp = Directory(p.join(outDir, 'tmp'))..createSync();

  final inputs = <String, String>{
    for (final n in songs.split(',')) n: p.join(audioDir, '$n.mp3'),
  };
  final asym = valueOf('--asym');
  if (asym != null) {
    final [a, b] = asym.split(',');
    inputs['asym'] = _makeAsym(
      mpvPath,
      p.join(audioDir, '$a.mp3'),
      p.join(audioDir, '$b.mp3'),
      p.join(outDir, 'asym.wav'),
      temp.path,
    );
  }

  final worker = SttWorker(
    onnxRuntimePath: onnxPath,
    gpuOnnxRuntimePath: gpuOnnx == null ? null : p.absolute(gpuOnnx),
    log: print,
  );
  try {
    for (final MapEntry(key: name, value: path) in inputs.entries) {
      final keep = p.join(out.path, name);
      final task = worker.run(
        VocalsJob(
          audioPath: path,
          outPath: '$keep.vocals16.f32',
          modelPath: modelPath,
          mpvPath: mpvPath,
          tempDir: temp.path,
          threads: threads,
          memoryArena: arena,
          directMlDevice: directMl,
          keepStereoAt: keep,
        ),
      );
      final result = await task.result;
      final memory = task.memory!;
      final line = {
        'song': name,
        'seconds': result.samples / 16000,
        'chunks': result.chunks,
        'decode_ms': result.decodeMs,
        'separate_ms': result.separateMs,
        'resample_ms': result.resampleMs,
        'model_ms': result.modelMs,
        'spectrum_ms': result.spectrumMs,
        'threads': threads,
        'arena': arena,
        'gpu_onnx': gpuOnnx,
        'dml': directMl,
        'scale': result.scale,
        'peak_ws_mb': memory.peakWorkingSet ~/ (1 << 20),
        'peak_private_mb': memory.peakPrivate ~/ (1 << 20),
        'after_ws_mb': memory.afterWorkingSet ~/ (1 << 20),
        'after_private_mb': memory.afterPrivate ~/ (1 << 20),
      };
      print(jsonEncode(line));
      File(p.join(out.path, 'dart-runs.jsonl'))
          .writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append);
    }
  } finally {
    await worker.close();
  }
}

/// A 44.1 kHz stereo float WAV of [a]'s left and [b]'s right channel, as
/// long as the shorter of the two.
String _makeAsym(String mpv, String a, String b, String target, String temp) {
  Float32List stereo(String path) {
    final file = decodeToFile(mpv, path, temp, sampleRate: 44100, channels: 2);
    try {
      return Float32List.sublistView(file.readAsBytesSync());
    } finally {
      file.deleteSync();
    }
  }

  final left = stereo(a);
  final right = stereo(b);
  final frames = (left.length < right.length ? left.length : right.length) ~/ 2;
  final data = Float32List(2 * frames);
  for (var i = 0; i < frames; i++) {
    data[2 * i] = left[2 * i];
    data[2 * i + 1] = right[2 * i + 1];
  }
  final header = ByteData(44);
  void text(int at, String s) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  final bytes = data.lengthInBytes;
  text(0, 'RIFF');
  header.setUint32(4, 36 + bytes, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 3, Endian.little); // IEEE float
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, mdxSampleRate, Endian.little);
  header.setUint32(28, mdxSampleRate * 8, Endian.little);
  header.setUint16(32, 8, Endian.little);
  header.setUint16(34, 32, Endian.little);
  text(36, 'data');
  header.setUint32(40, bytes, Endian.little);
  File(target)
    ..writeAsBytesSync(header.buffer.asUint8List())
    ..writeAsBytesSync(Uint8List.sublistView(data), mode: FileMode.append);
  return target;
}
