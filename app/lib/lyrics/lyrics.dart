/// A song's lyrics (plan 10): lines, timed when the source gives times.
///
/// What VK gives (tool/probe_lyrics.dart, 2026-11-21): `audio.getLyrics`
/// answers `{md5, credits, lyrics: {language, text: [lines]}}` or
/// `{..., lyrics: {language, timestamps: [{begin, end, line}]}}`, times in
/// milliseconds. About half the songs with lyrics are timed. An empty plain
/// line is a verse break; an empty timed line is an instrumental gap.
/// `language` often does not match the words, so it is not kept.
library;

import 'dart:convert';

/// One line of lyrics; a timed line knows when it starts and ends.
class LyricLine {
  const LyricLine(this.text, {this.startMs, this.endMs, this.label = false});

  final String text;

  /// When the line starts in the song, milliseconds; null in plain lyrics.
  final int? startMs;
  final int? endMs;

  /// Whether the row is a note in fitted plain words, not sung (a section
  /// header such as "[Chorus]", a repeat mark such as "x2"): it is shown
  /// in place but never lit and a click on it does not jump (plan 10 H5,
  /// user 2026-11-23). Set only on lyrics made for showing, never stored.
  final bool label;

  /// Whether the line has no words: a verse break or an instrumental gap.
  bool get isGap => text.trim().isEmpty;

  @override
  bool operator ==(Object other) =>
      other is LyricLine &&
      other.text == text &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.label == label;

  @override
  int get hashCode => Object.hash(text, startMs, endMs, label);

  @override
  String toString() => 'LyricLine($startMs-$endMs ${text.length} chars)';
}

/// A song's lyrics from one source.
class Lyrics {
  const Lyrics({required this.source, required this.lines});

  /// Where they came from: 'vk', or an outside source ('lrclib', 'netease',
  /// 'qq': lib/lyrics/lyrics_sources.dart).
  final String source;
  final List<LyricLine> lines;

  /// Whether every line has a start time, so the lines can follow the song.
  bool get timed =>
      lines.isNotEmpty && lines.every((line) => line.startMs != null);

  /// The index of the line sung at [ms] into the song: the last line that
  /// starts at or before it, label rows ([LyricLine.label]) passed over.
  /// -1 before the first line or for plain lyrics.
  int lineAt(int ms) {
    if (!timed) return -1;
    var low = 0, high = lines.length - 1, found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (lines[middle].startMs! <= ms) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    // A label row is never the line sung: the line before it stays lit.
    while (found >= 0 && lines[found].label) {
      found--;
    }
    return found;
  }

  /// The lines as stored in the library: `[{"t": text, "s": start, "e":
  /// end}]`, times left out for plain lines.
  String linesToJson() => jsonEncode([
    for (final line in lines)
      {
        't': line.text,
        if (line.startMs != null) 's': line.startMs,
        if (line.endMs != null) 'e': line.endMs,
      },
  ]);

  /// Reads lines written by [linesToJson].
  static List<LyricLine> linesFromJson(String json) => [
    for (final line in jsonDecode(json) as List)
      if (line case {'t': final String text})
        LyricLine(text, startMs: line['s'] as int?, endMs: line['e'] as int?),
  ];

  @override
  bool operator ==(Object other) =>
      other is Lyrics &&
      other.source == source &&
      other.lines.length == lines.length &&
      [for (var i = 0; i < lines.length; i++) other.lines[i] == lines[i]]
          .every((same) => same);

  @override
  int get hashCode => Object.hash(source, Object.hashAll(lines));
}

/// The lyrics in a VK `audio.getLyrics` reply, or null when it holds no
/// words. Timed lines are put in time order; gaps at the start (and plain
/// gaps at the end) are dropped and runs of gaps become one.
Lyrics? lyricsFromVk(Object? reply) {
  final lyrics = reply is Map ? reply['lyrics'] : null;
  if (lyrics is! Map) return null;
  final stamps = lyrics['timestamps'];
  final text = lyrics['text'];
  var lines = <LyricLine>[];
  if (stamps is List && stamps.isNotEmpty) {
    for (final stamp in stamps) {
      if (stamp case {'begin': final num begin}) {
        final end = stamp['end'];
        lines.add(
          LyricLine(
            _clean(stamp['line']),
            startMs: begin.round(),
            endMs: end is num ? end.round() : null,
          ),
        );
      }
    }
    lines = sortLinesByStart(lines);
  } else if (text is List) {
    lines = [for (final line in text) LyricLine(_clean(line))];
  } else if (text is String) {
    lines = [for (final line in text.split('\n')) LyricLine(_clean(line))];
  }
  lines = tidyLyricGaps(lines);
  if (lines.every((line) => line.isGap)) return null;
  return Lyrics(source: 'vk', lines: lines);
}

String _clean(Object? text) =>
    text is String ? text.replaceAll('\r', '').trimRight() : '';

List<LyricLine> sortLinesByStart(List<LyricLine> lines) {
  final indexed = [for (var i = 0; i < lines.length; i++) (i, lines[i])]
    ..sort((a, b) {
      final byStart = a.$2.startMs!.compareTo(b.$2.startMs!);
      return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
    });
  return [for (final (_, line) in indexed) line];
}

/// Drops gaps at the start and keeps one of each run of gaps. Plain gaps at
/// the end go too; a timed one there stays: it is the outro, and without it
/// the last sung line would stay lit through the silence (Codex review).
List<LyricLine> tidyLyricGaps(List<LyricLine> lines) {
  final tidy = <LyricLine>[];
  for (final line in lines) {
    if (line.isGap && (tidy.isEmpty || tidy.last.isGap)) continue;
    tidy.add(line);
  }
  while (tidy.isNotEmpty && tidy.last.isGap && tidy.last.startMs == null) {
    tidy.removeLast();
  }
  return tidy;
}
