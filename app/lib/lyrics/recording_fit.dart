// "Fit to this recording" (plan 10 G1/G2): timed lyric lines moved to
// where they are sung in one song file, in a background isolate.
//
// The steps: libmpv decodes the file to 16 kHz mono (audio_decode.dart),
// the MMS_FA int8 model gives letter probabilities through ONNX Runtime
// (emission_model.dart), forced alignment places the lines and the G0b
// formula says which placements to trust (line_fit.dart). A 3-4 minute
// song takes about 20-30 s of 4 CPU threads and up to 1.4 GB of memory,
// all freed when the isolate ends.
import 'dart:isolate';

import 'audio_decode.dart';
import 'ctc_align.dart';
import 'emission_model.dart';
import 'line_fit.dart';
import 'lyrics.dart';
import 'onnx_runtime.dart';

/// Where the native parts and the model are.
class FitTools {
  const FitTools({
    required this.onnxRuntimePath,
    required this.modelPath,
    required this.mpvPath,
    required this.tempDir,
    this.threads = 4,
  });

  final String onnxRuntimePath;
  final String modelPath;
  final String mpvPath;
  final String tempDir;
  final int threads;
}

/// A line's new start, as the fit found it.
class FitLine {
  const FitLine(this.startMs, {required this.sure});

  final int startMs;

  /// Whether the aligner's own placement was trusted; otherwise the start
  /// is the lyrics' moved by the shift of the sure lines around it.
  final bool sure;
}

/// What fitting gave for one song and one set of lyrics.
class RecordingFit {
  const RecordingFit({
    required this.lines,
    required this.sureShare,
    required this.audioSeconds,
    required this.elapsedMs,
  });

  /// By index into the lyrics' lines; lines without a start or words are
  /// missing.
  final Map<int, FitLine> lines;

  /// The share of placed lines that are sure.
  final double sureShare;
  final double audioSeconds;
  final int elapsedMs;

  /// Whether the lyrics seem to belong to this recording (G0b: when under
  /// half the lines are sure, most placements were wrong).
  bool get fits => sureShare >= 0.5;
}

/// Thrown when the lines cannot be fitted (no timed lines with letters the
/// aligner knows, or not enough audio for them).
class FitError implements Exception {
  const FitError(this.message);
  final String message;

  @override
  String toString() => 'FitError: $message';
}

/// Fits [lines] to the song at [audioPath], in a background isolate.
/// [onProgress] hears the model's chunks done out of all.
Future<RecordingFit> fitToRecording(
  String audioPath,
  List<LyricLine> lines,
  FitTools tools, {
  void Function(int done, int total)? onProgress,
}) async {
  final progress = ReceivePort();
  final listening = progress.listen((message) {
    if (message case [final int done, final int total]) {
      onProgress?.call(done, total);
    }
  });
  final plain = [
    for (final line in lines)
      (startMs: line.startMs, endMs: line.endMs, text: line.text),
  ];
  final port = progress.sendPort;
  try {
    return await Isolate.run(
      () => fitNow(
        audioPath,
        plain,
        tools,
        onChunk: (done, total) {
          port.send([done, total]);
        },
      ),
      debugName: 'lyrics fit',
    );
  } finally {
    await listening.cancel();
    progress.close();
  }
}

/// [fitToRecording]'s work, on the calling isolate (blocks it).
RecordingFit fitNow(
  String audioPath,
  List<({int? startMs, int? endMs, String text})> lines,
  FitTools tools, {
  void Function(int done, int total)? onChunk,
}) {
  final clock = Stopwatch()..start();
  final sung = sungLines(lines);
  var letters = 0;
  var kept = 0;
  for (final line in sung) {
    final r = romanize(line.text);
    letters += r.letters;
    kept += r.kept;
  }
  // The research skipped lyrics whose letters it mostly could not read.
  if (sung.length < 3 || letters == 0 || kept / letters < 0.8) {
    throw const FitError('these lyrics have too few lines or letters to fit');
  }
  final samples = decodeForModel(tools.mpvPath, audioPath, tools.tempDir);
  final seconds = samples.length / modelSampleRate;
  final session = OnnxRuntime.load(tools.onnxRuntimePath)
      .open(tools.modelPath, threads: tools.threads);
  final List<FittedLine> fitted;
  try {
    final emission = modelEmission(session, samples, onChunk: onChunk);
    try {
      fitted = fitLines(emission, sung, seconds / emission.frames);
    } on AlignmentTooLong {
      throw const FitError('the lyrics are longer than the recording allows');
    }
  } finally {
    session.close();
  }
  if (fitted.isEmpty) throw const FitError('no line could be placed');
  final starts = fittedStarts(fitted);
  var sure = 0;
  final result = <int, FitLine>{};
  for (var k = 0; k < fitted.length; k++) {
    final isSure = fitted[k].sure >= sureAt;
    if (isSure) sure++;
    result[sung[fitted[k].index].lineIndex] = FitLine(
      (starts[k] * 1000).round(),
      sure: isSure,
    );
  }
  return RecordingFit(
    lines: result,
    sureShare: sure / fitted.length,
    audioSeconds: seconds,
    elapsedMs: clock.elapsedMilliseconds,
  );
}
