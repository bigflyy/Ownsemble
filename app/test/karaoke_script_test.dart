import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/karaoke/karaoke_script.dart';
import 'package:ownsemble/lyrics/lyrics.dart';

/// The Dialogue lines of [script] whose style is [style].
List<String> eventsOf(String script, String style) => [
  for (final line in script.split('\n'))
    if (line.startsWith('Dialogue:') && line.split(',')[3] == style) line,
];

/// The text field of a Dialogue line (everything after the 9th comma).
String textOf(String event) => event.split(',').skip(9).join(',');

/// The sum of the karaoke durations (\k and \kf) in an event's text, cs.
int karaokeSum(String text) =>
    RegExp(r'\\kf?(\d+)')
        .allMatches(text)
        .fold(0, (sum, m) => sum + int.parse(m.group(1)!));

/// A fake text width: every character half the font size wide.
double halfSize(String text, int size) => text.length * size / 2;

String scriptOf(
  List<LyricLine> lines, {
  KaraokeShape shape = KaraokeShape.landscape,
  int durationMs = 60000,
  int shiftMs = 0,
  String title = 'Title',
}) => karaokeScript(
  lines: KaraokeLines.of(lines, shiftMs: shiftMs),
  shape: shape,
  title: title,
  artist: 'Artist',
  durationMs: durationMs,
  measure: halfSize,
);

void main() {
  test('own word times fill each word over its time, pauses as empty k', () {
    final line = LyricLine(
      'one two',
      startMs: 10000,
      endMs: 12000,
      words: const [WordTime(10000, 10500), WordTime(11000, 12000)],
    );
    final sung = eventsOf(scriptOf([line]), 'Sung').single;
    // Shown 3 s early: a 3 s empty piece, then one, a 0.5 s pause, two.
    expect(sung, startsWith('Dialogue: 0,0:00:07.00,'));
    expect(textOf(sung), endsWith('{\\k300}{\\kf50}one {\\k50}{\\kf100}two'));
  });

  test('a line without word times spreads its words by length', () {
    final lines = KaraokeLines.of([
      const LyricLine('aa b', startMs: 0, endMs: 1000),
    ]);
    final words = lines.lines.single.words;
    expect(lines.guessedLines, 1);
    // Weights 3 and 2 of 5.
    expect(
      [for (final w in words) (w.startMs, w.endMs)],
      [(0, 600), (600, 1000)],
    );
  });

  test('a guessed line without an end stops at the next line', () {
    final lines = KaraokeLines.of([
      const LyricLine('a b', startMs: 0),
      const LyricLine('c', startMs: 2000),
      const LyricLine('d', startMs: 60000),
    ]);
    expect(lines.lines[0].endMs, 2000);
    expect(lines.lines[1].endMs, 2000 + guessedLineMaxMs);
  });

  test('untimed words light as the Lyrics page lights them', () {
    final lines = KaraokeLines.of([
      LyricLine(
        '- go 2 now',
        startMs: 1000,
        words: const [null, WordTime(1500, 2000), null, WordTime(2500, 3000)],
      ),
    ]);
    final words = lines.lines.single.words;
    // The dash lights when the next timed word starts, the 2 when "go" ends.
    expect(
      [for (final w in words) (w.startMs, w.endMs)],
      [(1500, 1500), (1500, 2000), (2000, 2000), (2500, 3000)],
    );
  });

  test('label, passed and empty rows are not sung; lines sorted', () {
    final lines = KaraokeLines.of([
      const LyricLine('later', startMs: 5000, endMs: 6000),
      const LyricLine('[Chorus]', startMs: 1000, label: true),
      const LyricLine('skipped', startMs: 2000, passed: true),
      const LyricLine('', startMs: 3000),
      const LyricLine('first', startMs: 0, endMs: 4000),
      const LyricLine('plain'),
    ]);
    expect([for (final l in lines.lines) l.text], ['first', 'later']);
    // The empty row (a pause at 3 s) ends "first" before its own end, as
    // the Lyrics page stops lighting it there.
    expect(lines.lines.first.endMs, 3000);
  });

  test('the shift moves every time (offset minus lead)', () {
    final lines = KaraokeLines.of([
      LyricLine(
        'a',
        startMs: 1000,
        endMs: 2000,
        words: const [WordTime(1000, 2000)],
      ),
    ], shiftMs: 380);
    expect(lines.lines.single.startMs, 1380);
    expect(lines.lines.single.endMs, 2380);
  });

  test('karaoke pieces add up to the rounded word end over a long song', () {
    // 10 minutes of lines with awkward millisecond times.
    final lines = [
      for (var i = 0; i < 200; i++)
        LyricLine(
          'w1 w2 w3',
          startMs: i * 3000 + 7,
          endMs: i * 3000 + 2993,
          words: [
            WordTime(i * 3000 + 7, i * 3000 + 1003),
            WordTime(i * 3000 + 1336, i * 3000 + 2004),
            WordTime(i * 3000 + 2005, i * 3000 + 2993),
          ],
        ),
    ];
    final script = scriptOf(lines, durationMs: 600000);
    final sung = eventsOf(script, 'Sung');
    expect(sung, hasLength(200));
    for (var i = 0; i < sung.length; i++) {
      final start = sung[i].split(',')[1];
      final parts = start.split(':');
      final startCs =
          int.parse(parts[0]) * 360000 +
          int.parse(parts[1]) * 6000 +
          (double.parse(parts[2]) * 100).round();
      final lastEndCs = ((i * 3000 + 2993) / 10).round();
      expect(startCs + karaokeSum(textOf(sung[i])), lastEndCs, reason: '$i');
    }
  });

  test('times format as H:MM:SS.cc past an hour', () {
    final script = scriptOf([
      LyricLine(
        'late',
        startMs: 3723450,
        endMs: 3724000,
        words: const [WordTime(3723450, 3724000)],
      ),
    ], durationMs: 3730000);
    expect(eventsOf(script, 'Sung').single, contains(',1:02:00.45,'));
  });

  test('Cyrillic text passes through unchanged', () {
    const text = '\u041f\u0440\u0438\u0432\u0435\u0442 \u043c\u0438\u0440';
    final script = scriptOf([const LyricLine(text, startMs: 0, endMs: 900)]);
    expect(textOf(eventsOf(script, 'Sung').single), contains('\u041f\u0440'));
  });

  test('braces and backslashes cannot start ASS codes', () {
    expect(escapeAss(r'a{b}c\N'), 'a\\{b\\}c\u29F5N');
    expect(escapeAss('x\ny'), 'x y');
  });

  test('neighbours: one each side in landscape, two in vertical', () {
    final lines = [
      for (var i = 0; i < 6; i++)
        LyricLine('line$i', startMs: i * 2000, endMs: i * 2000 + 1500),
    ];
    final landscape = scriptOf(lines);
    final vertical = scriptOf(lines, shape: KaraokeShape.vertical);
    // While line 3 is sung: dim blocks hold line 2 / line 4 (landscape) and
    // lines 1-2 / 4-5 (vertical).
    bool has(String script, String text) =>
        eventsOf(script, 'Dim').any((e) => textOf(e).endsWith(text));
    expect(has(landscape, '}line2'), isTrue);
    expect(has(landscape, '}line4'), isTrue);
    // Each neighbour its own event, 10 px apart: sung row 72 px around
    // 960, 28 px gap, dim rows 52 px.
    final dims = [for (final e in eventsOf(vertical, 'Dim')) textOf(e)];
    expect(dims, contains(r'{\an2\pos(540,896)}line2'));
    expect(dims, contains(r'{\an2\pos(540,834)}line1'));
    expect(dims, contains(r'{\an8\pos(540,1024)}line4'));
    expect(dims, contains(r'{\an8\pos(540,1086)}line5'));
  });

  test('count-down dots before a line after a long pause', () {
    final script = scriptOf([
      const LyricLine('a', startMs: 1000, endMs: 2000),
      const LyricLine('b', startMs: 20000, endMs: 21000),
    ]);
    final dots = eventsOf(script, 'Count');
    expect(dots, hasLength(3));
    expect(dots.first, contains(',0:00:17.00,0:00:18.00,'));
  });

  test('a title card when the first line comes late enough', () {
    final late = scriptOf([const LyricLine('a', startMs: 9000, endMs: 9500)]);
    expect(eventsOf(late, 'Title'), hasLength(1));
    final early = scriptOf([const LyricLine('a', startMs: 500, endMs: 900)]);
    expect(eventsOf(early, 'Title'), isEmpty);
  });

  test('no sung lines: only the footer', () {
    final script = scriptOf([const LyricLine('plain words')]);
    expect(eventsOf(script, 'Footer'), hasLength(1));
    expect(eventsOf(script, 'Sung'), isEmpty);
  });

  test('rows: as few as fit, then as even as possible', () {
    // 8 + 2 + 2 + 2 letters, 5 px each at size 10; 70 px fits 14 letters.
    final words = ['aaaaaaaa', 'bb', 'cc', 'dd'];
    expect(wrapRows(words, 10, 100, halfSize), [0]);
    // Greedy would give "aaaaaaaa bb cc" / "dd"; even is "aaaaaaaa" /
    // "bb cc dd".
    expect(wrapRows(words, 10, 70, halfSize), [0, 1]);
  });

  test('rows: a word wider than the screen gets a row of its own', () {
    final words = ['a', 'x' * 40, 'b'];
    expect(wrapRows(words, 10, 50, halfSize), [0, 1, 2]);
    expect(wrapRows(['x' * 40], 10, 50, halfSize), [0]);
  });

  test('a long sung line wraps; neighbours sit clear of both rows', () {
    // 12 words of 6 letters: 83 letters at 38 px; 1640 px fit 43.
    final long = [
      for (var i = 0; i < 12; i++) 'word${i.toString().padLeft(2, '0')}',
    ];
    final script = scriptOf([
      const LyricLine('before', startMs: 1000, endMs: 2000),
      LyricLine(long.join(' '), startMs: 2000, endMs: 8000),
      const LyricLine('after', startMs: 8000, endMs: 9000),
    ]);
    expect(script, contains('WrapStyle: 2'));
    final sung = textOf(eventsOf(script, 'Sung')[1]);
    expect(r'\N'.allMatches(sung), hasLength(1));
    // Six words a row, and the break replaces the space.
    expect(sung, contains(r'word05\N{\kf'));
    expect(sung, isNot(contains(r' \N')));
    // Two rows of 76 px around the middle (540), 28 px gap.
    final dims = [for (final e in eventsOf(script, 'Dim')) textOf(e)];
    expect(dims, contains(r'{\an2\pos(960,436)}before'));
    expect(dims, contains(r'{\an8\pos(960,644)}after'));
  });

  test('a long title wraps on the title card', () {
    final script = scriptOf([
      const LyricLine('a', startMs: 9000, endMs: 9500),
    ], title: List.filled(10, 'longtitle').join(' '));
    expect(textOf(eventsOf(script, 'Title').single), contains(r'\N'));
  });
}
