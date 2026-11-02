import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/search_text.dart';
import '../library/track.dart';

/// Typing on the song list jumps to a matching row, leaving the list whole;
/// the search box is what filters. [row] is the row jumped to.
///
/// Rows match when their title or artist starts with the text, and only if
/// there are none, when a word in them does. Every key scans all rows, so the
/// jump keeps nothing in memory between uses.
class TypeJump extends ChangeNotifier {
  TypeJump({required this._rows, required this._reveal});

  /// Quiet time after which the typed text is forgotten.
  static const resetAfter = Duration(seconds: 2);

  final List<Track> Function() _rows;
  final void Function(int row) _reveal;

  String _text = '';

  /// Matching rows for [text], in list order.
  List<int> _matches = const [];

  /// The row jumped to. Kept while the text has no match, so it comes back
  /// on Backspace.
  int? _anchor;
  Timer? _resetTimer;

  /// What was typed; empty once it has been forgotten.
  String get text => _text;

  /// Whether letters are being typed: next keys add to the [text].
  bool get isTyping => _text.isNotEmpty;

  /// The row jumped to, or null when there is none or the [text] has no
  /// match. It outlives the text, until [clear].
  int? get row => isTyping && _matches.isEmpty ? null : _anchor;

  /// How many rows match the [text].
  int get matchCount => _matches.length;

  /// Place of [row] among the matches, from 1; 0 without a match.
  int get matchNumber {
    final current = row;
    return current == null ? 0 : _matches.indexOf(current) + 1;
  }

  /// Adds [character] to the text and moves to the row it leads to.
  void type(String character) {
    // Fresh text starts from the first match, not from the old jump.
    if (!isTyping) _anchor = null;
    _text += character;
    _findMatches();
    _settle();
  }

  /// Takes back the last character; with nothing left, the jump ends.
  void backspace() {
    if (!isTyping) return;
    final characters = _text.runes.toList()..removeLast();
    if (characters.isEmpty) {
      clear();
      return;
    }
    _text = String.fromCharCodes(characters);
    _findMatches();
    _settle();
  }

  /// Moves to the next match, after the last going back to the first.
  void next() => _step(1);

  /// Moves to the previous match, before the first going to the last.
  void previous() => _step(-1);

  void _step(int by) {
    final current = row;
    if (current != null) {
      final count = _matches.length;
      _anchor = _matches[(_matches.indexOf(current) + by + count) % count];
    }
    _settle();
  }

  /// Outlines [row] with no text typed, for going to a song. The caller
  /// scrolls to it, since the row may belong to a list not laid out yet.
  void mark(int row) {
    _resetTimer?.cancel();
    _text = '';
    _matches = const [];
    _anchor = row;
    notifyListeners();
  }

  /// Forgets the text and the row.
  void clear() {
    _resetTimer?.cancel();
    if (!isTyping && _anchor == null) return;
    _text = '';
    _matches = const [];
    _anchor = null;
    notifyListeners();
  }

  /// Fills [_matches] for the text and picks the row: the same one if it
  /// still matches, else the next match after it. With no matches the row is
  /// left alone, so a Backspace gets back to it.
  void _findMatches() {
    _matches = _matchingRows(_text.trimRight());
    if (_matches.isEmpty) return;
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = _matches.first;
    } else if (!_matches.contains(anchor)) {
      _anchor = _matches.firstWhere(
        (match) => match > anchor,
        orElse: () => _matches.first,
      );
    }
  }

  List<int> _matchingRows(String text) {
    final wanted = normalizeForSearch(text);
    final rows = _rows();
    final starting = <int>[];
    final withWord = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final title = normalizeForSearch(rows[i].title);
      final artist = normalizeForSearch(rows[i].artist);
      if (title.startsWith(wanted) || artist.startsWith(wanted)) {
        starting.add(i);
      } else if (starting.isEmpty &&
          (hasWordStartingWith(title, wanted) ||
              hasWordStartingWith(artist, wanted))) {
        withWord.add(i);
      }
    }
    return starting.isEmpty ? withWord : starting;
  }

  /// After every key: shows the row and restarts the quiet time.
  void _settle() {
    final current = row;
    if (current != null) _reveal(current);
    _resetTimer?.cancel();
    _resetTimer = Timer(resetAfter, _forgetText);
    notifyListeners();
  }

  /// The quiet time is over: a found row stays outlined, text with no match
  /// leaves nothing behind.
  void _forgetText() {
    if (row == null) {
      clear();
      return;
    }
    _text = '';
    _matches = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }
}
