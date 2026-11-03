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
    required this._runner,
    required this.onLibraryChanged,
  });

  /// Starts one sync; null when the app has no VK session to sync with.
  SyncRunner? get runner => _runner;
  set runner(SyncRunner? runner) {
    _runner = runner;
    notifyListeners();
  }

  SyncRunner? _runner;

  /// Receives the new library after a sync changed it.
  final void Function(LoadedLibrary library) onLibraryChanged;

  List<SourceInfo> _sources;
  bool _running = false;
  SyncProgress? _progress;
  SyncOutcome? _lastOutcome;
  Future<SyncOutcome?>? _current;
  bool _runAgain = false;

  /// All sources; notifies only when they change, unlike this controller,
  /// which also does at every step of a sync.
  ValueListenable<List<SourceInfo>> get sourceList => _sourceList;
  late final _sourceList = ValueNotifier(_sources);

  /// Sources that sync (VK accounts), with their counts and last sync.
  List<SourceInfo> get syncedSources =>
      _sources.where((source) => source.kind == TrackSource.vk).toList();

  bool get canSync => runner != null;
  bool get running => _running;

  /// Progress of the running sync, null when none runs.
  SyncProgress? get progress => _running ? _progress : null;

  /// How the last sync of this session ended; null before the first one.
  SyncOutcome? get lastOutcome => _lastOutcome;

  /// Whether VK no longer takes any session: nothing synced, and that is why.
  /// One expired account among working ones shows on that account instead.
  bool get loginExpired {
    final outcome = _lastOutcome;
    return outcome != null &&
        outcome.results.isEmpty &&
        outcome.errors.isNotEmpty &&
        outcome.errors.every((error) => error == vkLoginExpired);
  }

  /// Takes over [sources] after a change made outside a sync: a new name,
  /// color or a removed account.
  void updateSources(List<SourceInfo> sources) {
    _sources = _sourceList.value = sources;
    notifyListeners();
  }

  /// Completes when no sync runs, with the last sync's outcome.
  Future<SyncOutcome?> get idle =>
      _running ? _current! : Future.value(_lastOutcome);

  /// Syncs a change the running sync started too early to see, such as a new
  /// account: after it ends, or now if none runs.
  Future<SyncOutcome?> syncAfterRunning() {
    if (_running) _runAgain = true;
    return syncNow();
  }

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
      var outcome = await _runOnce(runner);
      while (true) {
        // A first sync shows the songs and leaves their album titles to a
        // second one, which only then costs the calls.
        final again =
            _runAgain ||
            outcome.results.any((result) => result.albumsSkipped > 0);
        final next = this.runner;
        if (!again || next == null) return outcome;
        _runAgain = false;
        outcome = await _runOnce(next);
      }
    } catch (error) {
      // The runner reports sync failures in its outcome; this is a bug in
      // the runner itself, still shown instead of a stuck progress line.
      _lastOutcome = SyncOutcome(sources: _sources, errors: ['$error']);
      return _lastOutcome;
    } finally {
      _runAgain = false;
      _running = false;
      notifyListeners();
    }
  }

  /// One run of [runner], with its outcome taken over.
  Future<SyncOutcome> _runOnce(SyncRunner runner) async {
    final outcome = await runner((progress) {
      _progress = progress;
      notifyListeners();
    });
    _lastOutcome = outcome;
    _sources = _sourceList.value = outcome.sources;
    final library = outcome.library;
    if (library != null) onLibraryChanged(library);
    return outcome;
  }
}
