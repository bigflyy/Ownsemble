import '../media/audio_policy.dart';
import 'progress_budget.dart';

class ScanOutcome {
  final int count;
  final bool continueSweep;
  final String reason;
  final List<String> head;
  const ScanOutcome(
    this.count,
    this.continueSweep,
    this.reason, {
    this.head = const [],
  });
}

/// A bounded slice of a virtualized list. It never declares full coverage or
/// deletes records. The host keeps the current viewport for the next slice.
class LibraryScanner {
  final Future<List<Track>> Function() read;
  final Future<bool> Function(int milliseconds, bool retry) advance;
  final void Function(List<Track>) merge;
  final bool Function() cancelled;
  final void Function(int) progress;
  final Duration Function() elapsed;
  final Duration quietLimit, hardLimit;
  final bool newestOnly;
  final List<String> checkpoint;
  LibraryScanner({
    required this.read,
    required this.advance,
    required this.merge,
    required this.cancelled,
    required this.progress,
    required this.elapsed,
    this.quietLimit = const Duration(seconds: 45),
    this.hardLimit = const Duration(seconds: 90),
    this.newestOnly = false,
    this.checkpoint = const [],
  });
  Future<ScanOutcome> run() async {
    final budget = ProgressBudget(quietLimit: quietLimit, hardLimit: hardLimit);
    final seen = <String>{};
    final metadata = <String, (String, String, double)>{};
    ScanOutcome finish(bool more, String reason) =>
        ScanOutcome(seen.length, more, reason, head: seen.take(128).toList());
    var idle = 0, loading = true;
    for (var page = 0; page < (newestOnly ? 8 : 100); page++) {
      if (cancelled()) return finish(!newestOnly, 'yielded');
      final tracks = await read();
      final before = seen.length;
      final changed = <Track>[];
      for (final track in tracks) {
        if (newestOnly && !seen.contains(track.id) && seen.length >= 256) break;
        seen.add(track.id);
        final fields = (track.title, track.artist, track.duration);
        if (metadata[track.id] == fields) continue;
        metadata[track.id] = fields;
        changed.add(track);
      }
      if (changed.isNotEmpty) merge(changed);
      progress(seen.length);
      if (newestOnly && seen.isNotEmpty) {
        if (checkpoint.isEmpty && seen.length >= 12) {
          return finish(false, 'head_seeded');
        }
        if (checkpoint.isNotEmpty && _matchesCheckpoint(seen)) {
          return finish(false, 'known_head');
        }
        if (seen.length >= 256) return finish(false, 'head_budget');
      }
      idle = seen.length == before ? idle + 1 : 0;
      if (budget.expired(elapsed(), progress: seen.length, loading: loading)) {
        final hard = elapsed() >= hardLimit;
        if (newestOnly && checkpoint.isEmpty && seen.isNotEmpty && !hard) {
          return finish(false, 'head_seeded');
        }
        return finish(
          !newestOnly && hard,
          hard ? 'time_budget' : 'quiet_boundary',
        );
      }
      final remaining = (hardLimit - elapsed()).inMilliseconds;
      if (remaining <= 0) return finish(!newestOnly, 'time_budget');
      loading = await advance(
        (1000 * (1 << idle.clamp(0, 4))).clamp(
          1,
          remaining.clamp(1, newestOnly ? 3000 : 16000),
        ),
        idle > 0,
      );
    }
    return finish(!newestOnly, 'page_budget');
  }

  // One familiar ID is insufficient: removals/reorders must not manufacture
  // an overlap. Match a consecutive block in both observed and saved order.
  bool _matchesCheckpoint(Iterable<String> observed) {
    final positions = {
      for (var i = 0; i < checkpoint.length; i++) checkpoint[i]: i,
    };
    final required = checkpoint.length < 12 ? checkpoint.length : 12;
    var previous = -2, run = 0;
    for (final id in observed) {
      final position = positions[id];
      run = position != null ? (position == previous + 1 ? run + 1 : 1) : 0;
      previous = position ?? -2;
      if (run >= required) return true;
    }
    return false;
  }
}
