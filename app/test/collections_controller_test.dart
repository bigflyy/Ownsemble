import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/collections_controller.dart';

void main() {
  late LibraryStore store;
  late CollectionsController collections;
  late List<int> ids;
  late List<int?> told;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    ids = store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Кино',
        title: 'Кукушка',
        durationSec: 398,
        addedAt: 0,
      ),
    ]);
    collections = CollectionsController(store);
    told = [];
    collections.onPlaysChanged = told.add;
  });
  tearDown(() => store.close());

  // The user, 2026-11-08: "when i just played a song. it still says last
  // played never". Plays and Last played follow a play once it counts, not
  // only when it ends.
  test('a play is told once when it starts to count, and when it ends', () {
    final play = collections.beginPlay(
      ids[0],
      start: PlayStart.chosen,
      shuffle: false,
    );
    expect(told, [ids[0]]);
    // Half of 398 s is 199 s.
    collections.updatePlay(play, listenedMs: 5000);
    collections.updatePlay(play, listenedMs: 198000);
    expect(told, [ids[0]]);
    collections.updatePlay(play, listenedMs: 199000);
    expect(told, [ids[0], ids[0]]);
    collections.updatePlay(play, listenedMs: 204000);
    expect(told, [ids[0], ids[0]]);
    expect(store.songPlays()[ids[0]]!.plays, 1);
    collections.updatePlay(play, listenedMs: 210000, ended: PlayEnd.finished);
    expect(told, [ids[0], ids[0], ids[0]]);
  });
}
