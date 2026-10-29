import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../sync/background_sync.dart';
import '../vk/vk_sync.dart';

/// State of syncing for the status bar: which sources there are, whether a
/// sync runs and how far it is, and what the last one did.
class SyncController extends ChangeNotifier {
  SyncController({
    required this._sources,
    required this.runner,
    required this.onLibraryChanged,
  });

  /// Starts one sync; null when the app has no VK session to sync with.
  final SyncRunner? runner;

  /// Receives the new library after a sync changed it.
  final void Function(LoadedLibrary library) onLibraryChanged;

  List<SourceInfo> _sources;
  bool _running = false;
  SyncProgress? _progress;
  SyncOutcome? _lastOutcome;
  Future<SyncOutcome?>? _current;

  /// Sources that sync (VK accounts), with their counts and last sync.
  List<SourceInfo> get syncedSources =>
      _sources.where((source) => source.kind == TrackSource.vk).toList();

  bool get canSync => runner != null;
  bool get running => _running;

  /// Progress of the running sync, null when none runs.
  SyncProgress? get progress => _running ? _progress : null;

  /// How the last sync of this session ended; null before the first one.
  SyncOutcome? get lastOutcome => _lastOutcome;

  /// Completes when no sync runs, with the last sync's outcome.
  Future<SyncOutcome?> get idle =>
      _running ? _current! : Future.value(_lastOutcome);

  /// Starts a sync unless one is running (then returns that one).
  Future<SyncOutcome?> syncNow() {
    final runner = this.runner;
    if (runner == null) return Future.value();
    if (_running) return _current!;
    _running = true;
    return _current = _sync(runner);
  }

  Future<SyncOutcome?> _sync(SyncRunner runner) async {
    _progress = const SyncProgress(SyncStage.connecting);
    notifyListeners();
    try {
      final outcome = await runner((progress) {
        _progress = progress;
        notifyListeners();
      });
      _lastOutcome = outcome;
      _sources = outcome.sources;
      final library = outcome.library;
      if (library != null) onLibraryChanged(library);
      return outcome;
    } catch (error) {
      // The runner reports sync failures in its outcome; this is a bug in
      // the runner itself, still shown instead of a stuck progress line.
      _lastOutcome = SyncOutcome(sources: _sources, error: '$error');
      return _lastOutcome;
    } finally {
      _running = false;
      notifyListeners();
    }
  }
}
