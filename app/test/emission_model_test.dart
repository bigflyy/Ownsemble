import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/emission_model.dart';

/// A stand-in model: one frame per 320 samples (as MMS_FA), two columns,
/// each frame holding the absolute sample index where it starts, so the
/// test can see which audio every kept frame came from.
({Float32List values, int columns}) Function(Float32List) fakeModel(
  Float32List whole,
) {
  return (chunk) {
    final offset = chunk.offsetInBytes ~/ 4;
    final frames = chunk.length ~/ 320;
    final values = Float32List(frames * 2);
    for (var f = 0; f < frames; f++) {
      values[f * 2] = (offset + f * 320).toDouble();
      values[f * 2 + 1] = whole[offset + f * 320];
    }
    return (values: values, columns: 2);
  };
}

void main() {
  test('roundHalfEven rounds like Python', () {
    expect([0.5, 1.5, 2.5, 2.4, 2.6, -0.5].map(roundHalfEven), [
      0, 2, 2, 2, 3, 0, //
    ]);
  });

  test('chunks keep every frame once, in order, without the context', () {
    // 50 s of audio: chunks of 20 s with 1 s of context either side.
    final samples = Float32List(50 * modelSampleRate);
    final chunks = <int>[];
    final emission = emissionInChunks(
      samples,
      fakeModel(samples),
      onChunk: (done, total) => chunks.add(total),
    );
    expect(chunks, [3, 3, 3]);
    expect(emission.frames, 50 * modelSampleRate ~/ 320);
    for (var f = 0; f < emission.frames; f++) {
      expect(emission.values[f * 2], f * 320.0, reason: 'frame $f');
    }
  });
}
