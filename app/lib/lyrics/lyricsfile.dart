/// LRCLIB's word-timed lyrics (plan 10 J3b): rows with `hasWordSync: true`
/// carry a `lyricsfile` field, YAML text with every line's start and end and
/// every word's start (seen 2026-11-26 on a real reply; `syncedLyrics` of the
/// same row has line times only, and its words may be spelled differently):
///
/// ```yaml
/// version: '1.0'
/// metadata: {title: ..., duration_ms: 246000, ...}
/// lines:
/// - text: Feeling my way through the darkness
///   start_ms: 9000
///   end_ms: 10857
///   words:
///   - text: 'Feeling '
///     start_ms: 9000
///   - text: darkness
///     start_ms: 10439
/// ```
///
/// A word's text keeps its trailing space; two pieces without a space
/// between them are parts of one word on screen. A word ends where the next
/// piece starts, the last one where its line ends.
library;

import 'package:yaml/yaml.dart';

import 'lyrics.dart';

/// A pause this long between two lines (or after the last before the song
/// ends) gets a gap line, as VK marks instrumental parts, so the line
/// before does not stay lit through the music.
const _gapMs = 8000;

/// Lyrics read from LRCLIB's [lyricsfile] for [source], or null when it
/// holds no timed words or does not look right for a song of [songSeconds]
/// (fewer than 3 lines with words, or a line starting more than 5 s after
/// the song's end).
Lyrics? lyricsFromLyricsfile(
  String source,
  String? lyricsfile, {
  int? songSeconds,
}) {
  if (lyricsfile == null || lyricsfile.trim().isEmpty) return null;
  final Object? document;
  try {
    document = loadYaml(lyricsfile);
  } on Object {
    return null; // Not YAML we can read: the row's other lyrics are used.
  }
  if (document is! Map || document['lines'] is! List) return null;
  final read = <LyricLine>[];
  for (final item in document['lines'] as List) {
    final line = _lineOf(item);
    if (line != null) read.add(line);
  }
  read.sort((a, b) => a.startMs!.compareTo(b.startMs!));
  if (read.length < 3) return null;
  final songMs = songSeconds == null || songSeconds <= 0
      ? null
      : songSeconds * 1000;
  if (songMs != null && read.last.startMs! > songMs + 5000) return null;
  final lines = <LyricLine>[];
  for (final line in read) {
    final previousEnd = lines.isEmpty ? null : lines.last.endMs;
    if (previousEnd != null && line.startMs! - previousEnd >= _gapMs) {
      lines.add(LyricLine('', startMs: previousEnd, endMs: line.startMs));
    }
    lines.add(line);
  }
  final lastEnd = lines.last.endMs;
  if (songMs != null && lastEnd != null && songMs - lastEnd >= _gapMs) {
    lines.add(LyricLine('', startMs: lastEnd, endMs: songMs));
  }
  return Lyrics(source: source, lines: lines);
}

/// One line of the lyricsfile, its text made of its word pieces so the word
/// times count the same words; null for a line without a start or words.
LyricLine? _lineOf(Object? item) {
  if (item is! Map) return null;
  final start = item['start_ms'];
  if (start is! num) return null;
  final end = item['end_ms'];
  final pieces = <({String text, int startMs})>[];
  final words = item['words'];
  if (words is List) {
    for (final word in words) {
      if (word is! Map) continue;
      final text = word['text'];
      final at = word['start_ms'];
      if (text is! String || at is! num || text.isEmpty) continue;
      pieces.add((text: text, startMs: at.round()));
    }
  }
  final lineStart = start.round();
  final lineEnd = end is num ? end.round() : null;
  if (pieces.isEmpty) {
    final text = item['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return LyricLine(text.trim(), startMs: lineStart, endMs: lineEnd);
  }
  // The words on screen: runs of pieces up to a piece that ends in a
  // space (or the last).
  final text = StringBuffer();
  final times = <WordTime?>[];
  int? wordStart;
  for (var i = 0; i < pieces.length; i++) {
    final piece = pieces[i];
    wordStart ??= piece.startMs;
    text.write(piece.text);
    final ends = piece.text.endsWith(' ') || i == pieces.length - 1;
    if (!ends) continue;
    final next = i + 1 < pieces.length ? pieces[i + 1].startMs : null;
    final wordEnd = next ?? lineEnd ?? piece.startMs;
    // Every word on screen this run adds gets its time (a piece may hold
    // several, "New York "; one of spaces only adds none).
    final added = lineWords(text.toString()).length - times.length;
    for (var k = 0; k < added; k++) {
      times.add(WordTime(wordStart, wordEnd < wordStart ? wordStart : wordEnd));
    }
    wordStart = null;
  }
  final lineText = text.toString().trim();
  if (lineText.isEmpty) return null;
  return LyricLine(
    lineText,
    startMs: lineStart,
    endMs: lineEnd,
    words: times.length == lineWords(lineText).length ? times : null,
  );
}
