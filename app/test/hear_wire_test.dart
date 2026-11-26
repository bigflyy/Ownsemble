// Every job and result of "Hear the words" survives the trip to the helper
// process and back as JSON text (plan 10 I2i5), Cyrillic and exact doubles
// included.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/gigaam.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/hear_wire.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:ownsemble/lyrics/whisper.dart';
import 'package:ownsemble/lyrics/whisper_job.dart';

/// Through JSON text, as the pipe carries it.
Object? _trip(Object? json) => jsonDecode(jsonEncode(json));

WorkerJob<Object?> _jobTrip(WorkerJob<Object?> job) =>
    jobFromJson(_trip(jobToJson(job)) as Map<String, Object?>);

Object? _resultTrip(String name, Object? result) =>
    resultFromJson(name, _trip(resultToJson(name, result)));

void _sameWords(List<HeardWord> got, List<HeardWord> want) {
  expect(got.length, want.length);
  for (var i = 0; i < want.length; i++) {
    expect(got[i].start, want[i].start);
    expect(got[i].end, want[i].end);
    expect(got[i].text, want[i].text);
    expect(got[i].confidence, want[i].confidence);
  }
}

void main() {
  test('a separate job comes back with every field', () {
    const job = VocalsJob(
      audioPath: r'C:\data\cache\песня.mp3',
      outPath: r'C:\data\vocals\a.vocals16.f32',
      modelPath: r'C:\models\Kim_Vocal_2.onnx',
      mpvPath: r'C:\app\libmpv-2.dll',
      tempDir: r'C:\data\hear\1',
      threads: 6,
      memoryArena: true,
      directMlDevice: -1,
      keepStereoAt: r'C:\x\keep',
    );
    final back = _jobTrip(job) as VocalsJob;
    expect(back.audioPath, job.audioPath);
    expect(back.outPath, job.outPath);
    expect(back.modelPath, job.modelPath);
    expect(back.mpvPath, job.mpvPath);
    expect(back.tempDir, job.tempDir);
    expect(back.threads, 6);
    expect(back.memoryArena, isTrue);
    expect(back.directMlDevice, -1);
    expect(back.keepStereoAt, job.keepStereoAt);
    expect(back.name, 'separate');
  });

  test('a GigaAM job comes back with every field, nulls kept', () {
    const job = GigaamJob(
      vocalsPath: r'C:\v.f32',
      modelFolder: r'C:\models\gigaam',
      sileroPath: r'C:\models\silero_vad_scan.onnx',
      threads: 4,
    );
    final back = _jobTrip(job) as GigaamJob;
    expect(back.vocalsPath, job.vocalsPath);
    expect(back.modelFolder, job.modelFolder);
    expect(back.sileroPath, job.sileroPath);
    expect(back.threads, 4);
    expect(back.memoryArena, isFalse);
    expect(back.directMlDevice, isNull);
    expect(back.keepForChecks, isFalse);
  });

  test('a Whisper job comes back with its ranges and an exact double', () {
    const job = WhisperJob(
      vocalsPath: r'C:\v.f32',
      bridgePath: r'C:\app\ownsemble_whisper.dll',
      libraryFolder: r'C:\models\whisper.cpp',
      modelPath: r'C:\models\ggml.bin',
      threads: 8,
      ranges: [(0, 16000), (32000, 99999)],
      speechSeconds: 0.1 + 0.2,
      language: 'ru',
      gpu: 1,
      gpuBackends: r'C:\models\gpu\vulkan',
    );
    final back = _jobTrip(job) as WhisperJob;
    expect(back.vocalsPath, job.vocalsPath);
    expect(back.bridgePath, job.bridgePath);
    expect(back.libraryFolder, job.libraryFolder);
    expect(back.modelPath, job.modelPath);
    expect(back.threads, 8);
    expect(back.sileroPath, isNull);
    expect(back.ranges, [(0, 16000), (32000, 99999)]);
    expect(back.speechSeconds, 0.1 + 0.2);
    expect(back.language, 'ru');
    expect(back.gpu, 1);
    expect(back.gpuBackends, job.gpuBackends);

    const detect = WhisperJob(
      vocalsPath: 'v',
      bridgePath: 'b',
      libraryFolder: 'l',
      modelPath: 'm',
      threads: 1,
      sileroPath: 's',
    );
    final again = _jobTrip(detect) as WhisperJob;
    expect(again.ranges, isNull);
    expect(again.sileroPath, 's');
    expect(again.language, isNull);
    expect(again.gpu, isNull);
  });

  test('a separate result comes back, a NaN scale too', () {
    const result = VocalsResult(
      samples: 3528000,
      chunks: 12,
      decodeMs: 310,
      separateMs: 12800,
      resampleMs: 95,
      scale: 0.987654321,
      modelMs: 4100,
      spectrumMs: 8000,
    );
    final back = _resultTrip('separate', result) as VocalsResult;
    expect(back.samples, result.samples);
    expect(back.chunks, 12);
    expect(back.decodeMs, 310);
    expect(back.separateMs, 12800);
    expect(back.resampleMs, 95);
    expect(back.scale, result.scale);
    expect(back.modelMs, 4100);
    expect(back.spectrumMs, 8000);

    const odd = VocalsResult(
      samples: 0,
      chunks: 0,
      decodeMs: 0,
      separateMs: 0,
      resampleMs: 0,
      scale: double.nan,
    );
    expect((_resultTrip('separate', odd) as VocalsResult).scale, isNaN);
  });

  test('a GigaAM result comes back word for word, check arrays too', () {
    const words = [
      HeardWord(1.04, 1.52, 'привет', 0.93125),
      HeardWord(1.6, 2.0000000000000004, ',', null),
    ];
    final result = GigaamJobResult(
      result: const GigaamResult(
        samples: 160000,
        speechSeconds: 8.25,
        chunks: [
          (
            range: (start: 0, end: 160000),
            frames: 250,
            tokens: [
              (token: 12, frame: 3, confidence: 0.5),
              (token: 7, frame: 9, confidence: null),
            ],
            words: words,
          ),
        ],
      ),
      loadMs: 10,
      vadMs: 20,
      openMs: 2100,
      encodeMs: 1900,
      decodeMs: 50,
      loudSeconds: 7.75,
      probabilities: Float32List.fromList([0.1, 0.9, double.infinity]),
      firstEncoded: null,
    );
    final back = _resultTrip('gigaam', result) as GigaamJobResult;
    expect(back.loadMs, 10);
    expect(back.vadMs, 20);
    expect(back.openMs, 2100);
    expect(back.encodeMs, 1900);
    expect(back.decodeMs, 50);
    expect(back.loudSeconds, 7.75);
    expect(back.probabilities, result.probabilities);
    expect(back.firstEncoded, isNull);
    expect(back.result.samples, 160000);
    expect(back.result.speechSeconds, 8.25);
    final chunk = back.result.chunks.single;
    expect(chunk.range, (start: 0, end: 160000));
    expect(chunk.frames, 250);
    expect(chunk.tokens, result.result.chunks.single.tokens);
    _sameWords(chunk.words, words);
    expect(back.result.meanConfidence, result.result.meanConfidence);
  });

  test('a Whisper result comes back with its token bytes', () {
    final word = HeardWord(3.5, 4.25, 'мир', 0.81);
    final result = WhisperJobResult(
      result: WhisperResult(
        samples: 96000,
        speechSeconds: 5.5,
        chunks: [
          (
            range: (start: 16000, end: 96000),
            language: 'ru',
            tokens: [
              (
                bytes: Uint8List.fromList(utf8.encode(' мир')),
                start: 3.5,
                end: 4.25,
                probability: 0.8100000000000001,
              ),
              (
                // Half a letter: whisper.cpp splits UTF-8 across tokens.
                bytes: Uint8List.fromList([0xD0]),
                start: 4.25,
                end: 4.3,
                probability: 0.2,
              ),
            ],
            words: [word],
          ),
        ],
      ),
      gpuName: 'NVIDIA GeForce RTX 4070 Laptop GPU',
      loadMs: 5,
      vadMs: 0,
      openMs: 900,
      transcribeMs: 4800,
      chunkMs: const [2400, 2400],
    );
    final back = _resultTrip('whisper', result) as WhisperJobResult;
    expect(back.gpuName, result.gpuName);
    expect(back.loadMs, 5);
    expect(back.vadMs, 0);
    expect(back.openMs, 900);
    expect(back.transcribeMs, 4800);
    expect(back.chunkMs, [2400, 2400]);
    expect(back.result.samples, 96000);
    expect(back.result.speechSeconds, 5.5);
    final chunk = back.result.chunks.single;
    expect(chunk.range, (start: 16000, end: 96000));
    expect(chunk.language, 'ru');
    final want = result.result.chunks.single.tokens;
    for (var i = 0; i < want.length; i++) {
      expect(chunk.tokens[i].bytes, want[i].bytes);
      expect(chunk.tokens[i].start, want[i].start);
      expect(chunk.tokens[i].end, want[i].end);
      expect(chunk.tokens[i].probability, want[i].probability);
    }
    _sameWords(chunk.words, [word]);
  });

  test('memory comes back; an unknown job is refused', () {
    const memory = (
      peakWorkingSet: 1300000000,
      peakPrivate: 2400000000,
      afterWorkingSet: 30000000,
      afterPrivate: 20000000,
    );
    expect(memoryFromJson(_trip(memoryToJson(memory))), memory);
    expect(
      () => jobFromJson({'job': 'format the disk'}),
      throwsA(isA<HearWireError>()),
    );
    expect(
      () => resultFromJson('nothing', <String, Object?>{}),
      throwsA(isA<HearWireError>()),
    );
  });
}
