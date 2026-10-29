import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/progress_budget.dart';

void main() {
  ProgressBudget budget() => ProgressBudget(
    quietLimit: const Duration(seconds: 30),
    hardLimit: const Duration(seconds: 90),
  );
  test('slow arrivals reset the quiet window', () {
    final wait = budget();
    expect(wait.expired(Duration.zero, progress: 0), isFalse);
    expect(wait.expired(const Duration(seconds: 29), progress: 1), isFalse);
    expect(wait.expired(const Duration(seconds: 40), progress: 1), isFalse);
    expect(wait.expired(const Duration(seconds: 58), progress: 2), isFalse);
    expect(wait.expired(const Duration(seconds: 80), progress: 2), isFalse);
    expect(wait.expired(const Duration(seconds: 88), progress: 2), isTrue);
  });
  test('an active loader gets extra time but cannot bypass the hard cap', () {
    final wait = budget();
    expect(wait.expired(Duration.zero, loading: true), isFalse);
    expect(wait.expired(const Duration(seconds: 60), loading: true), isFalse);
    expect(wait.expired(const Duration(seconds: 89), loading: true), isFalse);
    expect(wait.expired(const Duration(seconds: 90), loading: true), isTrue);
  });
  test(
    'quiet stalled pages stop and a finished loader gets a grace window',
    () {
      final wait = budget();
      expect(wait.expired(Duration.zero, progress: 1), isFalse);
      expect(wait.expired(const Duration(seconds: 30), progress: 1), isTrue);
      final loading = budget();
      expect(loading.expired(Duration.zero, loading: true), isFalse);
      expect(
        loading.expired(const Duration(seconds: 50), loading: true),
        isFalse,
      );
      expect(loading.expired(const Duration(seconds: 79)), isFalse);
      expect(loading.expired(const Duration(seconds: 80)), isTrue);
    },
  );
}
