import '../media/audio_policy.dart';

typedef RecentSource = ({Uri source, String userAgent, DateTime observed});

/// Temporary music links stay in memory only, indexed by exact provider ID.
/// Metadata scanning never downloads audio. Login loss clears all references.
class SourceMemory {
  final int capacity;
  final Duration lifetime;
  final DateTime Function() now;
  final _sources = <String, RecentSource>{};
  SourceMemory({
    this.capacity = 8192,
    this.lifetime = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  void remember(String id, Uri source, String userAgent) {
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(id) ||
        !audioCandidate(source) ||
        userAgent.length > 512 ||
        userAgent.contains(RegExp(r'[\r\n]'))) {
      return;
    }
    _sources.remove(id);
    _sources[id] = (source: source, userAgent: userAgent, observed: now());
    while (_sources.length > capacity) {
      _sources.remove(_sources.keys.first);
    }
  }

  RecentSource? lookup(String id) {
    final value = _sources[id];
    if (value == null) return null;
    final age = now().difference(value.observed);
    if (age.isNegative || age >= lifetime) {
      _sources.remove(id);
      return null;
    }
    return value;
  }

  void forget(String id) => _sources.remove(id);
  void clear() => _sources.clear();
}
