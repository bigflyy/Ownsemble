/// Reading lyrics in the LRC format that outside sources give (plan 10, E1).
///
/// LRCLIB, NetEase and QQ Music answer timed lyrics as LRC text: each line
/// starts with one or more time tags `[mm:ss.xx]`, metadata lines look like
/// `[ar:Artist]`, `[offset:+300]` moves every time, and word-timed lyrics
/// put `<mm:ss.xx>` tags inside a line. NetEase and QQ also put credit lines
/// at the start ("lyricist : x" written in Chinese) and QQ escapes some
/// characters as HTML entities. This file turns such text into [Lyrics].
library;

import 'dart:math' as math;

import 'lyrics.dart';

/// A time tag at the start of a line: minutes, seconds, an optional
/// fraction (1 digit = tenths, 2 = hundredths, 3 = milliseconds).
final _timeTag = RegExp(r'^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// Any time tag inside a line, with square or angle brackets (word timing).
final _innerTimeTag = RegExp(
  r'[\[<](\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?[\]>]',
);

/// A word stamp may sit this far before its line's own start (rounding in
/// the sources' tools) and still count as the line's.
const _wordEarlyMs = 1000;

/// A word stamp this far after its line's start is not the line's.
const _wordLateMs = 60000;

/// The end of a last word with no stamp after it: the next line's start,
/// but at most this long after the word started.
const _lastWordMaxMs = 1500;

/// A metadata line such as `[ar:Artist]` or `[offset:+300]`.
final _metaTag = RegExp(r'^\[([a-zA-Z#]+):([^\]]*)\]\s*$');

/// A credit line in Chinese at the start of NetEase and QQ lyrics, such as
/// "lyricist : name" or "composer: name" (a short run of Han characters,
/// then a colon, ASCII or full width).
final _creditLine = RegExp(r'^\s*\p{Script=Han}{1,8}\s*[:：]', unicode: true);

/// Lyrics read from [lrc] for [source], or null when it holds no words.
///
/// Timed when the text has time tags; then a line without a tag is dropped
/// (sources put notes there). Timed lyrics that do not look right for the
/// song are kept as words only: fewer than 3 lines with words, or the last
/// line starting more than 5 s after the song's end ([songSeconds], when
/// known). A first line that only names the song ("[title] - [artist]",
/// which QQ puts at 0:00) is dropped when [title] and [artist] are given.
Lyrics? lyricsFromLrc(
  String source,
  String? lrc, {
  int? songSeconds,
  String? title,
  String? artist,
}) {
  if (lrc == null || lrc.trim().isEmpty) return null;
  final text = decodeHtmlEntities(lrc);
  var offsetMs = 0;
  final timed = <LyricLine>[];
  final plain = <LyricLine>[];
  var sawTimeTag = false;
  for (final raw in text.replaceAll('\r', '').split('\n')) {
    final meta = _metaTag.firstMatch(raw.trim());
    if (meta != null) {
      if (meta.group(1)!.toLowerCase() == 'offset') {
        offsetMs = int.tryParse(meta.group(2)!.trim().replaceAll('+', '')) ?? 0;
      }
      continue;
    }
    // All the time tags at the start of the line: one line may be sung
    // at several moments (a chorus written once).
    var rest = raw.trimLeft();
    final starts = <int>[];
    for (
      var tag = _timeTag.firstMatch(rest);
      tag != null;
      tag = _timeTag.firstMatch(rest)
    ) {
      starts.add(_tagMs(tag));
      rest = rest.substring(tag.end);
    }
    final words = rest.replaceAll(_innerTimeTag, '').trim();
    if (starts.isEmpty) {
      plain.add(LyricLine(words));
      continue;
    }
    sawTimeTag = true;
    final stamped = _wordStamps(rest, starts.first);
    for (final start in starts) {
      // A line sung at several moments: its word stamps belong to the
      // first, and move with the line to the others.
      final delta = start - starts.first;
      timed.add(
        LyricLine(
          words,
          startMs: start,
          words: stamped == null
              ? null
              : [for (final word in stamped) word?.shifted(delta)],
        ),
      );
    }
  }
  if (sawTimeTag) {
    // LRC's offset: a positive one makes the lines come sooner.
    var lines = [for (final line in timed) line.shiftedBy(-offsetMs)];
    lines = sortLinesByStart(lines);
    lines = _endLastWords(lines);
    lines = _dropLeadingCredits(lines, title: title, artist: artist);
    lines = tidyLyricGaps(lines);
    if (_looksRight(lines, songSeconds)) {
      return Lyrics(source: source, lines: lines);
    }
    // Times that do not fit the song: its words are still worth showing.
    return _plainOrNull(source, [
      for (final line in lines) LyricLine(line.text),
    ]);
  }
  return _plainOrNull(
    source,
    _dropLeadingCredits(plain, title: title, artist: artist),
  );
}

/// Lyrics from plain text (one line per line, an empty line between
/// verses), or null when it holds no words.
Lyrics? lyricsFromPlain(String source, String? text) {
  if (text == null) return null;
  return _plainOrNull(source, [
    for (final line in decodeHtmlEntities(
      text,
    ).replaceAll('\r', '').split('\n'))
      LyricLine(line.trimRight()),
  ]);
}

Lyrics? _plainOrNull(String source, List<LyricLine> lines) {
  final tidy = tidyLyricGaps(lines);
  if (tidy.every((line) => line.isGap)) return null;
  return Lyrics(source: source, lines: tidy);
}

/// The word times of one LRC line's text after its leading time tags
/// ([rest], still holding its `<mm:ss.xx>` word stamps), by
/// space-separated word of the text without the stamps (plan 10 J3).
///
/// A word starts at the last stamp before its first letter (the line's own
/// [lineStartMs] before any stamp: some sources stamp only the words after
/// the first) and ends at the first stamp after its last letter. A word
/// with no stamp after it gets its end later ([_endLastWords]; its end is
/// its start here). Null when the line has no word stamps, or when they do not fit
/// the line: going back in time, or far from the line's own start.
List<WordTime?>? _wordStamps(String rest, int lineStartMs) {
  final tags = _innerTimeTag.allMatches(rest).toList();
  if (tags.isEmpty) return null;
  // Every letter of the text without stamps, with the stamp before it;
  // and the stamps that came after each letter.
  final text = StringBuffer();
  final startOf = <int>[]; // per character of [text]
  final stampAfter = <int?>[]; // per character: the first stamp after it
  var stamp = lineStartMs;
  var at = 0;
  final pendingAfter = <int>[]; // characters still waiting for a stamp
  for (final tag in tags) {
    for (final char in rest.substring(at, tag.start).split('')) {
      text.write(char);
      startOf.add(stamp);
      stampAfter.add(null);
      pendingAfter.add(startOf.length - 1);
    }
    stamp = _tagMs(tag);
    for (final i in pendingAfter) {
      stampAfter[i] = stamp;
    }
    pendingAfter.clear();
    at = tag.end;
  }
  for (final char in rest.substring(at).split('')) {
    text.write(char);
    startOf.add(stamp);
    stampAfter.add(null);
  }
  // The words of the trimmed text, found in the untrimmed one.
  final full = text.toString();
  final times = <WordTime?>[];
  var previous = -1;
  for (final match in RegExp(r'\S+').allMatches(full)) {
    final start = startOf[match.start];
    final end = stampAfter[match.end - 1];
    if (start < previous ||
        start < lineStartMs - _wordEarlyMs ||
        start > lineStartMs + _wordLateMs) {
      return null;
    }
    previous = start;
    // No stamp after it, or one before its start: its end is not known,
    // and stays at its start until [_endLastWords].
    times.add(WordTime(start, end == null || end < start ? start : end));
  }
  return times.isEmpty ? null : times;
}

/// Gives a word whose end is not known (its end is its start, from
/// [_wordStamps]) the next word's start, or for the last word the next
/// line's start, as its end, at most
/// [_lastWordMaxMs] after it began; drops the word times of a line whose
/// words start after the next line does.
List<LyricLine> _endLastWords(List<LyricLine> lines) => [
  for (var i = 0; i < lines.length; i++)
    _endWords(lines[i], i + 1 < lines.length ? lines[i + 1].startMs : null),
];

LyricLine _endWords(LyricLine line, int? nextStartMs) {
  final words = line.words;
  if (words == null) return line;
  final lastStart = words.lastWhere((word) => word != null)!.startMs;
  if (nextStartMs != null && lastStart > nextStartMs + _wordEarlyMs) {
    return LyricLine(line.text, startMs: line.startMs, endMs: line.endMs);
  }
  return LyricLine(
    line.text,
    startMs: line.startMs,
    endMs: line.endMs,
    words: [
      for (var i = 0; i < words.length; i++)
        if (words[i] case final word? when word.endMs <= word.startMs)
          WordTime(
            word.startMs,
            _endAfter(word.startMs, _nextStart(words, i) ?? nextStartMs),
          )
        else
          words[i],
    ],
  );
}

/// The start of the first timed word after [words][i], if any.
int? _nextStart(List<WordTime?> words, int i) {
  for (var j = i + 1; j < words.length; j++) {
    if (words[j] case final word?) return word.startMs;
  }
  return null;
}

/// An end for a word starting at [startMs]: [nextMs] when it comes later,
/// at most [_lastWordMaxMs] after the start.
int _endAfter(int startMs, int? nextMs) => nextMs != null && nextMs > startMs
    ? math.min(nextMs, startMs + _lastWordMaxMs)
    : startMs + _lastWordMaxMs;

int _tagMs(RegExpMatch tag) {
  final minutes = int.parse(tag.group(1)!);
  final seconds = int.parse(tag.group(2)!);
  final fraction = tag.group(3);
  final fractionMs = fraction == null
      ? 0
      : switch (fraction.length) {
          1 => int.parse(fraction) * 100,
          2 => int.parse(fraction) * 10,
          _ => int.parse(fraction),
        };
  return (minutes * 60 + seconds) * 1000 + fractionMs;
}

/// Drops credit lines and a line naming the song before the first sung
/// line.
List<LyricLine> _dropLeadingCredits(
  List<LyricLine> lines, {
  String? title,
  String? artist,
}) {
  String fold(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );
  final names = title == null || artist == null
      ? const <String>{}
      : {fold('$title$artist'), fold('$artist$title')};
  var first = 0;
  while (first < lines.length) {
    final text = lines[first].text;
    final isCredit =
        lines[first].isGap ||
        _creditLine.hasMatch(text) ||
        names.contains(fold(text));
    if (!isCredit) break;
    first++;
  }
  return lines.sublist(first);
}

/// Whether timed lines fit a song of [songSeconds]: at least 3 lines with
/// words and none starting more than 5 s after the end.
bool _looksRight(List<LyricLine> lines, int? songSeconds) {
  if (lines.where((line) => !line.isGap).length < 3) return false;
  if (songSeconds == null || songSeconds <= 0) return true;
  return lines.last.startMs! <= songSeconds * 1000 + 5000;
}

/// Decodes the HTML entities QQ Music puts in its lyrics.
String decodeHtmlEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|apos|quot|amp|lt|gt|nbsp);'),
    (match) {
      final name = match.group(1)!;
      if (name.startsWith('#x')) {
        return String.fromCharCode(int.parse(name.substring(2), radix: 16));
      }
      if (name.startsWith('#')) {
        return String.fromCharCode(int.parse(name.substring(1)));
      }
      return switch (name) {
        'apos' => "'",
        'quot' => '"',
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        _ => ' ',
      };
    },
  );
}
