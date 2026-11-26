// Plan 10 J8: which songs of a test library have word-timed lyrics on LRCLIB
// (LRC with <mm:ss.xx> stamps inside lines), asked the way the app asks.
// Prints the library position (1-based, in the library's own order), the
// line count and how many lines have word times; never names or words.
// Writes the matching library keys to OUT_KEYS (one per line, not printed).
//
//   dart run tool/word_lyrics_probe.dart DATA_DIR OUT_KEYS
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    print('usage: word_lyrics_probe.dart DATA_DIR OUT_KEYS');
    exit(2);
  }
  final store = LibraryStore.open(p.join(args[0], 'library.db'));
  final songs = [
    for (final track in store.loadAll())
      if (track.inLibrary) track,
  ];
  final lrclib = LrclibSource(httpGetJson());
  final keys = <String>[];
  var asked = 0, found = 0, timed = 0;
  for (final (i, track) in songs.indexed) {
    asked++;
    try {
      final candidate = await lrclib.find(
        SongNames(
          artist: track.artist,
          title: track.title,
          album: track.album,
          seconds: track.durationSec,
        ),
      );
      if (candidate == null) continue;
      found++;
      final lines = candidate.lyrics.lines;
      if (candidate.lyrics.timed) timed++;
      final worded = lines.where((line) => line.hasWordTimes).length;
      if (worded > 0) {
        keys.add(track.sourceKey ?? "");
        print(
          '#${i + 1}: ${lines.length} lines, $worded with word times, '
          'other version ${candidate.otherVersion}',
        );
      }
    } on Object catch (error) {
      print('#${i + 1}: error ${error.runtimeType}');
      // LRCLIB refuses a burst: wait before the next song.
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    // One song a second at most: the app asks one song at a time too.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
  }
  File(args[1]).writeAsStringSync(keys.join('\n'));
  print(
    'asked $asked, LRCLIB had $found, timed $timed, with word times '
    '${keys.length}',
  );
  store.close();
}
