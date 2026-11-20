// Rough timing of the artist index on generated songs (plan 09, C2):
// credits read from the store, the index built, the grid's sort. JIT run,
// so an upper bound; the release bench (C4, R13) is the real measure.
//
// Run from app/:  dart run tool/time_artist_index.dart [songs]
// ignore_for_file: avoid_print

import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_generator.dart';
import 'package:ownsemble/library/track.dart';

void main(List<String> args) {
  final count = args.isEmpty ? 10000 : int.parse(args.first);
  final store = LibraryStore.open(':memory:');
  final source = store.ensureSource(
    TrackSource.generated,
    account: 'generator',
    name: 'Generated songs',
  );
  store.upsertAll(source, generateSongs(count));
  final tracks = store.loadAll();
  for (var run = 0; run < 3; run++) {
    final clock = Stopwatch()..start();
    final credits = store.songArtistCredits();
    final read = clock.elapsedMicroseconds;
    final albums = store.listedVkAlbumKeys();
    final keys = clock.elapsedMicroseconds;
    final index = ArtistIndex.build(tracks, credits, albumKeys: albums);
    final built = clock.elapsedMicroseconds;
    final sorted = index.sorted(ArtistSort.mostSongs);
    final done = clock.elapsedMicroseconds;
    print(
      'run $run: ${tracks.length} songs, ${index.length} artists '
      '(${sorted.where((a) => a.nameOnly).length} name only): credits '
      '${read ~/ 1000} ms, album keys ${(keys - read) ~/ 1000} ms, build '
      '${(built - keys) ~/ 1000} ms, sort ${(done - built) ~/ 1000} ms, '
      'total ${done ~/ 1000} ms',
    );
  }
  store.close();
}
