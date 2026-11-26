/// Timed lines fitted to a recording (plan 10 G2), as they are kept and
/// shown.
///
/// A fit gives new starts for the sung lines only (recording_fit.dart).
/// Here every line, gaps too, gets a start, never out of order, and the
/// result is kept per upload and source together with a hash of the lyrics
/// it was made for: when the source's lyrics change, the fit is not used.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'line_fit.dart' show isUnsungLine;
import 'lyrics.dart';
import 'recording_fit.dart';

/// A kept fit of one source's lyrics to one upload's recording.
class StoredFit {
  const StoredFit({
    required this.lyricsHash,
    required this.audioBytes,
    required this.starts,
    required this.sureShare,
    required this.fittedAtMs,
    this.words,
  });

  /// [lyricsHashOf] of the lyrics that were fitted.
  final String lyricsHash;

  /// The size of the recording's file that was fitted: VK can swap an
  /// upload's audio, and a fit of the old recording is wrong for the new.
  final int audioBytes;

  /// The new start of every line, by index; null when the lyrics did not
  /// fit the recording (fewer than half the lines were sure), so nothing
  /// moves.
  final List<int>? starts;

  /// The share of placed lines that were sure.
  final double sureShare;
  final int fittedAtMs;

  /// Where each word of every line is sung, by line index as [starts]
  /// (plan 10 J4): null for a line the aligner was not sure of; null as a
  /// whole for a fit kept before word times were, or one that did not fit.
  final List<List<WordTime?>?>? words;

  /// Whether the fit gave word times to at least one line.
  bool get hasWords => words?.any((line) => line != null) ?? false;

  /// [words] as stored: a list by line of null or `[[start, end] or null
  /// per word]`; null when there are none.
  String? wordsToJson() => !hasWords
      ? null
      : jsonEncode([
          for (final line in words!)
            line == null
                ? null
                : [
                    for (final word in line)
                      word == null ? null : [word.startMs, word.endMs],
                  ],
        ]);

  /// Reads words written by [wordsToJson].
  static List<List<WordTime?>?>? wordsFromJson(String? json) {
    if (json == null) return null;
    return [
      for (final line in jsonDecode(json) as List)
        line is List
            ? [
                for (final word in line)
                  if (word case [final num start, final num end])
                    WordTime(start.round(), end.round())
                  else
                    null,
              ]
            : null,
    ];
  }

  /// Whether the lyrics fit the recording and their lines were moved.
  bool get fits => starts != null;

  /// Whether this fit was made for [lyrics] as they are now and, when
  /// [audioBytes] of the stored recording are known, for that recording.
  bool isFor(Lyrics lyrics, {int? audioBytes}) =>
      lyricsHash == lyricsHashOf(lyrics) &&
      (audioBytes == null || audioBytes == this.audioBytes) &&
      (starts == null || starts!.length == lyrics.lines.length);

  String? startsToJson() => starts == null ? null : jsonEncode(starts);

  static List<int>? startsFromJson(String? json) => json == null
      ? null
      : [for (final start in jsonDecode(json) as List) (start as num).toInt()];
}

/// A short, stable fingerprint of [lyrics]' words and line times (word
/// times left out: lyrics that gain them are still the lyrics fitted).
String lyricsHashOf(Lyrics lyrics) => sha256
    .convert(utf8.encode(lyrics.linesToJson(words: false)))
    .toString()
    .substring(0, 16);

/// Every line's start after [fit]: a fitted line takes its new start. Any
/// other line (a gap, or a line without letters the aligner knows) keeps
/// its place between the fitted lines around it: its time is stretched
/// from the source's span between them onto the fitted span, so a gap
/// stays between its lines. Before the first or after the last fitted line
/// it moves as far as that line moved. Starts never go back and stay
/// within the recording's [lengthMs].
List<int> fittedLineStarts(
  List<LyricLine> lines,
  Map<int, FitLine> fit, {
  int? lengthMs,
}) {
  // The fitted lines that had a start, in order: the anchors.
  final anchors = [
    for (var i = 0; i < lines.length; i++)
      if (fit[i] != null && lines[i].startMs != null) i,
  ];
  final starts = List<int>.filled(lines.length, 0);
  var before = -1; // index into anchors of the last anchor at or before i
  for (var i = 0; i < lines.length; i++) {
    while (before + 1 < anchors.length && anchors[before + 1] <= i) {
      before++;
    }
    final fitted = fit[i];
    if (fitted != null) {
      starts[i] = fitted.startMs;
      continue;
    }
    final old = lines[i].startMs ?? (i == 0 ? 0 : lines[i - 1].startMs ?? 0);
    final after = before + 1 < anchors.length ? anchors[before + 1] : null;
    final prev = before >= 0 ? anchors[before] : null;
    if (prev != null && after != null) {
      final a0 = lines[prev].startMs!, a1 = lines[after].startMs!;
      final b0 = fit[prev]!.startMs, b1 = fit[after]!.startMs;
      starts[i] = a1 > a0
          ? b0 + ((old - a0) * (b1 - b0) / (a1 - a0)).round()
          : b0;
    } else if (prev != null) {
      starts[i] = old + fit[prev]!.startMs - lines[prev].startMs!;
    } else if (after != null) {
      starts[i] = old + fit[after]!.startMs - lines[after].startMs!;
    } else {
      starts[i] = old;
    }
  }
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] < 0) starts[i] = 0;
    if (lengthMs != null && starts[i] > lengthMs) starts[i] = lengthMs;
    if (i > 0 && starts[i] < starts[i - 1]) starts[i] = starts[i - 1];
  }
  return starts;
}

/// Every line's start after a fit of plain words ([RecordingFit.plain]):
/// a placed line takes its fitted start; a blank line starts where the
/// placed line before it ends (0 before the first), so it lights during
/// the pause; any other line not placed (a section header, a repeat mark,
/// a line the aligner cannot read) starts with the next placed line, and
/// at the end where the last one ends. Starts never go back and stay
/// within the recording's [lengthMs].
List<int> plainLineStarts(
  List<LyricLine> lines,
  Map<int, FitLine> fit, {
  int? lengthMs,
}) {
  // First the placed lines and the blank lines; then every other line
  // takes the start of the next line that has one, a blank line too, so a
  // header just before a pause does not swallow it (Codex review of H2).
  final known = List<int?>.filled(lines.length, null);
  int? endBefore;
  for (var i = 0; i < lines.length; i++) {
    final placed = fit[i];
    if (placed != null) {
      known[i] = placed.startMs;
      endBefore = placed.endMs ?? placed.startMs;
    } else if (lines[i].isGap) {
      known[i] = endBefore ?? 0;
    }
  }
  final starts = List<int>.filled(lines.length, 0);
  int? next;
  int? lastEnd;
  for (final placed in fit.values) {
    final end = placed.endMs ?? placed.startMs;
    if (lastEnd == null || end > lastEnd) lastEnd = end;
  }
  for (var i = lines.length - 1; i >= 0; i--) {
    starts[i] = known[i] ?? next ?? lastEnd ?? 0;
    if (known[i] != null) next = known[i];
  }
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] < 0) starts[i] = 0;
    if (lengthMs != null && starts[i] > lengthMs) starts[i] = lengthMs;
    if (i > 0 && starts[i] < starts[i - 1]) starts[i] = starts[i - 1];
  }
  return starts;
}

/// [lyrics] with their lines at [starts]; each line's end and word times
/// move as far as its start did. With [labelUnsung] (plain words timed by a fit, H5) the
/// rows that are not sung ([isUnsungLine]: headers, repeat marks) become
/// label rows, never lit; lyrics timed by their source keep every row a
/// line, as before.
///
/// [words] (a fit's, by line index) replace a line's own word times where
/// the fit has them: they are where this recording sings the words. Where
/// the fit has none, a line keeps its own (moved with its start) only with
/// [ownWords]: another version's word times are another recording's pace.
Lyrics withStarts(
  Lyrics lyrics,
  List<int> starts, {
  bool labelUnsung = false,
  List<List<WordTime?>?>? words,
  bool ownWords = true,
}) => Lyrics(
  source: lyrics.source,
  lines: [
    for (var i = 0; i < lyrics.lines.length; i++)
      _withWords(
        lyrics.lines[i].movedTo(
          starts[i],
          label: labelUnsung && isUnsungLine(lyrics.lines[i].text),
        ),
        words != null && i < words.length ? words[i] : null,
        keepOwn: ownWords,
      ),
  ],
);

LyricLine _withWords(
  LyricLine line,
  List<WordTime?>? words, {
  required bool keepOwn,
}) => words == null && keepOwn
    ? line
    : LyricLine(
        line.text,
        startMs: line.startMs,
        endMs: line.endMs,
        label: line.label,
        passed: line.passed,
        words: words,
      );

/// Whether two fits' [StoredFit.words] are the same.
bool sameFitWords(List<List<WordTime?>?>? a, List<List<WordTime?>?>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x == null || y == null) {
      if (x != y) return false;
      continue;
    }
    if (x.length != y.length) return false;
    for (var j = 0; j < x.length; j++) {
      if (x[j] != y[j]) return false;
    }
  }
  return true;
}
