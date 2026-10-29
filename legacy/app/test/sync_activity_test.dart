import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/services/sync_activity.dart';

void main() {
  test('missing, malformed and interrupted results never restore an active spinner', () {
    for (final value in [
      null,
      'bad',
      {},
      {'phase': 'running'},
      {'phase': 'stopping'},
      {
        'phase': 'succeeded',
        'mode': 'head',
        'checked': -1,
        'added': 0,
        'finishedAt': '2026-01-01T00:00:00Z',
        'reason': 'known_head',
      },
    ]) {
      final activity = SyncActivity.restore(value);
      expect(activity.phase, 'idle');
      expect(activity.active, isFalse);
    }
  });

  test('successful newest checks do not attest a full listing', () {
    final head = SyncActivity.restore({
      'phase': 'succeeded',
      'mode': 'head',
      'checked': 12,
      'added': 1,
      'finishedAt': '2026-01-01T00:00:00Z',
      'reason': 'known_head',
    });
    expect(head.label, 'Newest entries checked');
    final falseFullWitness = SyncActivity.restore({
      ...head.toJson(),
      'mode': 'full',
    });
    expect(falseFullWitness.phase, 'partial');
    final full = SyncActivity.restore({
      ...head.toJson(),
      'mode': 'full',
      'reason': 'provider_end',
    });
    expect(full.label, 'Full scan complete');
  });

  test('result serialization excludes unknown/private content and arbitrary error text', () {
    final activity = SyncActivity.restore({
      'phase': 'failed',
      'mode': 'head',
      'checked': 0,
      'added': 0,
      'finishedAt': '2026-01-01T00:00:00Z',
      'reason': 'https://generated.invalid/private-source',
      'cookie': 'generated-private-marker',
    });
    expect(activity.reason, 'operation_failed');
    expect(activity.toJson().toString(), isNot(contains('generated')));
    expect(
      activity.toJson().keys,
      unorderedEquals([
        'phase',
        'mode',
        'checked',
        'added',
        'finishedAt',
        'reason',
      ]),
    );
  });
}
