// Call with monotonic elapsed time. Loading/progress extends the quiet window,
// while the hard cap always wins, including a loader that never finishes.
class ProgressBudget {
  final Duration quietLimit, hardLimit;
  Duration _lastProgress = Duration.zero;
  Object? _previous;
  ProgressBudget({required this.quietLimit, required this.hardLimit});

  bool expired(Duration elapsed, {Object? progress, bool loading = false}) {
    if (elapsed >= hardLimit) return true;
    if (progress != _previous || loading) {
      _previous = progress;
      _lastProgress = elapsed;
    }
    return elapsed - _lastProgress >= quietLimit;
  }
}
