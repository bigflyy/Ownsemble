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

/// When one word of a line is sung (plan 10 J2), milliseconds into the
/// song.
class WordTime {
  const WordTime(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  /// This time moved by [deltaMs], never before the song's start.
  WordTime shifted(int deltaMs) => WordTime(
    (startMs + deltaMs).clamp(0, 1 << 31),
    (endMs + deltaMs).clamp(0, 1 << 31),
  );

  @override
  bool operator ==(Object other) =>
      other is WordTime && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'WordTime($startMs-$endMs)';
}

final _spaces = RegExp(r'\s+');

/// The words of a line as word times count them: its text split at spaces,
/// empty pieces left out. A word here may hold punctuation ("know,") or be
/// punctuation alone ("-").
List<String> lineWords(String text) => [
  for (final word in text.trim().split(_spaces))
    if (word.isNotEmpty) word,
];

/// One line of lyrics; a timed line knows when it starts and ends.
class LyricLine {
  const LyricLine(
    this.text, {
    this.startMs,
    this.endMs,
    this.label = false,
    this.passed = false,
    this._words,
  });

  final String text;

  /// When the line starts in the song, milliseconds; null in plain lyrics.
  final int? startMs;
  final int? endMs;

  /// Whether the row is a note in fitted plain words, not sung (a section
  /// header such as "[Chorus]", a repeat mark such as "x2"): it is shown
  /// in place but never lit and a click on it does not jump (plan 10 H5,
  /// user 2026-11-23). Set only on lyrics made for showing, never stored.
  final bool label;

  /// Whether the row is a line of the user's edit whose own start is
  /// missing or earlier than the line above (plan 10 I2g): it is drawn as
  /// a line, but never lit (the line above stays lit) and a click on it
  /// does not jump. Set only on lyrics made for showing, never stored.
  final bool passed;

  final List<WordTime?>? _words;

  /// When each word of [lineWords] ([text] split at spaces) is sung, by
  /// index: null for a word without a time of its own (digits the aligner
  /// cannot read, a dash). Null when the line has no word times, or when
  /// the times given do not count the same words as the text (they are
  /// then not trusted).
  List<WordTime?>? get words {
    final words = _words;
    if (words == null || words.every((word) => word == null)) return null;
    return words.length == lineWords(text).length ? words : null;
  }

  /// Whether at least one word of the line has its own time.
  bool get hasWordTimes => words != null;

  /// Whether the line has no words: a verse break or an instrumental gap.
  bool get isGap => text.trim().isEmpty;

  /// This line with its start at [startMs]: the end and the word times move
  /// as far as the start did (none move when the line had no start).
  LyricLine movedTo(int? startMs, {bool? label}) {
    final old = this.startMs;
    final delta = old == null || startMs == null ? null : startMs - old;
    return LyricLine(
      text,
      startMs: startMs,
      endMs: switch ((endMs, delta)) {
        (final int end, final int delta) =>
          end + delta < startMs! ? startMs : end + delta,
        _ => null,
      },
      label: label ?? this.label,
      passed: passed,
      words: delta == null
          ? null
          : words == null
          ? null
          : [for (final word in words!) word?.shifted(delta)],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LyricLine &&
      other.text == text &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.label == label &&
      other.passed == passed &&
      _sameWords(other.words, words);

  @override
  int get hashCode => Object.hash(
    text,
    startMs,
    endMs,
    label,
    passed,
    words == null ? null : Object.hashAll(words!),
  );

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
  /// starts at or before it, label rows ([LyricLine.label]) and passed
  /// rows ([LyricLine.passed]) passed over.
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
    // A label or passed row is never the line sung: the line before it
    // stays lit.
    while (found >= 0 && (lines[found].label || lines[found].passed)) {
      found--;
    }
    return found;
  }

  /// Whether at least one line has word times of its own.
  bool get hasWordTimes => lines.any((line) => line.hasWordTimes);

  /// The index of the word of [lines][line] being sung at [ms]: the last
  /// word with a time that starts at or before it; -1 before its first
  /// timed word or when the line has no word times.
  int wordAt(int line, int ms) {
    if (line < 0 || line >= lines.length) return -1;
    final words = lines[line].words;
    if (words == null) return -1;
    var found = -1;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (word == null) continue;
      if (word.startMs > ms) break;
      found = i;
    }
    return found;
  }

  /// The lines as stored in the library: `[{"t": text, "s": start, "e":
  /// end, "w": [[start, end] or null per word]}]`, times left out for plain
  /// lines and "w" for lines without word times. With [words] false the
  /// word times are left out (the lyrics' hash: the same lines with word
  /// times added are the same lyrics to a kept fit).
  String linesToJson({bool words = true}) => jsonEncode([
    for (final line in lines)
      {
        't': line.text,
        if (line.startMs != null) 's': line.startMs,
        if (line.endMs != null) 'e': line.endMs,
        if (words && line.words != null)
          'w': [
            for (final word in line.words!)
              word == null ? null : [word.startMs, word.endMs],
          ],
      },
  ]);

  /// Reads lines written by [linesToJson].
  static List<LyricLine> linesFromJson(String json) => [
    for (final line in jsonDecode(json) as List)
      if (line case {'t': final String text})
        LyricLine(
          text,
          startMs: line['s'] as int?,
          endMs: line['e'] as int?,
          words: _wordsFromJson(line['w']),
        ),
  ];

  static List<WordTime?>? _wordsFromJson(Object? json) {
    if (json is! List) return null;
    return [
      for (final word in json)
        if (word case [final num start, final num end])
          WordTime(start.round(), end.round())
        else
          null,
    ];
  }

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

bool _sameWords(List<WordTime?>? a, List<WordTime?>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
