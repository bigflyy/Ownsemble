/// The user's own edit of a song's lyrics (plan 10 I2g): words and line
/// starts fixed by hand, from any lyrics (a source's, fitted ones, heard
/// words) or written from nothing.
///
/// An edit is kept per VK upload beside the sources' answers, never in
/// place of them: a source's refresh, VK's new lyrics or "Hear again" never
/// touch it, and the original stays one click away. The last
/// [lyricsEditsKept] saves are kept, so a save can be undone also after a
/// restart.
///
/// Lines are stored as typed: a line may have no start (added and not
/// timed yet) or a start earlier than the line above. [editForShow] turns
/// them into lines that follow the song: every line gets a start, in order,
/// and a line without a usable start of its own is passed over, so the line
/// above it stays lit. Only edits can have such lines (VK's and LRC lines
/// are all timed and sorted on reading), so [Lyrics.timed] keeps its
/// meaning everywhere else.
library;

import 'line_fit.dart' show isUnsungLine;
import 'lyrics.dart';

/// The source name of the user's edit wherever lyrics carry one (a pick,
/// an offset, a fit). It is never one of the sources the app asks.
const editedSource = 'edited';

/// How many saves of one upload's edit are kept for undo.
const lyricsEditsKept = 10;

/// The newest save of an upload's edit.
class LyricsEdit {
  const LyricsEdit({
    required this.lines,
    required this.basedOn,
    required this.savedAtMs,
    required this.saves,
  });

  /// The lines as typed: starts may be missing or out of order; no ends.
  final List<LyricLine> lines;

  /// The source the edit started from ('vk', 'lrclib', 'heard', ...), or
  /// null when it was written from nothing.
  final String? basedOn;

  final int savedAtMs;

  /// How many saves are kept, this one included: [saves] - 1 undo steps.
  final int saves;
}

/// Where edits are kept (LibraryStore).
abstract interface class LyricsEditStore {
  /// The newest save of the upload [ref]'s edit, or null for none.
  LyricsEdit? editOf(String ref);

  /// Keeps [lines] as the newest save of [ref]'s edit; older saves past
  /// [lyricsEditsKept] are dropped.
  void saveEdit(
    String ref,
    List<LyricLine> lines, {
    String? basedOn,
    required int atMs,
  });

  /// Drops the newest save: the one before shows, or none.
  void undoEdit(String ref);

  /// Drops every save of [ref]'s edit.
  void forgetEdit(String ref);
}

/// The lines an edit is stored as: text and start only. Show-only flags
/// and ends are left out (a line ends where the next one starts).
List<LyricLine> storableEditLines(List<LyricLine> lines) => [
  for (final line in lines) LyricLine(line.text, startMs: line.startMs),
];

/// [lines] of an edit as they show: when at least one sung line has a
/// start, every line gets an effective start, max(its own, the one above)
/// (lines above the first start take that start), and a line whose own
/// start is missing or earlier than the line above is marked
/// [LyricLine.passed]; an untimed header row ("[Chorus]") becomes a label
/// row instead. With no start on any sung line the words show plain.
Lyrics editForShow(List<LyricLine> lines) {
  final firstStart = [
    for (final line in lines)
      if (!line.isGap && line.startMs != null) line.startMs!,
  ].firstOrNull;
  if (firstStart == null) {
    return Lyrics(
      source: editedSource,
      lines: [for (final line in lines) LyricLine(line.text)],
    );
  }
  final shown = <LyricLine>[];
  var above = [
    for (final line in lines)
      if (line.startMs != null) line.startMs!,
  ].first;
  // Lines above the first start take it (a gap with an earlier start
  // keeps its own: it is in order).
  if (above > firstStart) above = firstStart;
  var before = true;
  for (final line in lines) {
    final own = line.startMs;
    final usable = own != null && (before || own >= above);
    final start = usable ? own : above;
    if (usable) before = false;
    final header = !usable && own == null && isUnsungLine(line.text);
    shown.add(
      LyricLine(
        line.text,
        startMs: start,
        label: header,
        passed: !usable && !header,
      ),
    );
    above = start;
  }
  return Lyrics(source: editedSource, lines: shown);
}
