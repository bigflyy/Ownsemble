/// The second stage of "Hear the words" (plan 10 I2c): GigaAM on the
/// worker, over the 16 kHz vocals [VocalsJob] wrote.
///
/// Units: Silero over the whole song (one thread, as gigaam_app: tiny
/// sequential steps), its model closed; then one unit per chunk, the
/// encoder and the decoder. Only one model is open at a time.
library;

import 'dart:io';
import 'dart:typed_data';

import 'gigaam.dart';
import 'onnx_runtime.dart';
import 'speech_chunks.dart';
import 'stt_worker.dart';

/// What [GigaamJob] gives back.
class GigaamJobResult {
  const GigaamJobResult({
    required this.result,
    required this.loadMs,
    required this.vadMs,
    required this.openMs,
    required this.encodeMs,
    required this.decodeMs,
    this.probabilities,
    this.firstEncoded,
  });

  final GigaamResult result;

  /// Reading the vocals and the model's small files; Silero over the
  /// song; [openMs]; the encoder calls; the Dart decoder (and the rest).
  final int loadMs;
  final int vadMs;

  /// Opening the encoder (about 320 MB) before the first chunk.
  final int openMs;
  final int encodeMs;
  final int decodeMs;

  /// For checks only: Silero's probability of every window, and the
  /// encoder's frames of the first chunk.
  final Float32List? probabilities;
  final Float32List? firstEncoded;
}

/// Hears the vocals in [vocalsPath] (16 kHz mono float, little endian).
class GigaamJob extends WorkerJob<GigaamJobResult> {
  const GigaamJob({
    required this.vocalsPath,
    required this.modelFolder,
    required this.sileroPath,
    required this.threads,
    this.memoryArena = false,
    this.keepForChecks = false,
  });

  final String vocalsPath;

  /// The GigaAM folder (model.json, encoder.onnx, vocab.json, head.npz).
  final String modelFolder;

  /// silero_vad_scan.onnx.
  final String sileroPath;

  /// Threads inside each encoder operation.
  final int threads;
  final bool memoryArena;

  /// Keeps [GigaamJobResult.probabilities] and
  /// [GigaamJobResult.firstEncoded].
  final bool keepForChecks;

  @override
  String get name => 'gigaam';

  @override
  GigaamJobResult run(WorkerContext context) {
    final clock = Stopwatch()..start();
    final bytes = File(vocalsPath).readAsBytesSync();
    final audio = Float32List(bytes.length ~/ 4);
    audio.buffer.asUint8List().setAll(
      0,
      Uint8List.sublistView(bytes, 0, audio.length * 4),
    );
    final model = GigaamModel.load(modelFolder);
    final loadMs = clock.elapsedMilliseconds;
    context.checkCancelled();

    final silero = context.model(sileroPath, threads: 1);
    final probabilities = keepForChecks
        ? Float32List(
            audio.isEmpty
                ? 1
                : (audio.length + sileroWindow - 1) ~/ sileroWindow,
          )
        : null;
    var vadMs = 0;
    var openMs = 0;
    var encodeMs = 0;
    OnnxSession? encoder;
    Float32List? firstEncoded;
    final result = hearRussian(
      audio,
      model,
      scan: (state, windows, count) {
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
      },
      onProbabilities: probabilities == null
          ? null
          : (first, values) => probabilities.setAll(first, values),
      onVadDone: () {
        context.freeModel();
        vadMs = clock.elapsedMilliseconds - loadMs;
        context.unitDone('speech', 1, 1);
      },
      encode: (samples) {
        final opening = clock.elapsedMilliseconds;
        final session = encoder ??= context.model(
          model.encoderPath,
          threads: threads,
          memoryArena: memoryArena,
        );
        final started = clock.elapsedMilliseconds;
        openMs += started - opening;
        final [encoded, lengths] = session.runTensors(
          {
            'wav': OnnxTensor.float(samples, [1, samples.length]),
            'wav_len': OnnxTensor.int64(
              Int64List.fromList([samples.length]),
              const [1],
            ),
          },
          const ['encoded', 'encoded_len'],
        );
        final shape = encoded.shape;
        final dim = model.head.encoderDim;
        final frames = lengths.ints[0];
        if (shape.length != 3 ||
            shape[0] != 1 ||
            shape[2] != dim ||
            frames > shape[1]) {
          throw OnnxError('encoder gave shape $shape, length $frames');
        }
        encodeMs += clock.elapsedMilliseconds - started;
        final frameValues = Float32List.sublistView(
          encoded.floats,
          0,
          frames * dim,
        );
        if (keepForChecks) firstEncoded ??= frameValues;
        return frameValues;
      },
      onChunk: (done, total) => context.unitDone('hear', done, total),
    );
    context.freeModel();
    return GigaamJobResult(
      result: result,
      loadMs: loadMs,
      vadMs: vadMs,
      openMs: openMs,
      encodeMs: encodeMs,
      decodeMs: clock.elapsedMilliseconds - loadMs - vadMs - openMs - encodeMs,
      probabilities: probabilities,
      firstEncoded: firstEncoded,
    );
  }
}
