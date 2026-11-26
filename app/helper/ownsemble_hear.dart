/// ownsemble_hear.exe: the helper process that runs "Hear the words" jobs
/// for the app (plan 10 I2i5; the conversation is in
/// lib/lyrics/hear_helper.dart).
///
/// Built with `dart compile exe` beside ownsemble.exe by
/// windows/hear_helper.cmake. It lives outside bin/ because `dart compile`
/// refuses a bin/ program of a package whose dependencies have build hooks
/// (sqlite3 has one), though this program never uses them.
///
/// Usage: `ownsemble_hear.exe --onnx ONNXRUNTIME_DLL [--gpu-onnx DLL]`.
/// It reads jobs on stdin and answers on stdout until stdin closes, then
/// ends at once (a job still running included).
library;

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/hear_helper.dart';
import 'package:ownsemble/platform/end_process.dart';

Future<void> main(List<String> args) async {
  String? onnx;
  String? gpuOnnx;
  for (var i = 0; i + 1 < args.length; i += 2) {
    switch (args[i]) {
      case '--onnx':
        onnx = args[i + 1];
      case '--gpu-onnx':
        gpuOnnx = args[i + 1];
    }
  }
  if (onnx == null) {
    stderr.writeln('usage: ownsemble_hear --onnx <dll> [--gpu-onnx <dll>]');
    exit(64);
  }
  await serveHearJobs(
    lines: stdin.transform(utf8.decoder).transform(const LineSplitter()),
    write: stdout.writeln,
    onnxRuntimePath: onnx,
    gpuOnnxRuntimePath: gpuOnnx,
  );
  // The app is done or gone. TerminateProcess, not exit(): a job stuck in
  // a native call (a GPU driver) cannot hold the helper open, and no
  // driver's shutdown code runs.
  await stdout.flush();
  endProcessNow();
  exit(0);
}
