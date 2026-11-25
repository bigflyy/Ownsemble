/// Whisper on the worker (plan 10 I2d): the words of a song GigaAM is
/// unsure of, over the 16 kHz vocals [VocalsJob] wrote.
///
/// Units: the speech chunks (Silero, unless the GigaAM pass already found
/// them), its model closed; then one unit per chunk. Whisper's model (about
/// 600 MB) is opened only after every ONNX model is closed and is freed
/// when the job ends. A cancel stops whisper.cpp inside a chunk: its abort
/// callback reads the job's cancel flag.
library;

import 'dart:io';
import 'dart:typed_data';

import 'onnx_runtime.dart';
import 'speech_chunks.dart';
import 'stt_worker.dart';
import 'whisper.dart';
import 'whisper_cpp.dart';

/// What [WhisperJob] gives back.
class WhisperJobResult {
  const WhisperJobResult({
    required this.result,
    required this.loadMs,
    required this.vadMs,
    required this.openMs,
    required this.transcribeMs,
    required this.chunkMs,
    this.gpuName,
  });

  final WhisperResult result;

  /// The GPU the model ran on, null for the CPU (or no model opened).
  final String? gpuName;

  /// Reading the vocals; Silero over the song (0 when the chunks were
  /// given); loading whisper.cpp and the model; whisper.cpp's calls.
  final int loadMs;
  final int vadMs;
  final int openMs;
  final int transcribeMs;

  /// Each chunk's whisper.cpp call, in order.
  final List<int> chunkMs;
}

/// Hears the vocals in [vocalsPath] (16 kHz mono float, little endian).
class WhisperJob extends WorkerJob<WhisperJobResult> {
  const WhisperJob({
    required this.vocalsPath,
    required this.bridgePath,
    required this.libraryFolder,
    required this.modelPath,
    required this.threads,
    this.sileroPath,
    this.ranges,
    this.speechSeconds = 0,
    this.language,
    this.gpu,
    this.gpuBackends,
  }) : assert(sileroPath != null || ranges != null);

  final String vocalsPath;

  /// ownsemble_whisper.dll (beside the app).
  final String bridgePath;

  /// The bundle's whisper.cpp folder (whisper.dll, ggml*.dll).
  final String libraryFolder;

  /// The ggml model file (ggml-large-v3-turbo-q5_0.bin).
  final String modelPath;

  /// CPU threads for whisper.cpp.
  final int threads;

  /// The GPU to hear on (an index into WhisperLibrary.gpus), or null for
  /// the CPU or the one [gpuBackends] picks (plan 10 I2i).
  final int? gpu;

  /// The GPU bundle's folder with ggml-vulkan.dll: loaded as well, and the
  /// model opened on [gpu] or else on [pickWhisperGpu]'s choice; no GPU
  /// there is a [WhisperError] (the app then hears on the CPU).
  final String? gpuBackends;

  /// silero_vad_scan.onnx, when [ranges] are not given.
  final String? sileroPath;

  /// The speech chunks as [start, end] sample pairs (plain data, so the job
  /// can be sent to the worker), and the singing found with them.
  final List<(int, int)>? ranges;
  final double speechSeconds;

  /// A language code, or null to detect it in every chunk.
  final String? language;

  @override
  String get name => 'whisper';

  @override
  WhisperJobResult run(WorkerContext context) {
    final clock = Stopwatch()..start();
    final bytes = File(vocalsPath).readAsBytesSync();
    final audio = Float32List(bytes.length ~/ 4);
    audio.buffer.asUint8List().setAll(
      0,
      Uint8List.sublistView(bytes, 0, audio.length * 4),
    );
    final loadMs = clock.elapsedMilliseconds;
    context.checkCancelled();

    final SpeechChunks speech;
    final given = ranges;
    if (given != null) {
      speech = (
        ranges: [for (final (start, end) in given) (start: start, end: end)],
        speechSeconds: speechSeconds,
      );
    } else {
      final silero = context.model(sileroPath!, threads: 1);
      speech = findSpeechChunks(audio, (state, windows, count) {
        final [nextState, scores] = silero.runTensors(
          {
            'state': OnnxTensor.float(state, const [2, 1, 128]),
            'windows': OnnxTensor.float(windows, [
              count,
              1,
              sileroContext + sileroWindow,
            ]),
          },
          const ['state_out', 'probabilities'],
        );
        context.checkCancelled();
        return (state: nextState.floats, probabilities: scores.floats);
      });
    }
    context.freeModel();
    final vadMs = clock.elapsedMilliseconds - loadMs;
    context.unitDone('speech', 1, 1);

    if (speech.ranges.isEmpty) {
      // No singing: the model (about 600 MB) is not opened at all.
      return WhisperJobResult(
        result: WhisperResult(
          samples: audio.length,
          speechSeconds: speech.speechSeconds,
          chunks: const [],
        ),
        loadMs: loadMs,
        vadMs: vadMs,
        openMs: 0,
        transcribeMs: 0,
        chunkMs: const [],
      );
    }
    final opening = clock.elapsedMilliseconds;
    final library = WhisperLibrary.load(bridgePath, libraryFolder);
    var onGpu = gpu;
    final backends = gpuBackends;
    if (backends != null) {
      library.loadBackends(backends);
      onGpu ??= pickWhisperGpu(library.gpus);
      if (onGpu == null) throw const WhisperError('no GPU for whisper.cpp');
    }
    final gpuName = onGpu == null ? null : library.gpus[onGpu].name;
    final model = library.open(modelPath, gpu: onGpu);
    final openMs = clock.elapsedMilliseconds - opening;
    final chunkMs = <int>[];
    try {
      // A cancel during the open (a second or two) stops here.
      context.unitDone('open', 1, 1);
      final result = hearWithWhisper(
        audio,
        speech,
        transcribe: (samples) {
          final started = clock.elapsedMilliseconds;
          final List<WhisperToken> tokens;
          try {
            tokens = model.transcribe(
              samples,
              language: language,
              threads: threads,
              cancel: context.cancelFlag,
            );
          } on WhisperCancelled {
            throw const WorkerCancelled();
          }
          chunkMs.add(clock.elapsedMilliseconds - started);
          return (language: model.lastLanguage, tokens: tokens);
        },
        onChunk: (done, total) => context.unitDone('hear', done, total),
      );
      return WhisperJobResult(
        result: result,
        loadMs: loadMs,
        vadMs: vadMs,
        openMs: openMs,
        transcribeMs: chunkMs.fold(0, (sum, ms) => sum + ms),
        chunkMs: chunkMs,
        gpuName: gpuName,
      );
    } finally {
      model.close();
    }
  }
}

/// The GPU whisper.cpp should hear on among [gpus] (WhisperLibrary.gpus):
/// the first discrete one, else the first built-in one; null when there
/// is none (plan 10 I2i, the user's "Auto": the discrete GPU first).
int? pickWhisperGpu(List<({String name, bool integrated})> gpus) {
  for (final (index, gpu) in gpus.indexed) {
    if (!gpu.integrated) return index;
  }
  return gpus.isEmpty ? null : 0;
}
