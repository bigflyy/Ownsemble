// Check for plan 10 G1: the app's ONNX Runtime binding and chunked model
// run (lib/lyrics/onnx_runtime.dart, emission_model.dart) against the
// Python research's int8 run on the same audio.
//
//   dart run tool/check_emission.dart DATA_DIR MODEL.onnx ONNXRUNTIME.dll
//       [--only 0,11] [--threads 4]
//
// For every DATA_DIR/vocals/<index>.flac with a cached Python output in
// DATA_DIR/emission-vocals-onnx/<index>.npy, the audio is decoded with
// ffmpeg (this PC's, a tool-only shortcut; the app decodes otherwise), run
// through the model here, and compared: frame counts, the largest
// difference in log probability, and the line starts both give. It loads a
// 355 MB model on 4 threads: run it through agg-queue. Prints numbers only.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ownsemble/lyrics/emission_model.dart';
import 'package:ownsemble/lyrics/line_fit.dart';
import 'package:ownsemble/lyrics/onnx_runtime.dart';

import 'check_line_fit.dart' show readNpy;

Float32List decode(String path) {
  final result = Process.runSync('ffmpeg', [
    '-v', 'error', '-i', path, '-ac', '1', //
    '-ar', '$modelSampleRate', '-f', 'f32le', '-',
  ], stdoutEncoding: null);
  if (result.exitCode != 0) throw StateError('ffmpeg: ${result.stderr}');
  final bytes = Uint8List.fromList(result.stdout as List<int>);
  return Float32List.sublistView(bytes);
}

void main(List<String> args) {
  final data = args[0];
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final only = (valueOf('--only') ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toSet();
  final threads = int.parse(valueOf('--threads') ?? '4');
  final ort = OnnxRuntime.load(args[2]);
  final clock = Stopwatch()..start();
  final session = ort.open(args[1], threads: threads);
  print(
    'onnxruntime ${ort.version}, model opened in ${clock.elapsedMilliseconds} ms',
  );
  final rss = ProcessInfo.currentRss ~/ (1 << 20);
  print('memory after open: $rss MB');

  final cached =
      Directory('$data/emission-vocals-onnx')
          .listSync()
          .whereType<File>()
          .map((f) => int.parse(f.uri.pathSegments.last.split('.').first))
          .where((i) => only.isEmpty || only.contains(i))
          .toList()
        ..sort();
  var peak = 0;
  for (final index in cached) {
    final flac = '$data/vocals/$index.flac';
    if (!File(flac).existsSync()) continue;
    final samples = decode(flac);
    final seconds = samples.length / modelSampleRate;
    clock.reset();
    final mine = modelEmission(session, samples);
    final runMs = clock.elapsedMilliseconds;
    final rssNow = ProcessInfo.currentRss ~/ (1 << 20);
    if (rssNow > peak) peak = rssNow;
    final dump = valueOf('--dump');
    if (dump != null) {
      File('$dump/dart-emission-$index.f32').writeAsBytesSync(
        mine.values.buffer.asUint8List(
          mine.values.offsetInBytes,
          mine.values.lengthInBytes,
        ),
      );
    }
    final theirs = readNpy(File('$data/emission-vocals-onnx/$index.npy'));
    var maxDiff = 0.0;
    // Differences in probability (0..1), where the alignment feels them;
    // log differences on letters that are next to impossible do not count.
    var maxProb = 0.0;
    final n = mine.values.length < theirs.values.length
        ? mine.values.length
        : theirs.values.length;
    for (var k = 0; k < n; k++) {
      final d = (mine.values[k] - theirs.values[k]).abs();
      if (d > maxDiff) maxDiff = d;
      final dp = (math.exp(mine.values[k]) - math.exp(theirs.values[k])).abs();
      if (dp > maxProb) maxProb = dp;
    }
    // Line starts from both, for every source of the song.
    final song = jsonDecode(
      File('$data/songs/$index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    var lines = 0;
    var moved = 0;
    for (final lyric in (song['sources'] as Map<String, dynamic>).values) {
      final sung = sungLines([
        for (final l in lyric as List)
          (
            startMs: (l as Map)['s'] as int?,
            endMs: l['e'] as int?,
            text: l['t'] as String,
          ),
      ]);
      if (sung.length < 3) continue;
      final a = fitLines(mine, sung, seconds / mine.frames);
      final b = fitLines(theirs, sung, seconds / theirs.frames);
      for (var k = 0; k < a.length && k < b.length; k++) {
        lines++;
        if ((a[k].start - b[k].start).abs() > 0.05) moved++;
      }
    }
    print(
      '#$index ${seconds.toStringAsFixed(0)} s: frames ${mine.frames} vs '
      '${theirs.frames}, max log-prob difference '
      '${maxDiff.toStringAsFixed(4)} (probability '
      '${maxProb.toStringAsFixed(4)}), line starts differing > 50 ms: '
      '$moved of $lines; $runMs ms '
      '(${(runMs / 1000 / seconds).toStringAsFixed(3)} s per audio second), '
      'memory $rssNow MB',
    );
  }
  session.close();
  print('peak memory $peak MB');
}
