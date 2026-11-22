// The aligner model's letter probabilities for a whole song (plan 10 G1).
//
// MMS_FA (int8 ONNX, made by experiments/f2-timing/onnx_probe.py) takes
// 16 kHz mono samples and gives log probabilities for every 20 ms frame.
// Its attention cannot take a whole song at once, so the song goes in
// chunks of 20 s, each with 1 s of context on both sides that is cut away
// again, exactly as timing_probe.py's Aligner.emission did.
import 'dart:typed_data';

import 'ctc_align.dart';
import 'onnx_runtime.dart';

/// The sample rate the model expects.
const modelSampleRate = 16000;

/// Python's round(): halves go to the even neighbour, so chunk edges land
/// on the same frames as in the research.
int roundHalfEven(double x) {
  final floor = x.floorToDouble();
  final diff = x - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  return floor.toInt().isEven ? floor.toInt() : floor.toInt() + 1;
}

/// Runs the aligner model over [samples] (16 kHz mono) in chunks.
///
/// [runChunk] turns one chunk's samples into its frames' log
/// probabilities (frames x columns, row after row); [onChunk] is told how
/// many of [chunks] are done, for a progress line.
Emission emissionInChunks(
  Float32List samples,
  ({Float32List values, int columns}) Function(Float32List chunk) runChunk, {
  int chunkSeconds = 20,
  int contextSeconds = 1,
  void Function(int done, int chunks)? onChunk,
}) {
  final chunk = chunkSeconds * modelSampleRate;
  final context = contextSeconds * modelSampleRate;
  final n = samples.length;
  final chunks = (n + chunk - 1) ~/ chunk;
  final parts = <Float32List>[];
  var columns = 0;
  var done = 0;
  for (var start = 0; start < n; start += chunk) {
    final a = start - context < 0 ? 0 : start - context;
    final b = start + chunk + context > n ? n : start + chunk + context;
    final out = runChunk(Float32List.sublistView(samples, a, b));
    columns = out.columns;
    final frames = out.values.length ~/ columns;
    final perFrame = (b - a) / frames;
    final lead = roundHalfEven((start - a) / perFrame);
    final end = start + chunk > n ? n : start + chunk;
    final body = roundHalfEven((end - start) / perFrame);
    final from = lead.clamp(0, frames);
    final to = (lead + body).clamp(from, frames);
    parts.add(
      Float32List.sublistView(out.values, from * columns, to * columns),
    );
    onChunk?.call(++done, chunks);
  }
  final total = parts.fold(0, (sum, p) => sum + p.length);
  final values = Float32List(total);
  var at = 0;
  for (final part in parts) {
    values.setAll(at, part);
    at += part.length;
  }
  return Emission(values, columns);
}

/// [emissionInChunks] with an opened MMS_FA ONNX session (input "wave"
/// [1, samples], output "emission" [1, frames, 28]).
Emission modelEmission(
  OnnxSession session,
  Float32List samples, {
  void Function(int done, int chunks)? onChunk,
}) {
  return emissionInChunks(samples, (chunk) {
    final out = session.run('wave', chunk, [1, chunk.length], 'emission');
    return (values: out.values, columns: out.shape.last);
  }, onChunk: onChunk);
}
