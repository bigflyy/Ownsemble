/// The lyrics editor's working copy (plan 10 I2g, mockup board 1 picked
/// 2026-11-25): one row per line with its start time and text, every
/// change undoable, Tap to time on the same rows, and editing as one text
/// with the times kept where the lines stay the same.
///
/// Pure logic: the editor place (lib/ui/lyrics_edit_page.dart) draws it and
/// passes in the player's position; nothing here plays or stores.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'lyrics.dart';

/// One row of the editor. [id] stays with the row through edits, so the
/// page keeps each row's text field.
@immutable
class EditLine {
  const EditLine(this.id, this.text, this.startMs);

  final int id;
  final String text;

  /// When the line starts, milliseconds; null when it has no time yet.
  final int? startMs;

  bool get isBreak => text.trim().isEmpty;

  EditLine withText(String value) => EditLine(id, value, startMs);
  EditLine withStart(int? value) => EditLine(id, text, value);
}

/// What one row's time says about it, for the row's note.
enum EditTimeNote {
  fine,

  /// No time: lit with the line above.
  none,

  /// Earlier than a line above: passed over, never lit.
  early,
}

/// One press of - or + moves a line's start this much.
const editNudgeMs = 100;

/// R in Tap to time plays from this far back.
const tapReplayMs = 3000;

/// Lines from "Edit as text" and how many kept a time.
typedef TextLines = ({
  List<LyricLine> lines,
  int kept,
  int corrected,
  int added,
});

class LyricsEditor extends ChangeNotifier {
  LyricsEditor(List<LyricLine> start)
    : _lines = [
        for (final line in start) EditLine(_nextId++, line.text, line.startMs),
      ] {
    _saved = _lines;
  }

  static int _nextId = 1;

  List<EditLine> _lines;
  late List<EditLine> _saved;
  final _undo = <List<EditLine>>[];
  final _redo = <List<EditLine>>[];

  /// The row whose text is being typed into, so a run of keystrokes is one
  /// undo step.
  int? _typingId;

  List<EditLine> get lines => List.unmodifiable(_lines);

  /// Whether anything differs from the lines the editor opened with.
  bool get changed => !_same(_lines, _saved);

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The edit as lines to keep (LyricsController.saveEdit).
  List<LyricLine> get result => [
    for (final line in _lines) LyricLine(line.text, startMs: line.startMs),
  ];

  static bool _same(List<EditLine> a, List<EditLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].text != b[i].text || a[i].startMs != b[i].startMs) return false;
    }
    return true;
  }

  /// Takes [next] as the lines, one undo step (a run of typing in one row
  /// stays one step).
  void _apply(List<EditLine> next, {int? typing}) {
    if (_same(next, _lines) && typing == null) return;
    if (typing == null || typing != _typingId) _undo.add(_lines);
    _typingId = typing;
    _redo.clear();
    _lines = next;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_lines);
    _lines = _undo.removeLast();
    _typingId = null;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_lines);
    _lines = _redo.removeLast();
    _typingId = null;
    notifyListeners();
  }

  /// The row of [id], -1 when it is gone.
  int indexOf(int id) => _lines.indexWhere((line) => line.id == id);

  /// The text of row [index] as typed.
  void setText(int index, String text) {
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    if (line.text == text) return;
    _apply([..._lines]..[index] = line.withText(text), typing: line.id);
  }

  /// Splits row [index] at [at] (Enter): the row keeps its time and the
  /// text before; the new row below gets the rest and no time. Returns the
  /// new row's index.
  int split(int index, int at) {
    final line = _lines[index];
    final cut = at.clamp(0, line.text.length);
    final next = [..._lines]
      ..[index] = line.withText(line.text.substring(0, cut).trimRight())
      ..insert(
        index + 1,
        EditLine(_nextId++, line.text.substring(cut).trimLeft(), null),
      );
    _apply(next);
    return index + 1;
  }

  /// Joins row [index] to the row above (Backspace at its start): the row
  /// above keeps its time. Returns where the join is in the row above's
  /// text, or -1 when there is no row above.
  int joinUp(int index) {
    if (index <= 0 || index >= _lines.length) return -1;
    final above = _lines[index - 1];
    final line = _lines[index];
    final gap = above.text.isEmpty || line.text.isEmpty ? '' : ' ';
    final next = [..._lines]
      ..[index - 1] = above.withText('${above.text}$gap${line.text}')
      ..removeAt(index);
    _apply(next);
    return above.text.length + gap.length;
  }

  /// A new empty row above [index] (at the end for [index] == length),
  /// without a time. Returns its index.
  int insertAt(int index) {
    final at = index.clamp(0, _lines.length);
    _apply([..._lines]..insert(at, EditLine(_nextId++, '', null)));
    return at;
  }

  void delete(int index) {
    if (index < 0 || index >= _lines.length) return;
    _apply([..._lines]..removeAt(index));
  }

  /// Makes row [index] a music break: no words, its time kept.
  void makeBreak(int index) {
    if (index < 0 || index >= _lines.length) return;
    _apply([..._lines]..[index] = _lines[index].withText(''));
  }

  /// Sets row [index]'s start ("now", a tap); null takes the time away.
  void setStart(int index, int? ms) {
    if (index < 0 || index >= _lines.length) return;
    final start = ms == null ? null : math.max(0, ms);
    if (_lines[index].startMs == start) return;
    _apply([..._lines]..[index] = _lines[index].withStart(start));
  }

  /// Moves row [index]'s start by [deltaMs]; a row without a time stays.
  void nudge(int index, int deltaMs) {
    final start = _lines[index].startMs;
    if (start != null) setStart(index, start + deltaMs);
  }

  /// What row [index]'s time says: none, earlier than a line above, fine.
  /// Breaks without a time are verse breaks, fine as they are.
  EditTimeNote noteOf(int index) {
    final line = _lines[index];
    final start = line.startMs;
    if (start == null) {
      return line.isBreak || !_anyStart ? EditTimeNote.fine : EditTimeNote.none;
    }
    for (var i = index - 1; i >= 0; i--) {
      final above = _lines[i].startMs;
      if (above != null && above > start) return EditTimeNote.early;
    }
    return EditTimeNote.fine;
  }

  /// Whether any row has a time: without one the words are plain, and no
  /// row is missing a time.
  bool get _anyStart => _lines.any((line) => line.startMs != null);

  // Tap to time.

  bool _tapping = false;
  int _nextTap = 0;
  final _tapped = <int>{};

  bool get tapping => _tapping;

  /// The row the next tap times; == lines.length after the last.
  int get nextTap => _nextTap;

  /// Whether row [id] got its time from a tap in this session.
  bool tapped(int id) => _tapped.contains(id);

  /// Starts Tap to time from where the song is ([positionMs]): the next
  /// row is the first one after the rows already sung, or the first row
  /// without a time when that comes earlier.
  void startTapping(int positionMs) {
    _tapping = true;
    _typingId = null;
    var next = _lines.indexWhere(
      (line) => line.startMs == null || line.startMs! > positionMs,
    );
    if (next < 0) next = _lines.length;
    _nextTap = next;
    notifyListeners();
  }

  void stopTapping() {
    if (!_tapping) return;
    _tapping = false;
    notifyListeners();
  }

  /// The row [nextTap] starts at [positionMs] (Space); the next row is up.
  void tap(int positionMs) {
    if (!_tapping || _nextTap >= _lines.length) return;
    final line = _lines[_nextTap];
    _tapped.add(line.id);
    _nextTap++;
    if (line.startMs == positionMs) {
      notifyListeners();
      return;
    }
    _apply([..._lines]..[_nextTap - 1] = line.withStart(positionMs));
  }

  /// Back a row (Left): that row is up again; its time stays until tapped.
  void tapBack() {
    if (!_tapping || _nextTap == 0) return;
    _nextTap--;
    notifyListeners();
  }

  /// Skips the row up (Down): it keeps its time.
  void tapSkip() {
    if (!_tapping || _nextTap >= _lines.length) return;
    _nextTap++;
    notifyListeners();
  }

  /// Makes row [index] the next to tap (a click on it while tapping).
  void tapFrom(int index) {
    if (!_tapping) return;
    _nextTap = index.clamp(0, _lines.length);
    notifyListeners();
  }

  // Edit as text.

  /// The rows as one text: one line per row, a break an empty row.
  String get text => _lines.map((line) => line.text).join('\n');

  /// Takes [text] as the rows, one undo step; times kept as
  /// [linesFromText] keeps them. Returns its counts.
  TextLines applyText(String text) {
    final made = linesFromText(result, text);
    _apply([
      for (final line in made.lines)
        EditLine(_nextId++, line.text, line.startMs),
    ]);
    return made;
  }
}

/// [text] as lines with the times of [old] kept: a line left as it was
/// keeps its time; inside a run of changed lines, lines are paired in order
/// and a corrected one (at least half its letters the same) keeps the old
/// time; other new lines have none. Trailing spaces and \r are dropped.
TextLines linesFromText(List<LyricLine> old, String text) {
  final typed = [
    for (final line in text.replaceAll('\r', '').split('\n')) line.trimRight(),
  ];
  // A text that ends with a newline has no empty row after it.
  while (typed.length > 1 && typed.last.isEmpty) {
    typed.removeLast();
  }
  if (typed.length == 1 && typed.single.isEmpty) typed.clear();
  final before = [for (final line in old) line.text.trimRight()];
  // Longest common run of equal lines (n and m are about 100).
  final n = before.length, m = typed.length;
  final common = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      common[i][j] = before[i] == typed[j]
          ? common[i + 1][j + 1] + 1
          : math.max(common[i + 1][j], common[i][j + 1]);
    }
  }
  final lines = <LyricLine>[];
  var kept = 0, corrected = 0, added = 0;
  var i = 0, j = 0;
  final oldRun = <int>[];
  final newRun = <int>[];
  void flush() {
    for (var k = 0; k < newRun.length; k++) {
      final line = typed[newRun[k]];
      final start = k < oldRun.length ? old[oldRun[k]].startMs : null;
      final close =
          k < oldRun.length && similarLetters(before[oldRun[k]], line) >= 0.5;
      if (close && start != null) {
        corrected++;
        lines.add(LyricLine(line, startMs: start));
      } else {
        if (line.isNotEmpty) added++;
        lines.add(LyricLine(line));
      }
    }
    oldRun.clear();
    newRun.clear();
  }

  while (i < n || j < m) {
    if (i < n && j < m && before[i] == typed[j]) {
      flush();
      if (old[i].startMs != null && typed[j].isNotEmpty) kept++;
      lines.add(LyricLine(typed[j], startMs: old[i].startMs));
      i++;
      j++;
    } else if (j < m && (i >= n || common[i][j + 1] >= common[i + 1][j])) {
      newRun.add(j++);
    } else {
      oldRun.add(i++);
    }
  }
  flush();
  return (lines: lines, kept: kept, corrected: corrected, added: added);
}

/// How alike two lines are by their letters, 0..1: the letters they share
/// (case and spaces left out) over the longer line's letters.
double similarLetters(String a, String b) {
  List<int> letters(String text) => [
    for (final rune in text.toLowerCase().runes)
      if (String.fromCharCode(rune).trim().isNotEmpty) rune,
  ];
  final left = letters(a), right = letters(b);
  if (left.isEmpty && right.isEmpty) return 1;
  final counts = <int, int>{};
  for (final rune in left) {
    counts[rune] = (counts[rune] ?? 0) + 1;
  }
  var shared = 0;
  for (final rune in right) {
    final count = counts[rune] ?? 0;
    if (count > 0) {
      shared++;
      counts[rune] = count - 1;
    }
  }
  return shared / math.max(left.length, right.length);
}

/// A start time as the editor shows it: m:ss.d ("--:--" for none).
String editTimeText(int? ms) {
  if (ms == null) return '--:--';
  final tenths = (ms / 100).round();
  final minutes = tenths ~/ 600;
  final seconds = (tenths % 600) ~/ 10;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.${tenths % 10}';
}
