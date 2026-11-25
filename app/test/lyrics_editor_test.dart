// Tests for plan 10 I2g2: the lyrics editor's working copy. Rows, undo and
// redo, split and join, time notes, Tap to time, and "Edit as text" keeping
// the times of lines left as they were. The words are made up.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_editor.dart';

const start = [
  LyricLine('Огни над рекой', startMs: 12400),
  LyricLine('Last train out', startMs: 16100),
  LyricLine('', startMs: 20000),
  LyricLine('Every window', startMs: 24900),
];

List<String> texts(LyricsEditor editor) => [
  for (final line in editor.lines) line.text,
];

List<int?> starts(LyricsEditor editor) => [
  for (final line in editor.lines) line.startMs,
];

void main() {
  test('opens unchanged with the lines given', () {
    final editor = LyricsEditor(start);
    expect(
      editor.result,
      start.map((l) => LyricLine(l.text, startMs: l.startMs)),
    );
    expect(editor.changed, isFalse);
    expect(editor.canUndo, isFalse);
  });

  test('a run of typing in one row is one undo step', () {
    final editor = LyricsEditor(start);
    editor.setText(1, 'Last train');
    editor.setText(1, 'Last train ou');
    editor.setText(1, 'Last train outta');
    expect(editor.changed, isTrue);
    editor.undo();
    expect(texts(editor)[1], 'Last train out');
    expect(editor.changed, isFalse);
    editor.redo();
    expect(texts(editor)[1], 'Last train outta');
  });

  test('typing in another row starts a new step', () {
    final editor = LyricsEditor(start)
      ..setText(0, 'a')
      ..setText(1, 'b');
    editor.undo();
    expect(texts(editor).take(2), ['a', 'Last train out']);
  });

  test('Enter splits: the new row has no time; Backspace joins back', () {
    final editor = LyricsEditor(start);
    final at = editor.split(1, 'Last train'.length);
    expect(at, 2);
    expect(texts(editor).take(3), ['Огни над рекой', 'Last train', 'out']);
    expect(starts(editor).take(3), [12400, 16100, null]);
    final join = editor.joinUp(2);
    expect(join, 'Last train '.length);
    expect(texts(editor)[1], 'Last train out');
    expect(starts(editor)[1], 16100);
    expect(editor.joinUp(0), -1, reason: 'nothing above the first row');
  });

  test('insert, break, delete and nudges, each undoable', () {
    final editor = LyricsEditor(start);
    expect(editor.insertAt(1), 1);
    expect(editor.lines[1].startMs, isNull);
    editor.makeBreak(0);
    expect(editor.lines[0].text, '');
    expect(editor.lines[0].startMs, 12400);
    editor.nudge(2, -editNudgeMs);
    expect(editor.lines[2].startMs, 16000);
    editor.nudge(1, editNudgeMs);
    expect(editor.lines[1].startMs, isNull, reason: 'no time to move');
    editor.delete(1);
    expect(editor.lines.length, start.length);
    editor
      ..undo()
      ..undo()
      ..undo()
      ..undo();
    expect(editor.changed, isFalse);
  });

  test('a time never goes below zero', () {
    final editor = LyricsEditor(const [LyricLine('a', startMs: 50)]);
    editor.nudge(0, -editNudgeMs);
    expect(editor.lines.single.startMs, 0);
  });

  test('notes: no time, earlier than a line above, verse breaks fine', () {
    final editor = LyricsEditor(const [
      LyricLine('a', startMs: 1000),
      LyricLine('no time'),
      LyricLine(''),
      LyricLine('b', startMs: 5000),
      LyricLine('early', startMs: 3000),
    ]);
    expect(editor.noteOf(0), EditTimeNote.fine);
    expect(editor.noteOf(1), EditTimeNote.none);
    expect(editor.noteOf(2), EditTimeNote.fine);
    expect(editor.noteOf(4), EditTimeNote.early);
    final plain = LyricsEditor(const [LyricLine('a'), LyricLine('b')]);
    expect(plain.noteOf(0), EditTimeNote.fine, reason: 'plain words');
  });

  group('Tap to time', () {
    test('starts after the lines already sung, taps and moves on', () {
      final editor = LyricsEditor(start)..startTapping(17000);
      expect(editor.nextTap, 2);
      editor.tap(19800);
      expect(editor.lines[2].startMs, 19800);
      expect(editor.tapped(editor.lines[2].id), isTrue);
      expect(editor.nextTap, 3);
      editor.tapBack();
      expect(editor.nextTap, 2);
      editor.tapSkip();
      editor.tapSkip();
      expect(editor.nextTap, 4);
      editor.tap(99000);
      expect(editor.nextTap, 4, reason: 'nothing after the last row');
      editor.undo();
      expect(editor.lines[2].startMs, 20000, reason: 'each tap is undoable');
    });

    test('a row without a time comes up first', () {
      final editor = LyricsEditor(const [
        LyricLine('a', startMs: 1000),
        LyricLine('new'),
        LyricLine('b', startMs: 9000),
      ])..startTapping(5000);
      expect(editor.nextTap, 1);
    });

    test('taps only while on', () {
      final editor = LyricsEditor(start)..tap(1);
      expect(editor.changed, isFalse);
      editor
        ..startTapping(0)
        ..stopTapping()
        ..tap(1);
      expect(editor.changed, isFalse);
    });
  });

  group('Edit as text', () {
    test('unchanged and corrected lines keep times, new ones have none', () {
      final made = linesFromText(
        start,
        'Огни над рекою\nLast train out\n\nA new line\nEvery window\n',
      );
      expect(made.lines, const [
        LyricLine('Огни над рекою', startMs: 12400),
        LyricLine('Last train out', startMs: 16100),
        LyricLine('', startMs: 20000),
        LyricLine('A new line'),
        LyricLine('Every window', startMs: 24900),
      ]);
      expect(made.kept, 2);
      expect(made.corrected, 1);
      expect(made.added, 1);
    });

    test('a replaced line unlike the old one gets no time', () {
      final made = linesFromText(
        start,
        'zzz qqq\nLast train out\n\nEvery window',
      );
      expect(made.lines.first, const LyricLine('zzz qqq'));
    });

    test('pasted lyrics over nothing have no times', () {
      final made = linesFromText(const [], 'one\r\ntwo\r\n');
      expect(made.lines, const [LyricLine('one'), LyricLine('two')]);
      expect(linesFromText(const [], '').lines, isEmpty);
    });

    test('applyText is one undo step', () {
      final editor = LyricsEditor(start);
      expect(editor.text, 'Огни над рекой\nLast train out\n\nEvery window');
      editor.applyText('only one');
      expect(texts(editor), ['only one']);
      editor.undo();
      expect(editor.changed, isFalse);
    });
  });

  test('times show as m:ss.d', () {
    expect(editTimeText(null), '--:--');
    expect(editTimeText(0), '0:00.0');
    expect(editTimeText(12440), '0:12.4');
    expect(editTimeText(61960), '1:02.0');
    expect(editTimeText(599960), '10:00.0');
  });

  test('similar letters', () {
    expect(similarLetters('abc', 'abc'), 1);
    expect(similarLetters('Abc', 'a b c'), 1);
    expect(similarLetters('abcd', 'wxyz'), 0);
  });
}
