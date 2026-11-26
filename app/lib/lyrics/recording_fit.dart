// "Fit to this recording" (plan 10 G1/G2): timed lyric lines moved to
// where they are sung in one song file, in a background isolate.
//
// The steps: libmpv decodes the file to 16 kHz mono (audio_decode.dart),
// the MMS_FA int8 model gives letter probabilities through ONNX Runtime
// (emission_model.dart), forced alignment places the lines and the G0b
// formula says which placements to trust (line_fit.dart). A 3-4 minute
// song takes about 20-30 s of 4 CPU threads and up to 1.4 GB of memory,
// all freed when the isolate ends.
//
// The model's output for a recording can be kept in a small cache file
// (about 1.3 MB for 4 minutes): fitting other lyrics to the same recording
// then takes well under a second and needs neither the decoder nor the
// model.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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
  const FitLine(this.startMs, {required this.sure, this.endMs, this.words});

  final int startMs;

  /// Where the aligner placed the line's last letter's end (plain words
  /// only: a blank line after it starts there).
  final int? endMs;

  /// Whether the aligner's own placement was trusted; otherwise the start
  /// is the lyrics' moved by the shift of the sure lines around it.
  final bool sure;

  /// Where each space-separated word of the line is sung, as the aligner
  /// placed it (plan 10 J4); null for a line that is not [sure] (its words
  /// were placed wrong) or whose words did not line up.
  final List<WordTime?>? words;
}

/// What fitting gave for one song and one set of lyrics.
class RecordingFit {
  const RecordingFit({
    required this.lines,
    required this.sureShare,
    required this.audioSeconds,
    required this.elapsedMs,
    this.plain = false,
    this.shuffleGain,
  });

  /// By index into the lyrics' lines; lines without a start or words are
  /// missing.
  final Map<int, FitLine> lines;

  /// The share of placed lines that are sure.
  final double sureShare;
  final double audioSeconds;
  final int elapsedMs;

  /// Whether plain words (no times of their own) were fitted (H2).
  final bool plain;

  /// Plain words only: how much better the words score in their own order
  /// than shuffled (line_fit.dart shuffleGain); null when that cannot be
  /// told (too few different lines).
  final double? shuffleGain;

  /// Plain words whose fit cannot be checked: too few different lines.
  bool get undecided => plain && shuffleGain == null;

  /// Whether the lyrics seem to belong to this recording (G0b: when under
  /// half the lines are sure, most placements were wrong). Plain words
  /// must also beat their own shuffled order (H1: the sure share alone
  /// lets words of another song through).
  bool get fits =>
      sureShare >= 0.5 &&
      (!plain || (shuffleGain != null && shuffleGain! >= plainGainAt));
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
/// With [emissionCachePath] the model's output is read from that file when
/// it was made for this audio file, and written there otherwise.
Future<RecordingFit> fitToRecording(
  String audioPath,
  List<LyricLine> lines,
  FitTools tools, {
  void Function(int done, int total)? onProgress,
  String? emissionCachePath,
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
  try {
    return await _fitInIsolate(
      audioPath,
      plain,
      tools,
      progress.sendPort,
      emissionCachePath,
    );
  } finally {
    await listening.cancel();
    progress.close();
  }
}

/// Starts the background isolate. A function of its own on purpose: a
/// closure shares its enclosing scope's captured variables, and in
/// [fitToRecording] those include [onProgress], which holds the app's
/// objects; an isolate cannot be sent those (real check fit-45a: an
/// ArgumentError, "object is unsendable"). Here the closure holds only
/// the fit's own data.
Future<RecordingFit> _fitInIsolate(
  String audioPath,
  List<({int? startMs, int? endMs, String text})> lines,
  FitTools tools,
  SendPort port,
  String? emissionCachePath,
) => Isolate.run(
  () => fitNow(
    audioPath,
    lines,
    tools,
    onChunk: (done, total) => port.send([done, total]),
    emissionCachePath: emissionCachePath,
  ),
  debugName: 'lyrics fit',
);

/// What a fit aligns of [lines]: for timed lyrics the sung lines
/// (line_fit.dart sungLines); for plain words (no line has a time, H2)
/// the words of each sung line by its place in [lines], without section
/// headers and repeat marks. Null when there is too little to fit: fewer
/// than 3 lines, under 80% of the letters readable by the aligner (the
/// research skipped those lyrics), or plain words with fewer than 3
/// different lines (their check cannot tell: line_fit.dart shuffleGain).
({bool plain, List<SungLine> sung, Map<int, String> plainTexts})? fitTextsOf(
  List<({int? startMs, int? endMs, String text})> lines,
) {
  final plain = lines.every((line) => line.startMs == null);
  final sung = plain ? const <SungLine>[] : sungLines(lines);
  // Plain words: every line that may be sung, readable or not, counts for
  // the readable share; only the readable ones are aligned (Codex review:
  // lines the aligner cannot read at all were left out of the share).
  final candidates = <int, String>{
    if (plain)
      for (var i = 0; i < lines.length; i++)
        if (lines[i].text.trim().isNotEmpty && !isUnsungLine(lines[i].text))
          i: sungText(lines[i].text),
  };
  final plainTexts = <int, String>{
    for (final MapEntry(:key, :value) in candidates.entries)
      if (romanize(value).words.isNotEmpty) key: value,
  };
  var letters = 0;
  var kept = 0;
  for (final text in plain ? candidates.values : sung.map((l) => l.text)) {
    final r = romanize(text);
    letters += r.letters;
    kept += r.kept;
  }
  final count = plain ? plainTexts.length : sung.length;
  if (count < 3 || letters == 0 || kept / letters < 0.8) return null;
  if (plain && plainTexts.values.toSet().length < 3) return null;
  return (plain: plain, sung: sung, plainTexts: plainTexts);
}

/// Whether [lines] can be fitted at all ([fitTextsOf]), so no model is
/// downloaded for lyrics the fit cannot read (Codex review of H2).
bool canFitLines(List<LyricLine> lines) =>
    fitTextsOf([
      for (final line in lines)
        (startMs: line.startMs, endMs: line.endMs, text: line.text),
    ]) !=
    null;

/// [fitToRecording]'s work, on the calling isolate (blocks it).
RecordingFit fitNow(
  String audioPath,
  List<({int? startMs, int? endMs, String text})> lines,
  FitTools tools, {
  void Function(int done, int total)? onChunk,
  String? emissionCachePath,
}) {
  final clock = Stopwatch()..start();
  final texts = fitTextsOf(lines);
  if (texts == null) {
    throw const FitError('these lyrics have too few lines or letters to fit');
  }
  final (:plain, :sung, :plainTexts) = texts;
  final audioBytes = File(audioPath).lengthSync();
  var cached = emissionCachePath == null
      ? null
      : readEmissionCache(emissionCachePath, audioBytes);
  if (cached == null) {
    final samples = decodeForModel(tools.mpvPath, audioPath, tools.tempDir);
    final session = OnnxRuntime.load(tools.onnxRuntimePath)
        .open(tools.modelPath, threads: tools.threads);
    try {
      cached = (
        emission: modelEmission(session, samples, onChunk: onChunk),
        seconds: samples.length / modelSampleRate,
      );
    } finally {
      session.close();
    }
    if (emissionCachePath != null) {
      writeEmissionCache(emissionCachePath, audioBytes, cached);
    }
  } else {
    onChunk?.call(1, 1);
  }
  final (:emission, :seconds) = cached;
  if (plain) {
    return _fitPlain(
      plainTexts,
      emission,
      seconds,
      clock,
      lineTexts: {for (final i in plainTexts.keys) i: lines[i].text},
    );
  }
  final List<FittedLine> fitted;
  try {
    fitted = fitLines(emission, sung, seconds / emission.frames);
  } on AlignmentTooLong {
    throw const FitError('the lyrics are longer than the recording allows');
  }
  if (fitted.isEmpty) throw const FitError('no line could be placed');
  final starts = fittedStarts(fitted);
  var sure = 0;
  final result = <int, FitLine>{};
  for (var k = 0; k < fitted.length; k++) {
    final isSure = fitted[k].sure >= sureAt;
    if (isSure) sure++;
    final line = sung[fitted[k].index];
    result[line.lineIndex] = FitLine(
      (starts[k] * 1000).round(),
      sure: isSure,
      words: isSure
          ? wordTimesOnText(line.text, line.text, fitted[k].wordSpans)
          : null,
    );
  }
  return RecordingFit(
    lines: result,
    sureShare: sure / fitted.length,
    audioSeconds: seconds,
    elapsedMs: clock.elapsedMilliseconds,
  );
}

/// [fitNow] for plain words: every line placed keeps the aligner's start
/// (H1: moving unsure lines by their neighbours gains nothing), and the
/// verdict needs the shuffled-order check too.
RecordingFit _fitPlain(
  Map<int, String> texts,
  Emission emission,
  double seconds,
  Stopwatch clock, {
  Map<int, String> lineTexts = const {},
}) {
  final indexes = texts.keys.toList();
  final words = texts.values.toList();
  final List<PlainFittedLine> fitted;
  final double? gain;
  try {
    fitted = fitPlainLines(emission, words, seconds / emission.frames);
    gain = shuffleGain(emission, words, fitted, seed: plainSeedOf(words));
  } on AlignmentTooLong {
    throw const FitError('the lyrics are longer than the recording allows');
  }
  if (fitted.isEmpty) throw const FitError('no line could be placed');
  var sure = 0;
  final result = <int, FitLine>{};
  for (final line in fitted) {
    final isSure = line.sure >= sureAt;
    if (isSure) sure++;
    final index = indexes[line.index];
    result[index] = FitLine(
      (line.start * 1000).round(),
      endMs: (line.end * 1000).round(),
      sure: isSure,
      words: isSure
          ? wordTimesOnText(
              lineTexts[index] ?? words[line.index],
              words[line.index],
              line.wordSpans,
            )
          : null,
    );
  }
  return RecordingFit(
    lines: result,
    sureShare: sure / fitted.length,
    audioSeconds: seconds,
    elapsedMs: clock.elapsedMilliseconds,
    plain: true,
    shuffleGain: gain,
  );
}

/// The cache file name for an upload's key: no path characters, and the
/// key itself (an account and song id) not spelled out on disk.
String fitCacheName(String key) =>
    sha256.convert(utf8.encode(key)).toString().substring(0, 24);

/// The first bytes of an emission cache file, and its layout's version.
const _cacheMagic = 0x4D45574F; // "OWEM"
const _cacheVersion = 1;
const _cacheHeaderBytes = 32;

/// The model's output kept in [path] for an audio file of [audioBytes]
/// bytes; null when the file is missing, unreadable or made for another
/// file.
({Emission emission, double seconds})? readEmissionCache(
  String path,
  int audioBytes,
) {
  try {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < _cacheHeaderBytes) return null;
    final head = ByteData.sublistView(bytes, 0, _cacheHeaderBytes);
    if (head.getUint32(0, Endian.little) != _cacheMagic ||
        head.getUint32(4, Endian.little) != _cacheVersion ||
        head.getInt64(8, Endian.little) != audioBytes) {
      return null;
    }
    final columns = head.getUint32(16, Endian.little);
    final frames = head.getUint32(20, Endian.little);
    final seconds = head.getFloat64(24, Endian.little);
    if (columns == 0 ||
        bytes.length != _cacheHeaderBytes + columns * frames * 4) {
      return null;
    }
    // Copied, so the floats start on a 4-byte boundary.
    final values = Float32List(columns * frames);
    values.buffer.asUint8List().setAll(
      0,
      Uint8List.sublistView(bytes, _cacheHeaderBytes),
    );
    return (emission: Emission(values, columns), seconds: seconds);
  } on FileSystemException {
    return null;
  }
}

/// Keeps [cached] in [path] for an audio file of [audioBytes] bytes. A
/// failure to write only loses the cache.
void writeEmissionCache(
  String path,
  int audioBytes,
  ({Emission emission, double seconds}) cached,
) {
  final (:emission, :seconds) = cached;
  final head = ByteData(_cacheHeaderBytes)
    ..setUint32(0, _cacheMagic, Endian.little)
    ..setUint32(4, _cacheVersion, Endian.little)
    ..setInt64(8, audioBytes, Endian.little)
    ..setUint32(16, emission.columns, Endian.little)
    ..setUint32(20, emission.frames, Endian.little)
    ..setFloat64(24, seconds, Endian.little);
  final file = File(path);
  final part = File('$path.part');
  try {
    file.parent.createSync(recursive: true);
    final out = part.openSync(mode: FileMode.write);
    try {
      out
        ..writeFromSync(head.buffer.asUint8List())
        ..writeFromSync(Uint8List.sublistView(emission.values))
        ..flushSync();
    } finally {
      out.closeSync();
    }
    part.renameSync(path);
  } on FileSystemException {
    // Only the cache is lost.
  }
}
