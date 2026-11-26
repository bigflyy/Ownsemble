/// What "Hear the words" made of a song (plan 10 I2e): the heard words cut
/// into timed lines, or the word that no singing was found, kept as a local
/// "heard" version beside the lyrics the sources give.
///
/// The rules come from the research (plan 10 I1c, I1d):
/// - Lines: a new line before a word that starts with a capital and after
///   a word that ends a sentence (. ! ?), not at commas or pauses; a line
///   over 12 words is split at its widest pause, at least 2 words on each
///   side (line starts within 1 s of the lyrics' own: F1 0.75 GigaAM, 0.64
///   Whisper). Times are the models' own word times.
/// - "No singing found" only when the words are few (under 20; real songs
///   gave at least 39) AND the vocals are quiet: under 2 s of 100 ms windows
///   above -35 dBFS (the instrumental #45: 0.4 s, where GigaAM still wrote
///   one word at 0.99 confidence; the sung songs of Stage I: 90-170 s,
///   session 54). Few words over loud vocals, even a short sung passage of
///   a few seconds, are shown, marked rough.
/// - The 12-word limit counts words as [countHeardWords] does (the research
///   counted the folded parts: a hyphenated word is two); a line is split
///   only between model words, so one long unspaced word stays whole.
/// - Rough: mean word confidence under 0.93 for GigaAM and 0.92 for Whisper
///   (studio research songs: every Whisper song under 0.92 had a word error
///   rate of 0.34-0.63, GigaAM's only bad song sat at 0.92). I2h checks the
///   lines on held-out songs.
/// - Words are counted in the heard text itself (a Chinese or Japanese
///   character counts as a word), never after folding to a-z, which counts
///   such text as nothing.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'gigaam.dart' show HeardWord;
import 'lyrics.dart';

/// The source name of heard lyrics wherever lyrics carry one (a pick, an
/// offset). It is never one of the sources the app asks.
const heardSource = 'heard';

/// Fewer heard words than this may mean no singing (plan 10 I1c).
const noSingingWordFloor = 20;

/// A 100 ms window of the vocals louder than this (RMS, dB of full scale)
/// counts as sound.
const loudVocalsDb = -35.0;

/// Vocals with less sound than this, in seconds, are quiet.
const quietVocalsSeconds = 2.0;

/// Mean word confidence under these marks the heard words as rough.
const gigaamRoughBelow = 0.93;
const whisperRoughBelow = 0.92;

/// A heard line longer than this, in words, is split at its widest pause.
const heardLineMaxWords = 12;

/// A pause this long between two heard lines (or after the last one before
/// the song ends) gets a gap line, as VK marks instrumental parts, so the
/// line before it does not stay lit through the music.
const heardGapMs = 8000;

/// The seconds of [samples] (16 kHz mono) in 100 ms windows whose RMS is
/// above [loudVocalsDb]. A last partial window is left out.
double loudSeconds(Float32List samples, {int rate = 16000}) {
  final window = rate ~/ 10;
  if (window == 0) return 0;
  // RMS above the mark is the mean square above its square.
  final floor = math.pow(10, loudVocalsDb / 10).toDouble() * window;
  var loud = 0;
  for (var start = 0; start + window <= samples.length; start += window) {
    var sum = 0.0;
    for (var i = start; i < start + window; i++) {
      final value = samples[i];
      sum += value * value;
    }
    if (sum > floor) loud++;
  }
  return loud * window / rate;
}

/// A Han character or kana: written without spaces, so each counts as a
/// word.
final _unspaced = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]',
  unicode: true,
);

/// A run of letters or digits of any other script: one word.
final _spacedRun = RegExp(
  r'(?:(?![\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])[\p{L}\p{N}\p{M}])+',
  unicode: true,
);

/// How many words [words] hold, counted in their own text: every Han
/// character and kana, plus every run of other letters or digits (a word
/// of punctuation only counts as none).
int countHeardWords(Iterable<HeardWord> words) {
  var count = 0;
  for (final word in words) {
    count += _unspaced.allMatches(word.text).length;
    count += _spacedRun.allMatches(word.text).length;
  }
  return count;
}

/// Ends of a sentence after which a new line starts (with the full-width
/// marks Chinese and Japanese text uses).
const _sentenceEnds = {'.', '!', '?', '。', '！', '？'};

/// Opening marks passed over before the capital test (the research's
/// `lstrip("\"'(-")`).
const _openers = {'"', "'", '(', '-'};

/// Whether [text]'s first character after opening marks is a capital
/// letter: a letter that has a lower case and is not it.
bool _startsWithCapital(String text) {
  final runes = text.runes.toList();
  var at = 0;
  while (at < runes.length &&
      _openers.contains(String.fromCharCode(runes[at]))) {
    at++;
  }
  if (at == runes.length) return false;
  final first = String.fromCharCode(runes[at]);
  return first.toUpperCase() == first && first.toLowerCase() != first;
}

/// [words] (in time order) cut into timed lines as the research's best
/// rule ([heardLineMaxWords]); each line runs from its first word's start
/// to its last word's end, its words joined by spaces. A pause of
/// [heardGapMs] or more between lines gets a gap line, and so does the end
/// of the song when [songMs] is given and the singing stops that long
/// before it.
List<LyricLine> cutHeardLines(List<HeardWord> words, {int? songMs}) {
  // In time order; words starting together keep the models' order (the
  // research's Python sort is stable, Dart's is not promised to be).
  final indexed =
      [
        for (final (i, word) in words.indexed)
          if (word.text.trim().isNotEmpty) (i, word),
      ]..sort((a, b) {
        final byStart = a.$2.start.compareTo(b.$2.start);
        return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
      });
  final spoken = [for (final (_, word) in indexed) word];
  if (spoken.isEmpty) return const [];
  final pieces = <List<HeardWord>>[];
  var current = <HeardWord>[spoken.first];
  for (var i = 1; i < spoken.length; i++) {
    final before = spoken[i - 1].text.trim();
    final word = spoken[i].text.trim();
    final ends = _sentenceEnds.contains(String.fromCharCode(before.runes.last));
    if (ends || _startsWithCapital(word)) {
      pieces.add(current);
      current = [];
    }
    current.add(spoken[i]);
  }
  pieces.add(current);

  // Long lines split at the widest pause, at least 2 words on each side.
  final lines = <List<HeardWord>>[];
  final waiting = [...pieces];
  while (waiting.isNotEmpty) {
    final line = waiting.removeAt(0);
    // Counted in words, as the research's folded parts; split only between
    // model words with 2 on each side.
    if (countHeardWords(line) <= heardLineMaxWords || line.length < 4) {
      lines.add(line);
      continue;
    }
    var at = 2;
    var widest = double.negativeInfinity;
    for (var i = 2; i < line.length - 1; i++) {
      final gap = line[i].start - line[i - 1].end;
      // Python's max over (gap, i): an equal gap later wins.
      if (gap >= widest) {
        widest = gap;
        at = i;
      }
    }
    waiting.insertAll(0, [line.sublist(0, at), line.sublist(at)]);
  }

  final out = <LyricLine>[];
  for (final (index, line) in lines.indexed) {
    final startMs = _ms(line.first.start);
    final endMs = math.max(startMs, _ms(line.last.end));
    if (index > 0) {
      final previousEnd = out.last.endMs!;
      if (startMs - previousEnd >= heardGapMs) {
        out.add(LyricLine('', startMs: previousEnd, endMs: startMs));
      }
    }
    out.add(
      LyricLine(
        line.map((word) => word.text.trim()).join(' '),
        startMs: startMs,
        endMs: endMs,
      ),
    );
  }
  final lastEnd = out.last.endMs!;
  if (songMs != null && songMs - lastEnd >= heardGapMs) {
    out.add(LyricLine('', startMs: lastEnd, endMs: songMs));
  }
  return out;
}

int _ms(double seconds) => (seconds * 1000).round();

/// What hearing a song gave.
enum HeardOutcome {
  /// Words, shown as lyrics.
  words,

  /// Few words and quiet vocals: an instrumental.
  noSinging,

  /// The vocals have sound but no word could be made out of them.
  noWords,
}

/// Which model's words a heard version holds.
enum HeardModel { gigaam, whisper }

/// One song's heard version, as kept in the library.
class HeardLyrics {
  HeardLyrics({
    required this.outcome,
    required this.lines,
    required this.words,
    required this.model,
    required this.language,
    required this.confidence,
    required this.russianConfidence,
    required this.rough,
    required this.wordCount,
    required this.loudSeconds,
    required this.heardAtMs,
    this.audioBytes,
    this.bundles = '',
    this.askedLanguage,
  });

  final HeardOutcome outcome;

  /// The lines shown (empty unless [outcome] is words).
  final List<LyricLine> lines;

  /// Every heard word with its times and confidence, for editing and checks.
  final List<HeardWord> words;

  /// Whose words these are; null when no model heard any.
  final HeardModel? model;

  /// The song's language: 'ru' for GigaAM, Whisper's language of most of
  /// the singing; null when nothing was heard.
  final String? language;

  /// The mean word confidence of [model]'s words (0 without words).
  final double confidence;

  /// GigaAM's mean confidence, the number the router read (>= 0.80: Russian).
  final double russianConfidence;

  /// Whether the words are marked as rough: low confidence, or few words.
  final bool rough;

  /// [countHeardWords] of [words].
  final int wordCount;

  /// [loudSeconds] of the vocals.
  final double loudSeconds;
  final int heardAtMs;

  /// The size of the file the words were heard from, when known.
  final int? audioBytes;

  /// The model bundles used, as "name-version" separated by spaces.
  final String bundles;

  /// The language the user asked for (plan 10 I2j): 'ru' (GigaAM) or a
  /// Whisper language code; null when the app chose by itself.
  final String? askedLanguage;

  /// The lines as lyrics to show, or null when there are no words.
  late final Lyrics? lyrics = outcome == HeardOutcome.words
      ? Lyrics(source: heardSource, lines: lines)
      : null;

  /// [words] as stored: `[{"t": text, "s": start ms, "e": end ms, "c":
  /// confidence}]`, "c" left out for punctuation.
  String wordsToJson() => jsonEncode([
    for (final word in words)
      {
        't': word.text,
        's': _ms(word.start),
        'e': _ms(word.end),
        if (word.confidence != null)
          'c': (word.confidence! * 1000).round() / 1000,
      },
  ]);

  /// Reads words written by [wordsToJson].
  static List<HeardWord> wordsFromJson(String? json) => json == null
      ? const []
      : [
          for (final word in jsonDecode(json) as List)
            if (word case {
              't': final String text,
              's': final int start,
              'e': final int end,
            })
              HeardWord(
                start / 1000,
                end / 1000,
                text,
                (word['c'] as num?)?.toDouble(),
              ),
        ];

  @override
  String toString() =>
      'HeardLyrics(${outcome.name}, ${model?.name}, $language, '
      '${lines.length} lines, $wordCount words, rough $rough)';
}

/// The rough mark of [model]'s words with [confidence] and [wordCount].
bool isRoughHeard(HeardModel model, double confidence, int wordCount) =>
    wordCount < noSingingWordFloor ||
    confidence <
        (model == HeardModel.gigaam ? gigaamRoughBelow : whisperRoughBelow);

/// The heard version of a song from the words [model] heard (empty when
/// no model heard any: no speech chunks), their mean [confidence], the
/// vocals' [loud] seconds and the song's length.
HeardLyrics judgeHeard({
  required HeardModel? model,
  required List<HeardWord> words,
  required double confidence,
  required double russianConfidence,
  required String? language,
  required double loud,
  required int songMs,
  required int heardAtMs,
  int? audioBytes,
  String bundles = '',
  String? askedLanguage,
}) {
  final count = countHeardWords(words);
  final quiet = loud < quietVocalsSeconds;
  final HeardOutcome outcome;
  if (count < noSingingWordFloor && quiet) {
    outcome = HeardOutcome.noSinging;
  } else if (count == 0 || model == null) {
    outcome = HeardOutcome.noWords;
  } else {
    outcome = HeardOutcome.words;
  }
  final shown = outcome == HeardOutcome.words;
  return HeardLyrics(
    outcome: outcome,
    lines: shown ? cutHeardLines(words, songMs: songMs) : const [],
    words: shown ? words : const [],
    model: shown ? model : null,
    language: shown ? language : null,
    confidence: shown ? confidence : 0,
    russianConfidence: russianConfidence,
    rough: shown && isRoughHeard(model!, confidence, count),
    wordCount: count,
    loudSeconds: loud,
    heardAtMs: heardAtMs,
    audioBytes: audioBytes,
    bundles: bundles,
    askedLanguage: askedLanguage,
  );
}
