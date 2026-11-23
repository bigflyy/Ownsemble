/// Whether an outside source's song is the song played (plan 10, E1).
///
/// Outside sources are searched by artist and title, so their rows must be
/// matched back to the song: crowd rows differ in case, in yo/e, in tags
/// such as "(Remastered)" or "feat. X", sometimes swap artist and title, and
/// often spell Russian names in Latin letters ("Aquarium" for the Cyrillic
/// name). The A4 probe (session 37) found such rows with the same length, so
/// the names are also compared transliterated, and then the length must
/// agree more closely.
library;

/// How well a candidate's names agree with the song's.
enum NameMatch {
  /// The names differ.
  none,

  /// They agree only after transliteration and spelling folds.
  loose,

  /// They agree as written (case, yo/e, tags and punctuation aside).
  exact,
}

/// Lower case, yo -> e, bracket tags and "feat." parts dropped, letters and
/// digits only, single spaces.
String foldName(String text) {
  var folded = text.toLowerCase().replaceAll('ё', 'е');
  folded = folded.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
  folded = folded.replaceAll(RegExp(r'(^|\s)(feat|ft)\.?\s.*$'), ' ');
  folded = folded.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return folded.trim().replaceAll(RegExp(r'\s+'), ' ');
}

const _cyrillicToLatin = {
  'а': 'a',
  'б': 'b',
  'в': 'v',
  'г': 'g',
  'д': 'd',
  'е': 'e',
  'ж': 'zh',
  'з': 'z',
  'и': 'i',
  'й': 'i',
  'к': 'k',
  'л': 'l',
  'м': 'm',
  'н': 'n',
  'о': 'o',
  'п': 'p',
  'р': 'r',
  'с': 's',
  'т': 't',
  'у': 'u',
  'ф': 'f',
  'х': 'kh',
  'ц': 'ts',
  'ч': 'ch',
  'ш': 'sh',
  'щ': 'sh',
  'ъ': '',
  'ы': 'i',
  'ь': '',
  'э': 'e',
  'ю': 'iu',
  'я': 'ia',
  'і': 'i',
  'ї': 'i',
  'є': 'e',
  'ґ': 'g',
  'ў': 'u',
};

/// [foldName] in Latin letters with spelling differences folded away:
/// Cyrillic transliterated, then c/q -> k, w -> v, y/j -> i, x -> ks, h
/// dropped and doubled letters once. Only for comparing.
String looseName(String text) {
  final latin = StringBuffer();
  for (final rune in foldName(text).runes) {
    final char = String.fromCharCode(rune);
    latin.write(_cyrillicToLatin[char] ?? char);
  }
  var loose = latin
      .toString()
      .replaceAll(RegExp('[cq]'), 'k')
      .replaceAll('w', 'v')
      .replaceAll(RegExp('[yj]'), 'i')
      .replaceAll('x', 'ks')
      .replaceAll('h', '');
  loose = loose.replaceAllMapped(RegExp(r'(\p{L})\1+', unicode: true), (m) {
    return m.group(1)!;
  });
  return loose.trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// How alike two strings are: 1 when equal, 0 when nothing is shared (one
/// minus the edit distance over the longer length).
double similarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  final longer = a.length > b.length ? a.length : b.length;
  return 1 - previous[b.length] / longer;
}

/// Whether two names (already folded one way) are the same name: equal, or
/// one holds the other (the shorter at least 3 letters: "(Live)" dropped
/// leaves "title" inside "title live version"), or, when [fuzzy], at least
/// 80% alike.
bool _sameName(String a, String b, {required bool fuzzy}) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final shorter = a.length < b.length ? a : b;
  final longer = identical(shorter, a) ? b : a;
  if (shorter.length >= 3 && longer.contains(shorter)) return true;
  return fuzzy && similarity(a, b) >= 0.8;
}

/// Whether a candidate's artist names the song's artist: the same name, or
/// a shared word longer than 2 letters ("A, B" against "B").
bool _sameArtist(String song, String candidate, {required bool fuzzy}) {
  if (_sameName(song, candidate, fuzzy: fuzzy)) return true;
  final words = candidate.split(' ').toSet();
  return song.split(' ').any((word) => word.length > 2 && words.contains(word));
}

/// How well the candidate's [artist] and [title] name the song
/// ([songArtist], [songTitle]); artist and title are also tried swapped.
NameMatch matchNames({
  required String songArtist,
  required String songTitle,
  required String artist,
  required String title,
}) {
  bool agree(String Function(String) form, {required bool fuzzy}) {
    final a = form(songArtist), t = form(songTitle);
    final ca = form(artist), ct = form(title);
    return (_sameName(t, ct, fuzzy: fuzzy) &&
            _sameArtist(a, ca, fuzzy: fuzzy)) ||
        (_sameName(t, ca, fuzzy: fuzzy) && _sameArtist(a, ct, fuzzy: fuzzy));
  }

  if (agree(foldName, fuzzy: false)) return NameMatch.exact;
  if (agree(looseName, fuzzy: true)) return NameMatch.loose;
  return NameMatch.none;
}

/// Whether a candidate is close enough to show on its own: exact names and
/// a length within 5 s, or loose names within 3 s. A candidate without a
/// length is never taken (live and other versions differ by 3-60 s).
bool takeCandidate(NameMatch names, int? lengthDiffSeconds) {
  if (lengthDiffSeconds == null) return false;
  return switch (names) {
    NameMatch.exact => lengthDiffSeconds <= 5,
    NameMatch.loose => lengthDiffSeconds <= 3,
    NameMatch.none => false,
  };
}

/// A version tag left outside brackets: after a dash, slash, bar or colon
/// ("Song - Acoustic Version", "Song / Live"), or "live at / in / from ..."
/// ("Song live at Wembley"). A version word that ends the title itself is
/// no tag: "Let Me Live" is not another version of "Let Me" (Codex review).
final _versionTag = RegExp(
  r'\s+[-\u2013\u2014/|:]\s*(live|acoustic|unplugged|session|version|remix|'
  r'edit|концерт\p{L}*|акуст\p{L}*|живой|версия)(\s.*)?$|'
  r'\s+(live|концерт\p{L}*)\s+(at|in|from|on|в|на)\s.*$',
  caseSensitive: false,
  unicode: true,
);

/// [foldName] of [name] without a version tag outside brackets.
String _versionFold(String name) {
  final cut = name.replaceFirst(_versionTag, '').trim();
  return foldName(cut.isEmpty ? name : cut);
}

/// Whether a candidate not taken by [takeCandidate] may still be offered
/// as the lyrics of another version of the song (plan 10 G4a): the same
/// artist and title once case, tags in brackets and a trailing version tag
/// are dropped (stricter than [matchNames], which takes a title inside a
/// longer one and a shared artist word: "Home (Live)" is not "Homecoming"),
/// and both lengths known and more than 5 s apart (a live, acoustic or
/// edited upload). Its words show without timing until fitted.
bool otherVersionCandidate({
  required String songArtist,
  required String songTitle,
  required String artist,
  required String title,
  required int? lengthDiffSeconds,
}) {
  if (lengthDiffSeconds == null || lengthDiffSeconds <= 5) return false;
  final a = foldName(songArtist), t = _versionFold(songTitle);
  return a.isNotEmpty &&
      t.isNotEmpty &&
      a == foldName(artist) &&
      t == _versionFold(title);
}

/// Whether a text has Cyrillic letters, so a search in Latin letters may
/// find rows a search as written does not.
bool hasCyrillic(String text) => RegExp('[Ѐ-ӿ]').hasMatch(text);

/// [text] with Cyrillic letters transliterated (readable, for a search:
/// "й" -> "y", "х" -> "kh"), other characters kept.
String transliterate(String text) {
  const readable = {
    'й': 'y',
    'х': 'kh',
    'ы': 'y',
    'щ': 'shch',
    'ю': 'yu',
    'я': 'ya',
    'ё': 'yo',
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final lower = char.toLowerCase();
    final latin = readable[lower] ?? _cyrillicToLatin[lower];
    if (latin == null) {
      out.write(char);
    } else if (lower != char && latin.isNotEmpty) {
      out.write(latin[0].toUpperCase() + latin.substring(1));
    } else {
      out.write(latin);
    }
  }
  return out.toString();
}
