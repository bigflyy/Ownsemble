import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/services/playback_queue.dart';

void main() {
  test('queue starts at the selected duplicate occurrence', () {
    final q = PlaybackQueue()
      ..replace(const [
        QueueEntry('A', 1),
        QueueEntry('B', 2),
        QueueEntry('A', 3),
      ], 2);
    expect(q.current!.occurrence, 3);
    expect(q.previous()!.occurrence, 2);
    expect(q.next()!.occurrence, 3);
    expect(q.next(), isNull);
  });
  test('shuffle preserves every occurrence and the playing item', () {
    final q = PlaybackQueue()
      ..replace(List.generate(100, (i) => QueueEntry('A', i)), 42);
    q.setShuffle(true, random: Random(1));
    expect(q.current!.occurrence, 42);
    expect(q.order.toSet(), hasLength(100));
    expect(q.order.first, 42);
    q.setShuffle(false);
    expect(q.current!.occurrence, 42);
  });
  test('repeat-one applies to automatic completion, next still advances', () {
    final q = PlaybackQueue()
      ..replace(const [QueueEntry('A'), QueueEntry('B')], 0)
      ..repeat = QueueRepeat.one;
    expect(q.next(automatic: true)!.id, 'A');
    expect(q.next()!.id, 'B');
    q.repeat = QueueRepeat.all;
    expect(q.next()!.id, 'A');
  });
  test('saved shuffled order and cursor survive restart', () {
    final q = PlaybackQueue()
      ..replace(const [
        QueueEntry('A', 1),
        QueueEntry('A', 2),
        QueueEntry('B', 3),
      ], 1);
    q.setShuffle(true, random: Random(2));
    q.next();
    final restored = PlaybackQueue()..restore(q.toJson());
    expect(restored.toJson(), q.toJson());
  });
  test('malformed or out-of-range saved queue cannot select a track', () {
    for (final bad in [
      null,
      {
        'entries': [],
        'order': [1],
        'cursor': 0,
      },
      {
        'entries': [
          {'id': 'A'},
        ],
        'order': [2],
        'cursor': 0,
      },
    ]) {
      final q = PlaybackQueue()..restore(bad);
      expect(q.current, isNull);
    }
  });
}
