/// The picture of a karaoke video (plan 11 C1): a song's timed lyrics as an
/// ASS subtitle script, which libass inside ffmpeg draws over the blurred
/// cover. Pure Dart, no I/O.
///
/// What the script shows, for each sung line:
///  - the line being sung in the middle, its words filling from white to
///    the accent colour as they are sung (`\kf`, the same smooth fill as
///    the Lyrics page);
///  - the lines before it above and the lines after it below, dim
///    (landscape one each, vertical two each);
///  - before the first line a title card (title, artist), and before a
///    line that comes after a long pause three dots counting down;
///  - the artist and title small at the bottom all through.
///
/// A line starts being shown up to [leadMs] before it is sung (never before
/// the line above has ended), so the singer can read ahead. A line without
/// word times gets its words spread over its time by their length (the
/// export dialog says so: [KaraokeLines.guessedLines]).
///
/// Long lines are broken into rows here, by a [TextWidth] function that
/// measures the text as libass will draw it, and the script turns libass's
/// own wrapping off (WrapStyle 2). So the code knows how tall each block
/// is and places the lines around the sung one without overlap.
library;

import 'dart:math' as math;

import '../lyrics/lyrics.dart';

/// The two shapes of the video (user, 2026-11-28: "Both, chosen at export").
enum KaraokeShape {
  /// 1920 x 1080: one line before, the sung line, one line after.
  landscape(1920, 1080, around: 1, sungSize: 76, dimSize: 54, margin: 140),

  /// 1080 x 1920: two lines before, the sung line, two lines after.
  vertical(1080, 1920, around: 2, sungSize: 72, dimSize: 52, margin: 80);

  const KaraokeShape(
    this.width,
    this.height, {
    required this.around,
    required this.sungSize,
    required this.dimSize,
    required this.margin,
  });

  final int width;
  final int height;

  /// How many lines show above and below the sung one.
  final int around;

  /// Font sizes in pixels of the video.
  final int sungSize;
  final int dimSize;

  /// Left and right margin; text wraps inside them.
  final int margin;
}

/// How long before its first word a line is shown (if the line above has
/// ended by then).
const leadMs = 3000;

/// A pause of at least this long before a line gets the count-down dots.
const countdownGapMs = 6000;

/// A line without an end and without word times is taken to last at most
/// this long (its words are spread over it).
const guessedLineMaxMs = 8000;

/// The font every style uses (bold). Segoe UI ships with Windows and has
/// Latin, Cyrillic and Greek.
const karaokeFont = 'Segoe UI';

/// The width in video pixels of [text] drawn in bold [karaokeFont] at the
/// ASS font size [size]. In the app this is Flutter's text layout at the
/// em size [size] * [segoeUiEmPerAssSize]; tests pass a fake.
typedef TextWidth = double Function(String text, int size);

/// The em size of Segoe UI for one unit of ASS font size. libass (like
/// VSFilter) takes the font size as the font's whole height, OS/2
/// winAscent + winDescent: 2210 + 514 units of Segoe UI's 2048 (read from
/// segoeui.ttf and segoeuib.ttf, 2026-11-28). So a 76 px ASS font has a
/// 57 px em, and one row of text is exactly [size] pixels tall.
const segoeUiEmPerAssSize = 2048 / (2210 + 514);

/// Space between the sung block and the dim lines, in video pixels.
const _blockGap = 28;

/// Space between two dim lines (not between the rows of one line).
const _lineGap = 10;

/// One word of a sung line and when it is sung.
class KaraokeWord {
  const KaraokeWord(this.text, this.startMs, this.endMs);

  final String text;
  final int startMs;
  final int endMs;

  @override
  String toString() => 'KaraokeWord($startMs-$endMs ${text.length} chars)';
}

/// One sung line: its words in order, never going back in time.
class KaraokeLine {
  const KaraokeLine(this.words, {required this.guessed});

  final List<KaraokeWord> words;

  /// Whether the word times were spread by length (the lyrics had none).
  final bool guessed;

  int get startMs => words.first.startMs;
  int get endMs => words.last.endMs;
  String get text => words.map((word) => word.text).join(' ');
}

/// The sung lines of a song's lyrics, ready for the script.
class KaraokeLines {
  KaraokeLines._(this.lines);

  /// The lines that have a start and words, by start time; label rows,
  /// passed rows ([LyricLine.label], [LyricLine.passed]) and empty lines
  /// (pauses) are left out, though a pause still ends the line before it.
  ///
  /// [shiftMs] moves every time, so the video lights a line when the
  /// Lyrics page does: the user's offset for this lyrics source minus the
  /// page's lead (lyricsLeadMs), given by the caller.
  factory KaraokeLines.of(List<LyricLine> lyrics, {int shiftMs = 0}) {
    final timed = [
      for (final line in lyrics)
        if (line.startMs != null && !line.label && !line.passed)
          shiftMs == 0 ? line : line.shiftedBy(shiftMs),
    ];
    // Stable sort: equal starts keep their order.
    final order = List.generate(timed.length, (i) => i)
      ..sort((a, b) {
        final byStart = timed[a].startMs!.compareTo(timed[b].startMs!);
        return byStart != 0 ? byStart : a.compareTo(b);
      });
    final sorted = [for (final i in order) timed[i]];
    final lines = <KaraokeLine>[];
    for (var i = 0; i < sorted.length; i++) {
      final line = sorted[i];
      if (line.isGap) continue;
      final next = i + 1 < sorted.length ? sorted[i + 1].startMs : null;
      final made = _wordsOf(line, next);
      if (made != null) lines.add(made);
    }
    return KaraokeLines._(lines);
  }

  final List<KaraokeLine> lines;

  bool get isEmpty => lines.isEmpty;

  /// How many lines got guessed word times.
  int get guessedLines => lines.where((line) => line.guessed).length;
}

/// The words of [line] with their times; [nextStartMs] is when the next
/// timed row (a line or a pause) starts.
KaraokeLine? _wordsOf(LyricLine line, int? nextStartMs) {
  final texts = lineWords(line.text);
  if (texts.isEmpty) return null;
  final start = line.startMs!;
  final times = line.words;
  final words = <KaraokeWord>[];
  if (times != null) {
    // Own word times; a word without one (a dash, digits) lights at once
    // when the word before has ended, or (none before) when the next timed
    // word starts, as on the Lyrics page (sungWordShares).
    var cursor = start;
    for (var i = 0; i < texts.length; i++) {
      final time = times[i];
      int from, to;
      if (time != null) {
        from = math.max(time.startMs, cursor);
        to = math.max(time.endMs, from);
      } else {
        final before = i > 0;
        int? nextTimed;
        for (var j = i + 1; j < times.length && !before; j++) {
          if (times[j] != null) {
            nextTimed = times[j]!.startMs;
            break;
          }
        }
        from = math.max(before ? cursor : (nextTimed ?? cursor), cursor);
        to = from;
      }
      words.add(KaraokeWord(texts[i], from, to));
      cursor = to;
    }
    return KaraokeLine(words, guessed: false);
  }
  // No word times: spread the words over the line by length (letters + 1,
  // so short words still get a moment).
  var end = line.endMs ?? nextStartMs ?? start + guessedLineMaxMs;
  if (line.endMs == null) end = math.min(end, start + guessedLineMaxMs);
  if (nextStartMs != null && nextStartMs > start) {
    end = math.min(end, nextStartMs);
  }
  if (end <= start) end = start + 1000;
  final weights = [for (final text in texts) text.length + 1];
  final total = weights.fold(0, (sum, weight) => sum + weight);
  var used = 0;
  for (var i = 0; i < texts.length; i++) {
    final from = start + (end - start) * used ~/ total;
    used += weights[i];
    final to = start + (end - start) * used ~/ total;
    words.add(KaraokeWord(texts[i], from, to));
  }
  return KaraokeLine(words, guessed: true);
}

/// Where each row of [words] starts (indexes into [words], the first is
/// always 0), so that every row is at most [maxWidth] wide at font size
/// [size], in as few rows as possible, and the rows as even as possible
/// (the widest row as narrow as it can be), the way karaoke lines read
/// best. A single word wider than [maxWidth] gets a row of its own.
List<int> wrapRows(
  List<String> words,
  int size,
  double maxWidth,
  TextWidth measure,
) {
  final n = words.length;
  if (n <= 1) return const [0];
  final widths = <int, double>{};
  // Width of the row holding words [from, to).
  double width(int from, int to) => widths[from * (n + 1) + to] ??= measure(
    words.sublist(from, to).join(' '),
    size,
  );
  bool fits(int from, int to) => to - from == 1 || width(from, to) <= maxWidth;

  if (fits(0, n)) return const [0];
  // Fewest rows: greedy filling.
  var rows = 0;
  for (var from = 0; from < n; rows++) {
    var to = from + 1;
    while (to < n && fits(from, to + 1)) {
      to++;
    }
    from = to;
  }
  // Evenest split into that many rows: best[k][j] is the narrowest widest
  // row for words [0, j) in k rows; cut[k][j] where its last row starts.
  const none = double.infinity;
  final best = List.generate(rows + 1, (_) => List.filled(n + 1, none));
  final cut = List.generate(rows + 1, (_) => List.filled(n + 1, 0));
  best[0][0] = 0;
  for (var k = 1; k <= rows; k++) {
    for (var j = k; j <= n; j++) {
      for (var i = k - 1; i < j; i++) {
        if (best[k - 1][i] == none || !fits(i, j)) continue;
        final widest = math.max(best[k - 1][i], width(i, j));
        if (widest < best[k][j]) {
          best[k][j] = widest;
          cut[k][j] = i;
        }
      }
    }
  }
  final starts = <int>[];
  for (var k = rows, j = n; k > 0; k--) {
    j = cut[k][j];
    starts.add(j);
  }
  return starts.reversed.toList();
}

/// [text] broken into rows (see [wrapRows]) and written with ASS's `\N`
/// row breaks, escaped; returns the text and how many rows it has.
(String, int) _wrapped(
  String text,
  int size,
  double maxWidth,
  TextWidth measure,
) {
  final words = lineWords(text);
  if (words.isEmpty) return (escapeAss(text), 1);
  final starts = wrapRows(words, size, maxWidth, measure);
  final out = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    if (i > 0) out.write(starts.contains(i) ? '\\N' : ' ');
    out.write(escapeAss(words[i]));
  }
  return (out.toString(), starts.length);
}

/// The ASS script of a karaoke video of [lines] in [shape], [durationMs]
/// long. [measure] gives text widths for breaking long lines into rows.
String karaokeScript({
  required KaraokeLines lines,
  required KaraokeShape shape,
  required String title,
  required String artist,
  required int durationMs,
  required TextWidth measure,
}) {
  final out = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('ScriptType: v4.00+')
    ..writeln('PlayResX: ${shape.width}')
    ..writeln('PlayResY: ${shape.height}')
    // 2: libass never wraps; rows are broken here with \N.
    ..writeln('WrapStyle: 2')
    ..writeln('ScaledBorderAndShadow: yes')
    ..writeln('YCbCr Matrix: TV.709')
    ..writeln()
    ..writeln('[V4+ Styles]')
    ..writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
      'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
      'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
      'Alignment, MarginL, MarginR, MarginV, Encoding',
    );
  final m = shape.margin;
  // Colours are &HAABBGGRR (alpha 00 = solid). The sung fill is the app's
  // accent (A594FF), unsung text the app's text colour (ECEEF3).
  void style(String name, int size, String primary, String secondary) =>
      out.writeln(
        'Style: $name,$karaokeFont,$size,$primary,$secondary,&H50000000,'
        '&H80000000,-1,0,0,0,100,100,0,0,1,3,2,5,$m,$m,40,1',
      );
  const footerSize = 34;
  final titleSize = shape.sungSize + 16;
  style('Sung', shape.sungSize, '&H00FF94A5', '&H00F3EEEC');
  // Primary and secondary alike, so the karaoke timing never changes it.
  style('Dim', shape.dimSize, '&H60F3EEEC', '&H60F3EEEC');
  style('Title', titleSize, '&H00F3EEEC', '&H00F3EEEC');
  style('Artist', shape.dimSize, '&H30F3EEEC', '&H30F3EEEC');
  style('Count', shape.sungSize, '&H00FF94A5', '&H00FF94A5');
  style('Footer', footerSize, '&H60F3EEEC', '&H60F3EEEC');
  out
    ..writeln()
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    );

  void event(int fromMs, int toMs, String styleName, String text) {
    final from = _cs(fromMs), to = _cs(toMs);
    if (to <= from) return;
    out.writeln(
      'Dialogue: 0,${_time(from)},${_time(to)},$styleName,,0,0,0,,$text',
    );
  }

  final cx = shape.width ~/ 2;
  final cy = shape.height ~/ 2;
  final wrapWidth = (shape.width - 2 * m).toDouble();
  final sung = lines.lines;
  final end = math.max(durationMs, sung.isEmpty ? 0 : sung.last.endMs);

  // Footer all through, growing upwards when it needs two rows.
  final (footer, footerRows) = _wrapped(
    artist.isEmpty ? title : '$artist - $title',
    footerSize,
    wrapWidth,
    measure,
  );
  final footerBottom = shape.height - 36;
  final footerTop = footerBottom - footerRows * footerSize;
  event(0, end, 'Footer', '{\\an2\\pos($cx,$footerBottom)}$footer');
  if (sung.isEmpty) return out.toString();

  // When each line starts and stops being the sung one on screen.
  final shows = <int>[];
  for (var i = 0; i < sung.length; i++) {
    final earliest = sung[i].startMs - leadMs;
    final after = i == 0 ? 0 : math.min(sung[i - 1].endMs, sung[i].startMs);
    shows.add(math.max(math.max(earliest, after), i == 0 ? 0 : shows[i - 1]));
  }
  int hideOf(int i) => i + 1 < sung.length
      ? shows[i + 1]
      : math.min(end, sung[i].endMs + leadMs);

  // Title card before the first line, when there is room for one: the
  // title's bottom row just above the middle, the artist just below it.
  if (shows.first >= 1500) {
    final (titleText, _) = _wrapped(title, titleSize, wrapWidth, measure);
    event(
      0,
      shows.first - 200,
      'Title',
      '{\\an2\\pos($cx,$cy)\\fad(300,300)}$titleText',
    );
    if (artist.isNotEmpty) {
      final (artistText, _) = _wrapped(
        artist,
        shape.dimSize,
        wrapWidth,
        measure,
      );
      event(
        0,
        shows.first - 200,
        'Artist',
        '{\\an8\\pos($cx,${cy + 16})\\fad(300,300)}$artistText',
      );
    }
  }

  // Each line wrapped once, at both sizes it is drawn in.
  final sungRows = [
    for (final line in sung)
      wrapRows(
        [for (final word in line.words) word.text],
        shape.sungSize,
        wrapWidth,
        measure,
      ),
  ];
  final dimText = [
    for (final line in sung)
      _wrapped(line.text, shape.dimSize, wrapWidth, measure),
  ];

  for (var i = 0; i < sung.length; i++) {
    final from = shows[i], to = hideOf(i);
    final line = sung[i];
    final half = sungRows[i].length * shape.sungSize ~/ 2;
    event(
      from,
      to,
      'Sung',
      '{\\an5\\pos($cx,$cy)}${_karaokeText(line, from, sungRows[i])}',
    );
    // The lines before, nearest first going up, as many as fit; each its
    // own event, a little apart, so a wrapped line reads as one.
    var beforeTop = cy - half - _blockGap;
    var placedBefore = 0;
    for (var j = i - 1; j >= 0 && j >= i - shape.around; j--) {
      final (text, rows) = dimText[j];
      final top = beforeTop - rows * shape.dimSize;
      if (top < 20) break;
      event(from, to, 'Dim', '{\\an2\\pos($cx,$beforeTop)}$text');
      beforeTop = top - _lineGap;
      placedBefore++;
    }
    // The lines after, going down, as many as fit above the footer.
    var afterTop = cy + half + _blockGap;
    for (var j = i + 1; j <= i + shape.around && j < sung.length; j++) {
      final (text, rows) = dimText[j];
      final bottom = afterTop + rows * shape.dimSize;
      if (bottom > footerTop - 16) break;
      event(from, to, 'Dim', '{\\an8\\pos($cx,$afterTop)}$text');
      afterTop = bottom + _lineGap;
    }
    // Count-down dots after a long pause (or a long intro), above the
    // lines before.
    final pauseFrom = i == 0 ? 0 : sung[i - 1].endMs;
    if (line.startMs - pauseFrom >= countdownGapMs) {
      final dotsY = math.max(
        shape.sungSize,
        placedBefore == 0 ? beforeTop : beforeTop + _lineGap - _blockGap,
      );
      for (var dots = 3; dots >= 1; dots--) {
        event(
          math.max(from, line.startMs - dots * 1000),
          line.startMs - (dots - 1) * 1000,
          'Count',
          '{\\an2\\pos($cx,$dotsY)}${List.filled(dots, '●').join(' ')}',
        );
      }
    }
  }
  return out.toString();
}

/// The sung line as karaoke syllables, timed from [eventStartMs]: a pause
/// before a word is an empty `\k` syllable, each word fills over its own
/// time (`\kf`). All in centiseconds counted from the absolute times, so
/// rounding never adds up along the line. A new row starts (`\N`) before
/// each word index in [rowStarts] but the first.
String _karaokeText(KaraokeLine line, int eventStartMs, List<int> rowStarts) {
  final out = StringBuffer();
  var cursor = _cs(eventStartMs);
  for (var i = 0; i < line.words.length; i++) {
    final word = line.words[i];
    final from = math.max(_cs(word.startMs), cursor);
    final to = math.max(_cs(word.endMs), from);
    if (i > 0) out.write(rowStarts.contains(i) ? '\\N' : ' ');
    if (from > cursor) out.write('{\\k${from - cursor}}');
    out.write('{\\kf${to - from}}${escapeAss(word.text)}');
    cursor = to;
  }
  return out.toString();
}

/// [text] safe inside an ASS event: braces would start an override block
/// and a backslash an escape (`\N`, `\h`), so they are written as libass's
/// own escapes (`\{`, `\}`) and a backslash as U+29F5 (a reverse solidus
/// lookalike; libass has no escape for it). Line breaks become spaces.
String escapeAss(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    switch (rune) {
      case 0x5C: // backslash
        out.write('⧵');
      case 0x7B: // {
        out.write('\\{');
      case 0x7D: // }
        out.write('\\}');
      case 0x0A || 0x0D || 0x09:
        out.write(' ');
      default:
        out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// Milliseconds to centiseconds, rounded.
int _cs(int ms) => (ms / 10).round();

/// Centiseconds as ASS's H:MM:SS.cc.
String _time(int cs) {
  final h = cs ~/ 360000;
  final m = cs ~/ 6000 % 60;
  final s = cs ~/ 100 % 60;
  final c = cs % 100;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}.${two(c)}';
}
