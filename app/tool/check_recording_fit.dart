// Check for plan 10 G1: "Fit to this recording" end to end as the app runs
// it (lib/lyrics/recording_fit.dart: a background isolate with libmpv,
// ONNX Runtime and the aligner), on songs the research saved.
//
//   dart run tool/check_recording_fit.dart DATA_DIR INDEX[,INDEX] MODEL.onnx
//       ONNXRUNTIME.dll LIBMPV.dll
//
// For each song and each of its timed sources: progress events, time,
// the share of sure lines, how far the lines moved (median and largest),
// and the process memory before, at its peak during, and after the fit
// (the model's memory should be gone once the isolate ends). It loads a
// 355 MB model on 4 threads: run it through agg-queue. Prints numbers only.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/recording_fit.dart';

int rssMb() => ProcessInfo.currentRss ~/ (1 << 20);

Future<void> main(List<String> args) async {
  final data = args[0];
  final tools = FitTools(
    modelPath: File(args[2]).absolute.path,
    onnxRuntimePath: File(args[3]).absolute.path,
    mpvPath: File(args[4]).absolute.path,
    tempDir: Directory.systemTemp.path,
  );
  for (final index in args[1].split(',').map(int.parse)) {
    final song = jsonDecode(
      File('$data/songs/$index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final source in (song['sources'] as Map<String, dynamic>).entries) {
      final lines = [
        for (final l in source.value as List)
          LyricLine(
            (l as Map)['t'] as String,
            startMs: l['s'] as int?,
            endMs: l['e'] as int?,
          ),
      ];
      final before = rssMb();
      var peak = before;
      final sampler = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final now = rssMb();
        if (now > peak) peak = now;
      });
      var events = 0;
      var lastTotal = 0;
      try {
        final fit = await fitToRecording(
          File('$data/audio/$index.mp3').absolute.path,
          lines,
          tools,
          onProgress: (done, total) {
            events++;
            lastTotal = total;
          },
        );
        final moves = [
          for (final e in fit.lines.entries)
            ((e.value.startMs - lines[e.key].startMs!) / 1000).abs(),
        ]..sort();
        print(
          '#$index ${source.key}: ${fit.lines.length} lines, sure '
          '${fit.sureShare.toStringAsFixed(2)} (fits: ${fit.fits}), moved '
          'median ${moves[moves.length ~/ 2].toStringAsFixed(2)} s, largest '
          '${moves.last.toStringAsFixed(1)} s; ${fit.elapsedMs} ms for '
          '${fit.audioSeconds.toStringAsFixed(0)} s; progress $events of '
          '$lastTotal chunks',
        );
      } on FitError catch (e) {
        print('#$index ${source.key}: $e');
      }
      sampler.cancel();
      // Give the ended isolate's memory a moment to go back.
      await Future<void>.delayed(const Duration(seconds: 2));
      print('  memory: before $before MB, peak $peak MB, after ${rssMb()} MB');
    }
  }
}
