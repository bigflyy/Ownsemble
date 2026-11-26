// Plan 10 J3b: reads an LRCLIB reply saved as JSON with lyricsFromLyricsfile
// and prints counts only (lines, lines with word times, words, words out of
// order), never words.
//
//   dart run tool/lyricsfile_check.dart REPLY_JSON
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyricsfile.dart';

void main(List<String> args) {
  final row = jsonDecode(File(args.single).readAsStringSync()) as Map;
  final lyrics = lyricsFromLyricsfile(
    'lrclib',
    row['lyricsfile'] as String?,
    songSeconds: (row['duration'] as num?)?.round(),
  );
  if (lyrics == null) {
    print('nothing read');
    return;
  }
  var words = 0, timed = 0, back = 0, withWords = 0;
  for (final line in lyrics.lines) {
    final times = line.words;
    if (times == null) continue;
    withWords++;
    words += times.length;
    var previous = -1;
    for (final time in times.whereType<WordTime>()) {
      timed++;
      if (time.startMs < previous || time.endMs < time.startMs) back++;
      previous = time.startMs;
    }
  }
  print(
    'lines ${lyrics.lines.length} (gaps '
    '${lyrics.lines.where((l) => l.isGap).length}), with word times '
    '$withWords, words $words, timed $timed, out of order $back, timed '
    '${lyrics.timed}',
  );
}
