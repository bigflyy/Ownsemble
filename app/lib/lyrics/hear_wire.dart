/// The jobs of "Hear the words" and their results as JSON, for the helper
/// process (plan 10 I2i5): the app sends a job as one line of JSON to
/// ownsemble_hear.exe and reads its result back the same way.
///
/// Every value comes back exactly as it went: a double is written as the
/// shortest text that reads back to the same double (dart:convert does
/// that), the few that JSON cannot hold (NaN, the infinities) as strings,
/// and binary data (token bytes, float arrays for checks) as base64.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../karaoke/instrumental_job.dart';
import 'gigaam.dart';
import 'gigaam_job.dart';
import 'speech_chunks.dart';
import 'stt_worker.dart';
import 'vocals_job.dart';
import 'whisper.dart';
import 'whisper_cpp.dart';
import 'whisper_job.dart';

/// A message that does not have the shape this version writes.
class HearWireError implements Exception {
  const HearWireError(this.message);
  final String message;

  @override
  String toString() => 'HearWireError: $message';
}

// --- Plain values -------------------------------------------------------

/// A double as JSON: a number, or 'NaN' / 'Infinity' / '-Infinity'.
Object _double(double value) {
  if (value.isFinite) return value;
  if (value.isNaN) return 'NaN';
  return value > 0 ? 'Infinity' : '-Infinity';
}

double _toDouble(Object? value) => switch (value) {
  num() => value.toDouble(),
  'NaN' => double.nan,
  'Infinity' => double.infinity,
  '-Infinity' => double.negativeInfinity,
  _ => throw HearWireError('not a double: $value'),
};

Object? _doubleOrNull(double? value) => value == null ? null : _double(value);

double? _toDoubleOrNull(Object? value) =>
    value == null ? null : _toDouble(value);

String _bytes(Uint8List bytes) => base64.encode(bytes);

Uint8List _toBytes(Object? value) => base64.decode(value as String);

String? _floats(Float32List? floats) => floats == null
    ? null
    : base64.encode(
        floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes),
      );

Float32List? _toFloats(Object? value) {
  if (value == null) return null;
  final bytes = base64.decode(value as String);
  // A copy: the decoded bytes may not start on a 4-byte boundary.
  return Float32List.view(Uint8List.fromList(bytes).buffer);
}

List<Object?> _range(SampleRange range) => [range.start, range.end];

SampleRange _toRange(Object? value) {
  final [start as int, end as int] = value as List<Object?>;
  return (start: start, end: end);
}

Map<String, Object?> _word(HeardWord word) => {
  's': _double(word.start),
  'e': _double(word.end),
  't': word.text,
  'c': _doubleOrNull(word.confidence),
};

HeardWord _toWord(Object? value) {
  final map = value as Map<String, Object?>;
  return HeardWord(
    _toDouble(map['s']),
    _toDouble(map['e']),
    map['t'] as String,
    _toDoubleOrNull(map['c']),
  );
}

List<HeardWord> _toWords(Object? value) => [
  for (final word in value as List<Object?>) _toWord(word),
];

// --- Jobs ---------------------------------------------------------------

/// [job] as JSON; throws [HearWireError] for a job the helper cannot run.
Map<String, Object?> jobToJson(WorkerJob<Object?> job) => switch (job) {
  VocalsJob() => {
    'job': 'separate',
    'audioPath': job.audioPath,
    'outPath': job.outPath,
    'modelPath': job.modelPath,
    'mpvPath': job.mpvPath,
    'tempDir': job.tempDir,
    'threads': job.threads,
    'memoryArena': job.memoryArena,
    'directMlDevice': job.directMlDevice,
    'keepStereoAt': job.keepStereoAt,
  },
  InstrumentalJob() => {
    'job': 'instrumental',
    'audioPath': job.audioPath,
    'outPath': job.outPath,
    'modelPath': job.modelPath,
    'mpvPath': job.mpvPath,
    'tempDir': job.tempDir,
    'threads': job.threads,
    'memoryArena': job.memoryArena,
    'directMlDevice': job.directMlDevice,
  },
  GigaamJob() => {
    'job': 'gigaam',
    'vocalsPath': job.vocalsPath,
    'modelFolder': job.modelFolder,
    'sileroPath': job.sileroPath,
    'threads': job.threads,
    'memoryArena': job.memoryArena,
    'directMlDevice': job.directMlDevice,
    'keepForChecks': job.keepForChecks,
  },
  WhisperJob() => {
    'job': 'whisper',
    'vocalsPath': job.vocalsPath,
    'bridgePath': job.bridgePath,
    'libraryFolder': job.libraryFolder,
    'modelPath': job.modelPath,
    'threads': job.threads,
    'sileroPath': job.sileroPath,
    'ranges': job.ranges == null
        ? null
        : [
            for (final (start, end) in job.ranges!) [start, end],
          ],
    'speechSeconds': _double(job.speechSeconds),
    'language': job.language,
    'gpu': job.gpu,
    'gpuBackends': job.gpuBackends,
  },
  _ => throw HearWireError('no wire form for the job ${job.name}'),
};

/// The job [jobToJson] wrote.
WorkerJob<Object?> jobFromJson(Map<String, Object?> json) =>
    switch (json['job']) {
      'separate' => VocalsJob(
        audioPath: json['audioPath'] as String,
        outPath: json['outPath'] as String,
        modelPath: json['modelPath'] as String,
        mpvPath: json['mpvPath'] as String,
        tempDir: json['tempDir'] as String,
        threads: json['threads'] as int,
        memoryArena: json['memoryArena'] as bool,
        directMlDevice: json['directMlDevice'] as int?,
        keepStereoAt: json['keepStereoAt'] as String?,
      ),
      'instrumental' => InstrumentalJob(
        audioPath: json['audioPath'] as String,
        outPath: json['outPath'] as String,
        modelPath: json['modelPath'] as String,
        mpvPath: json['mpvPath'] as String,
        tempDir: json['tempDir'] as String,
        threads: json['threads'] as int,
        memoryArena: json['memoryArena'] as bool,
        directMlDevice: json['directMlDevice'] as int?,
      ),
      'gigaam' => GigaamJob(
        vocalsPath: json['vocalsPath'] as String,
        modelFolder: json['modelFolder'] as String,
        sileroPath: json['sileroPath'] as String,
        threads: json['threads'] as int,
        memoryArena: json['memoryArena'] as bool,
        directMlDevice: json['directMlDevice'] as int?,
        keepForChecks: json['keepForChecks'] as bool,
      ),
      'whisper' => WhisperJob(
        vocalsPath: json['vocalsPath'] as String,
        bridgePath: json['bridgePath'] as String,
        libraryFolder: json['libraryFolder'] as String,
        modelPath: json['modelPath'] as String,
        threads: json['threads'] as int,
        sileroPath: json['sileroPath'] as String?,
        ranges: json['ranges'] == null
            ? null
            : [
                for (final pair in json['ranges'] as List<Object?>)
                  ((pair as List<Object?>)[0] as int, pair[1] as int),
              ],
        speechSeconds: _toDouble(json['speechSeconds']),
        language: json['language'] as String?,
        gpu: json['gpu'] as int?,
        gpuBackends: json['gpuBackends'] as String?,
      ),
      final other => throw HearWireError('unknown job $other'),
    };

// --- Results ------------------------------------------------------------

/// The result of the job named [jobName] ('separate', 'instrumental',
/// 'gigaam', 'whisper')
/// as JSON.
Object? resultToJson(String jobName, Object? result) => switch (result) {
  VocalsResult() => {
    'samples': result.samples,
    'chunks': result.chunks,
    'decodeMs': result.decodeMs,
    'separateMs': result.separateMs,
    'resampleMs': result.resampleMs,
    'scale': _double(result.scale),
    'modelMs': result.modelMs,
    'spectrumMs': result.spectrumMs,
  },
  InstrumentalResult() => {
    'frames': result.frames,
    'chunks': result.chunks,
    'decodeMs': result.decodeMs,
    'separateMs': result.separateMs,
    'inputScale': _double(result.inputScale),
    'modelMs': result.modelMs,
    'spectrumMs': result.spectrumMs,
  },
  GigaamJobResult() => {
    'result': _gigaam(result.result),
    'loadMs': result.loadMs,
    'vadMs': result.vadMs,
    'openMs': result.openMs,
    'encodeMs': result.encodeMs,
    'decodeMs': result.decodeMs,
    'loudSeconds': _double(result.loudSeconds),
    'probabilities': _floats(result.probabilities),
    'firstEncoded': _floats(result.firstEncoded),
  },
  WhisperJobResult() => {
    'result': _whisper(result.result),
    'gpuName': result.gpuName,
    'loadMs': result.loadMs,
    'vadMs': result.vadMs,
    'openMs': result.openMs,
    'transcribeMs': result.transcribeMs,
    'chunkMs': result.chunkMs,
  },
  _ => throw HearWireError('no wire form for a result of $jobName'),
};

/// The result [resultToJson] wrote for the job named [jobName].
Object? resultFromJson(String jobName, Object? json) {
  final map = json as Map<String, Object?>;
  return switch (jobName) {
    'separate' => VocalsResult(
      samples: map['samples'] as int,
      chunks: map['chunks'] as int,
      decodeMs: map['decodeMs'] as int,
      separateMs: map['separateMs'] as int,
      resampleMs: map['resampleMs'] as int,
      scale: _toDouble(map['scale']),
      modelMs: map['modelMs'] as int,
      spectrumMs: map['spectrumMs'] as int,
    ),
    'instrumental' => InstrumentalResult(
      frames: map['frames'] as int,
      chunks: map['chunks'] as int,
      decodeMs: map['decodeMs'] as int,
      separateMs: map['separateMs'] as int,
      inputScale: _toDouble(map['inputScale']),
      modelMs: map['modelMs'] as int,
      spectrumMs: map['spectrumMs'] as int,
    ),
    'gigaam' => GigaamJobResult(
      result: _toGigaam(map['result']),
      loadMs: map['loadMs'] as int,
      vadMs: map['vadMs'] as int,
      openMs: map['openMs'] as int,
      encodeMs: map['encodeMs'] as int,
      decodeMs: map['decodeMs'] as int,
      loudSeconds: _toDouble(map['loudSeconds']),
      probabilities: _toFloats(map['probabilities']),
      firstEncoded: _toFloats(map['firstEncoded']),
    ),
    'whisper' => WhisperJobResult(
      result: _toWhisper(map['result']),
      gpuName: map['gpuName'] as String?,
      loadMs: map['loadMs'] as int,
      vadMs: map['vadMs'] as int,
      openMs: map['openMs'] as int,
      transcribeMs: map['transcribeMs'] as int,
      chunkMs: [for (final ms in map['chunkMs'] as List<Object?>) ms as int],
    ),
    _ => throw HearWireError('unknown job $jobName'),
  };
}

Map<String, Object?> _gigaam(GigaamResult result) => {
  'samples': result.samples,
  'speechSeconds': _double(result.speechSeconds),
  'chunks': [
    for (final chunk in result.chunks)
      {
        'range': _range(chunk.range),
        'frames': chunk.frames,
        'tokens': [
          for (final token in chunk.tokens)
            [token.token, token.frame, _doubleOrNull(token.confidence)],
        ],
        'words': [for (final word in chunk.words) _word(word)],
      },
  ],
};

GigaamResult _toGigaam(Object? value) {
  final map = value as Map<String, Object?>;
  return GigaamResult(
    samples: map['samples'] as int,
    speechSeconds: _toDouble(map['speechSeconds']),
    chunks: [
      for (final chunk in map['chunks'] as List<Object?>)
        _toGigaamChunk(chunk as Map<String, Object?>),
    ],
  );
}

HeardChunk _toGigaamChunk(Map<String, Object?> chunk) => (
  range: _toRange(chunk['range']),
  frames: chunk['frames'] as int,
  tokens: [
    for (final token in chunk['tokens'] as List<Object?>)
      _toGigaamToken(token as List<Object?>),
  ],
  words: _toWords(chunk['words']),
);

HeardToken _toGigaamToken(List<Object?> token) => (
  token: token[0] as int,
  frame: token[1] as int,
  confidence: _toDoubleOrNull(token[2]),
);

Map<String, Object?> _whisper(WhisperResult result) => {
  'samples': result.samples,
  'speechSeconds': _double(result.speechSeconds),
  'chunks': [
    for (final chunk in result.chunks)
      {
        'range': _range(chunk.range),
        'language': chunk.language,
        'tokens': [
          for (final token in chunk.tokens)
            [
              _bytes(token.bytes),
              _double(token.start),
              _double(token.end),
              _double(token.probability),
            ],
        ],
        'words': [for (final word in chunk.words) _word(word)],
      },
  ],
};

WhisperResult _toWhisper(Object? value) {
  final map = value as Map<String, Object?>;
  return WhisperResult(
    samples: map['samples'] as int,
    speechSeconds: _toDouble(map['speechSeconds']),
    chunks: [
      for (final chunk in map['chunks'] as List<Object?>)
        _toWhisperChunk(chunk as Map<String, Object?>),
    ],
  );
}

WhisperChunk _toWhisperChunk(Map<String, Object?> chunk) => (
  range: _toRange(chunk['range']),
  language: chunk['language'] as String,
  tokens: [
    for (final token in chunk['tokens'] as List<Object?>)
      _toWhisperToken(token as List<Object?>),
  ],
  words: _toWords(chunk['words']),
);

WhisperToken _toWhisperToken(List<Object?> token) => (
  bytes: _toBytes(token[0]),
  start: _toDouble(token[1]),
  end: _toDouble(token[2]),
  probability: _toDouble(token[3]),
);

// --- Memory -------------------------------------------------------------

/// [memory] as JSON.
List<int> memoryToJson(WorkerMemory memory) => [
  memory.peakWorkingSet,
  memory.peakPrivate,
  memory.afterWorkingSet,
  memory.afterPrivate,
];

/// The memory [memoryToJson] wrote.
WorkerMemory memoryFromJson(Object? json) {
  final [
    peakWorking as int,
    peakPrivate as int,
    after as int,
    afterPrivate as int,
  ] = json as List<Object?>;
  return (
    peakWorkingSet: peakWorking,
    peakPrivate: peakPrivate,
    afterWorkingSet: after,
    afterPrivate: afterPrivate,
  );
}
