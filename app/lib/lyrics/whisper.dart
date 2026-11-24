/// Whisper's side of "Hear the words" (plan 10 I2d): the words of songs
/// GigaAM is unsure of, from Whisper large-v3-turbo on whisper.cpp
/// ([WhisperModel]), ported from gigaam_app's whisper_model.py.
///
/// The vocals are cut into the same Silero chunks as for GigaAM (up to 25
/// s, inside Whisper's 30 s window). Each chunk is recognised on its own:
/// greedy, nothing carried over from the chunk before (gigaam_app measured
/// that whole-file decoding and beam search invent text and loops). Token
/// bytes are joined into words before they are read as UTF-8, because a
/// token may end in the middle of a character (common for Cyrillic and
/// CJK); token times are kept inside the chunk and in order, then moved by
/// the chunk's start; a word's confidence is its weakest letter token's
/// probability put on GigaAM's scale ([whisperConfidence]).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'gigaam.dart';
import 'speech_chunks.dart';
import 'whisper_cpp.dart';

/// Whisper's token probability -> the confidence scale of the GigaAM
/// models (gigaam_app's WHISPER_SCALE, its plan 03 B2b). Whisper's raw
/// probability also carries its doubt about case and punctuation, written
/// in the same token, so 0.5 counts as 0.80 and 0.7 as 0.97.
const whisperScale = <(double, double)>[
  (0.0, 0.0),
  (0.5, 0.80),
  (0.7, 0.97),
  (1.0, 1.0),
];

/// A Whisper token probability on the GigaAM confidence scale.
double whisperConfidence(double probability) {
  // Python's min(1.0, max(0.0, p)) also for NaN, which gives 0.0 there
  // (clamp would give 1.0): max keeps 0.0 unless p is greater.
  final atLeast = probability > 0.0 ? probability : 0.0;
  final value = atLeast < 1.0 ? atLeast : 1.0;
  for (var i = 0; i + 1 < whisperScale.length; i++) {
    final (low, lowValue) = whisperScale[i];
    final (high, highValue) = whisperScale[i + 1];
    if (value <= high) {
      return lowValue + (value - low) * (highValue - lowValue) / (high - low);
    }
  }
  return 1.0;
}

final _alphanumeric = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// True if token [bytes] hold a letter or digit. A part of a character
/// split between two tokens counts as a letter: that is how Cyrillic
/// letters are often cut (gigaam_app's _has_letters: bytes dropped by a
/// lenient decode mean such a part).
bool tokenHasLetters(Uint8List bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return true;
  }
  return _alphanumeric.hasMatch(text);
}

/// Python's bytes.decode('utf-8', 'replace'): Dart's decoder also drops a
/// byte order mark at the very start, Python keeps it as U+FEFF.
String pythonDecode(Uint8List bytes) {
  final bom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  final text = utf8.decode(bytes, allowMalformed: true);
  return bom ? '\uFEFF$text' : text;
}

/// Python's bytes.strip() is empty: only ASCII whitespace (or nothing).
bool _blankBytes(List<int> bytes) {
  for (final byte in bytes) {
    if (byte != 0x20 && (byte < 0x09 || byte > 0x0D)) return false;
  }
  return true;
}

/// The characters Python's str.strip() removes (str.isspace).
bool _pythonSpace(int rune) =>
    (rune >= 0x09 && rune <= 0x0D) ||
    (rune >= 0x1C && rune <= 0x20) ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000;

/// Python's str.strip(): Dart's trim() also removes U+FEFF and keeps
/// U+001C..U+001F.
String pythonStrip(String text) {
  final runes = text.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && _pythonSpace(runes[start])) {
    start++;
  }
  while (end > start && _pythonSpace(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes, start, end);
}

/// Joins Whisper's text tokens into words with times from the start of
/// the song (gigaam_app's words_from_tokens). A token that begins with a
/// space starts a new word; punctuation and word pieces without one stick
/// to the word before. A word runs from its first non-blank token's start
/// to its last one's end. Times are kept inside the chunk (0..[duration])
/// and in order: whisper.cpp's token times come from a heuristic and can
/// step back a little or run past the end. Times and confidences are
/// rounded to 3 digits as Python's round.
List<HeardWord> whisperWords(
  List<WhisperToken> tokens,
  double offsetSeconds, [
  double? duration,
]) {
  final words = <HeardWord>[];
  var data = BytesBuilder(copy: false);
  double? start;
  double? end;
  double? lowest;

  void flush() {
    final text = pythonStrip(pythonDecode(data.toBytes()));
    final first = start;
    if (text.isNotEmpty && first != null) {
      var from = first;
      var to = end! > first ? end! : first;
      if (duration != null) {
        if (duration < from) from = duration;
        if (duration < to) to = duration;
      }
      if (words.isNotEmpty) {
        final floor = words.last.start - offsetSeconds;
        if (floor > from) from = floor;
        if (from > to) to = from;
      }
      final weakest = lowest;
      words.add(
        HeardWord(
          pythonRound(offsetSeconds + from, 3),
          pythonRound(offsetSeconds + to, 3),
          text,
          weakest == null ? null : pythonRound(whisperConfidence(weakest), 3),
        ),
      );
    }
    data = BytesBuilder(copy: false);
    start = null;
    end = null;
    lowest = null;
  }

  for (final token in tokens) {
    final bytes = token.bytes;
    if (bytes.isNotEmpty && bytes[0] == 0x20 && !_blankBytes(data.toBytes())) {
      flush();
    }
    if (!_blankBytes(bytes)) {
      start ??= token.start > 0.0 ? token.start : 0.0;
      end = token.end > 0.0 ? token.end : 0.0;
    }
    if (tokenHasLetters(bytes)) {
      final current = lowest;
      lowest = current == null || token.probability < current
          ? token.probability
          : current;
    }
    data.add(bytes);
  }
  flush();
  return words;
}

/// One chunk Whisper recognised: its sample range, the language it heard,
/// its tokens and words.
typedef WhisperChunk = ({
  SampleRange range,
  String language,
  List<WhisperToken> tokens,
  List<HeardWord> words,
});

/// What Whisper heard in a song.
class WhisperResult {
  const WhisperResult({
    required this.samples,
    required this.speechSeconds,
    required this.chunks,
  });

  /// Length of the audio in 16 kHz samples.
  final int samples;

  /// Singing the speech gate found (padded regions).
  final double speechSeconds;
  final List<WhisperChunk> chunks;

  /// Every word in time order.
  List<HeardWord> get words => [for (final c in chunks) ...c.words];

  /// The mean confidence of the words with letters; 0 when there are none.
  double get meanConfidence {
    var sum = 0.0;
    var count = 0;
    for (final chunk in chunks) {
      for (final word in chunk.words) {
        final confidence = word.confidence;
        if (confidence == null) continue;
        sum += confidence;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }
}

/// Whisper on one chunk of 16 kHz samples: the language it heard and the
/// text tokens.
typedef WhisperTranscribe =
    ({String language, List<WhisperToken> tokens}) Function(
      Float32List samples,
    );

/// Hears [audio] (16 kHz mono vocals) chunk by chunk through [transcribe],
/// over the [speech] chunks Silero found (the same as for GigaAM, so the
/// pipeline finds them once). [onChunk] runs after each chunk (progress
/// and cancel).
WhisperResult hearWithWhisper(
  Float32List audio,
  SpeechChunks speech, {
  required WhisperTranscribe transcribe,
  void Function(int done, int total)? onChunk,
}) {
  final chunks = <WhisperChunk>[];
  for (final range in speech.ranges) {
    final heard = transcribe(
      Float32List.sublistView(audio, range.start, range.end),
    );
    chunks.add((
      range: range,
      language: heard.language,
      tokens: heard.tokens,
      words: whisperWords(
        heard.tokens,
        range.start / 16000,
        (range.end - range.start) / 16000,
      ),
    ));
    onChunk?.call(chunks.length, speech.ranges.length);
  }
  return WhisperResult(
    samples: audio.length,
    speechSeconds: speech.speechSeconds,
    chunks: chunks,
  );
}
