import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/standby_resource.dart';

void main() {
  test('warming is bounded to one resource and taking transfers it', () async {
    var created = 0, closed = 0;
    final standby = StandbyResource<int>(
      create: () => ++created,
      prepare: (_) async {},
      dispose: (_) async {
        closed++;
      },
    );
    standby.warm();
    standby.warm();
    await Future<void>.delayed(Duration.zero);
    expect(standby.isReady, isTrue);
    final taken = standby.take();
    expect(created, 1);
    expect(taken.value, 1);
    await standby.discard();
    expect(closed, 0);
    await taken.close();
    await taken.close();
    expect(closed, 1);
  });
  test(
    'pending preparation can be closed immediately by its new owner',
    () async {
      final gate = Completer<void>();
      var closed = false;
      final standby = StandbyResource<int>(
        create: () => 1,
        prepare: (_) => gate.future,
        dispose: (_) async {
          closed = true;
          gate.completeError(StateError('synthetic cancellation'));
        },
      );
      standby.warm();
      final taken = standby.take();
      final failure = expectLater(taken.ready, throwsStateError);
      await taken.close();
      await failure;
      expect(closed, isTrue);
    },
  );
  test(
    'discard cancels idle preparation and a failure does not poison retry',
    () async {
      var created = 0, closed = 0, failures = 0;
      final standby = StandbyResource<int>(
        create: () => ++created,
        prepare: (n) async {
          if (n == 1) throw StateError('synthetic failure');
        },
        dispose: (_) async {
          closed++;
        },
        failed: (_) {
          failures++;
        },
      );
      standby.warm();
      await Future<void>.delayed(Duration.zero);
      expect(failures, 1);
      expect(closed, 1);
      standby.warm();
      await Future<void>.delayed(Duration.zero);
      expect(standby.isReady, isTrue);
      await standby.discard();
      expect(closed, 2);
      expect(created, 2);
    },
  );
  test(
    'an unused ready document can be reused, cancelled, and remains bounded',
    () async {
      var created = 0;
      final closed = <int>[];
      final standby = StandbyResource<int>(
        create: () => ++created,
        prepare: (_) async {},
        dispose: (value) async {
          closed.add(value);
        },
      );
      final first = standby.take();
      await first.ready;
      await standby.returnUnused(first);
      expect(standby.isReady, isTrue);
      expect(identical(standby.take(), first), isTrue);
      expect(created, 1);
      standby.warm();
      await Future<void>.delayed(Duration.zero);
      await standby.returnUnused(first);
      expect(closed, [1]);
      await standby.discard();
      expect(closed, [1, 2]);
      await standby.returnUnused(first);
      expect(standby.isReady, isFalse);
    },
  );
}
