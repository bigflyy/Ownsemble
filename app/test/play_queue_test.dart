import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/play_queue.dart';

List<Track> songs(int count) => [
  for (var i = 0; i < count; i++)
    Track(
      id: i,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Исполнитель',
      title: 'Песня $i',
      durationSec: 200,
    ),
];

List<int?> ids(Iterable<Track?> tracks) => [for (final t in tracks) t?.id];

void main() {
  late PlayQueue queue;
  setUp(() => queue = PlayQueue(random: Random(7)));

  test('next walks the list the song was started from', () {
    final list = songs(4);
    expect(queue.start(list, 1).id, 1);
    expect(ids([queue.next(auto: true), queue.next(auto: true)]), [2, 3]);
    expect(queue.next(auto: true), isNull, reason: 'repeat off stops');
    expect(queue.current?.id, 3);
  });

  test('a manual next at the end wraps, an automatic one stops', () {
    queue.start(songs(3), 2);
    expect(queue.next(auto: true), isNull);
    expect(queue.next(auto: false)?.id, 0);
  });

  test('repeat list starts over; repeat one replays only on its own', () {
    queue.start(songs(2), 1);
    queue.repeat = Repeat.list;
    expect(queue.next(auto: true)?.id, 0);
    queue.repeat = Repeat.one;
    expect(queue.next(auto: true)?.id, 0, reason: 'same song again');
    expect(queue.next(auto: false)?.id, 1, reason: 'Next still moves on');
  });

  test('repeat cycles off, list, one, off', () {
    expect(
      [queue.cycleRepeat(), queue.cycleRepeat(), queue.cycleRepeat()],
      [Repeat.list, Repeat.one, Repeat.off],
    );
  });

  test('previous restarts after 3 s, else goes back and wraps', () {
    queue.start(songs(3), 1);
    expect(queue.previous(const Duration(seconds: 4)), isNull);
    expect(queue.current?.id, 1);
    expect(queue.previous(const Duration(milliseconds: 2900))?.id, 0);
    expect(queue.previous(Duration.zero)?.id, 2, reason: 'wraps');
    expect(queue.previous(const Duration(seconds: 3))?.id, 1);
  });

  test('the play list is a snapshot of the list at the click', () {
    final list = songs(3);
    queue.start(list, 0);
    list.removeAt(1);
    expect(queue.next(auto: true)?.id, 1);
  });

  test('shuffle plays every song once per round, current first', () {
    final list = songs(20);
    queue.shuffle = true;
    queue.start(list, 5);
    final round = [5];
    for (var i = 0; i < 19; i++) {
      round.add(queue.next(auto: true)!.id);
    }
    expect(round.toSet(), hasLength(20));
    expect(round, isNot(orderedEquals(List.generate(20, (i) => i))));
    expect(queue.next(auto: true), isNull, reason: 'repeat off ends it');

    queue.repeat = Repeat.list;
    final last = queue.current!.id;
    final second = [for (var i = 0; i < 20; i++) queue.next(auto: true)!.id];
    expect(second.toSet(), hasLength(20));
    expect(second.first, isNot(last), reason: 'no song twice in a row');
  });

  test('previous with shuffle goes back along the shuffled order', () {
    queue.shuffle = true;
    queue.start(songs(10), 0);
    final a = queue.next(auto: true)!;
    final b = queue.next(auto: true)!;
    expect(b.id, isNot(a.id));
    expect(queue.previous(Duration.zero)?.id, a.id);
    expect(queue.previous(Duration.zero)?.id, 0);
  });

  test('turning shuffle off continues in list order from the current song', () {
    queue.start(songs(10), 0);
    queue.shuffle = true;
    final now = queue.next(auto: true)!;
    queue.shuffle = false;
    expect(queue.current?.id, now.id);
    expect(queue.next(auto: true)?.id, now.id + 1 < 10 ? now.id + 1 : null);
  });

  test('a one-song list with repeat list plays it again', () {
    queue.shuffle = true;
    queue.repeat = Repeat.list;
    queue.start(songs(1), 0);
    expect(queue.next(auto: true)?.id, 0);
    expect(queue.previous(Duration.zero)?.id, 0);
  });

  test('nothing started: no next, no previous', () {
    expect(queue.current, isNull);
    expect(queue.next(auto: false), isNull);
    expect(queue.previous(Duration.zero), isNull);
  });
}
