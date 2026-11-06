import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../sync/background_sync.dart';
import '../sync/file_check.dart';
import '../vk/vk_sync.dart';

/// State of syncing for the status bar: which sources there are, whether a
/// sync runs and how far it is, and what the last one did.
class SyncController extends ChangeNotifier {
  SyncController({
    required this._sources,
    required this._runner,
    required this.onLibraryChanged,
    this.checker,
    this.onFilesChecked,
  });

  /// Starts one sync; null when the app has no VK session to sync with.
  SyncRunner? get runner => _runner;
  set runner(SyncRunner? runner) {
    _runner = runner;
    notifyListeners();
  }

  SyncRunner? _runner;

  /// Checks every song's VK file after each sync (Stage M2); null without
  /// a VK session.
  FileCheckRunner? checker;

  /// Receives what each file check did, so the app can take over the
  /// version choices it stored.
  final void Function(FileCheckOutcome outcome)? onFilesChecked;

  /// Receives the new library after a sync changed it.
  final void Function(LoadedLibrary library) onLibraryChanged;

  List<SourceInfo> _sources;
  bool _running = false;
  SyncProgress? _progress;
  SyncOutcome? _lastOutcome;
  Future<SyncOutcome?>? _current;
  Completer<SyncOutcome?>? _synced;
  bool _runAgain = false;
  FileCheckProgress? _checking;
  FileCheckOutcome? _lastCheck;

  /// All sources; notifies only when they change, unlike this controller,
  /// which also does at every step of a sync.
  ValueListenable<List<SourceInfo>> get sourceList => _sourceList;
  late final _sourceList = ValueNotifier(_sources);

  /// Sources that sync (VK accounts), with their counts and last sync.
  List<SourceInfo> get syncedSources =>
      _sources.where((source) => source.kind == TrackSource.vk).toList();

  bool get canSync => runner != null;

  /// Whether a sync or the file check after it runs: Sync now waits.
  bool get running => _running;

  /// Whether a sync itself runs, not only the file check after it.
  bool get syncing => _running && _checking == null;

  /// Progress of the running sync, null when none runs or only the file
  /// check does.
  SyncProgress? get progress => syncing ? _progress : null;

  /// Progress of the file check after a sync, null when none runs.
  FileCheckProgress? get checking => _running ? _checking : null;

  /// What the last file check of this session did; null before the first.
  FileCheckOutcome? get lastCheck => _lastCheck;

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

  /// Completes when no sync and no file check runs, with the last sync's
  /// outcome.
  Future<SyncOutcome?> get idle =>
      _running ? _current! : Future.value(_lastOutcome);

  /// Completes when the running sync has handed over its library, before
  /// the file check after it; at once when none runs.
  Future<SyncOutcome?> get synced =>
      _synced?.future ?? Future.value(_lastOutcome);

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
    _synced = Completer<SyncOutcome?>();
    return _current = _sync(runner);
  }

  Future<SyncOutcome?> _sync(SyncRunner runner) async {
    _progress = const SyncProgress(SyncStage.connecting);
    notifyListeners();
    try {
      var next = runner;
      while (true) {
        var outcome = await _runOnce(next);
        while (true) {
          // A first sync shows the songs and leaves their album titles to
          // a second one, which only then costs the calls.
          final again =
              _runAgain ||
              outcome.results.any((result) => result.albumsSkipped > 0);
          final following = this.runner;
          if (!again || following == null) break;
          _runAgain = false;
          outcome = await _runOnce(following);
        }
        _finishSynced(outcome);
        await _checkFiles();
        // A login during the check is synced now.
        final following = this.runner;
        if (!_runAgain || following == null) return outcome;
        _runAgain = false;
        _progress = const SyncProgress(SyncStage.connecting);
        next = following;
      }
    } catch (error) {
      // The runner reports sync failures in its outcome; this is a bug in
      // the runner itself, still shown instead of a stuck progress line.
      _lastOutcome = SyncOutcome(sources: _sources, errors: ['$error']);
      _finishSynced(_lastOutcome);
      return _lastOutcome;
    } finally {
      _runAgain = false;
      _running = false;
      _checking = null;
      _synced = null;
      notifyListeners();
    }
  }

  void _finishSynced(SyncOutcome? outcome) {
    final synced = _synced;
    if (synced != null && !synced.isCompleted) synced.complete(outcome);
  }

  /// Runs [checker] after a sync. Its failures only mean the next sync
  /// checks the files it did not reach.
  Future<void> _checkFiles() async {
    final checker = this.checker;
    if (checker == null) return;
    _checking = const FileCheckProgress(done: 0, total: 0);
    notifyListeners();
    try {
      final outcome = _lastCheck = await checker((progress) {
        _checking = progress;
        notifyListeners();
      });
      onFilesChecked?.call(outcome);
    } on Object {
      return;
    } finally {
      _checking = null;
      notifyListeners();
    }
  }

  /// One run of [runner], with its outcome taken over. The outcome kept and
  /// returned no longer holds the new library: [onLibraryChanged] has it.
  Future<SyncOutcome> _runOnce(SyncRunner runner) async {
    final outcome = await runner((progress) {
      _progress = progress;
      notifyListeners();
    });
    final kept = _lastOutcome = outcome.withoutLibrary();
    _sources = _sourceList.value = outcome.sources;
    final library = outcome.library;
    if (library != null) onLibraryChanged(library);
    return kept;
  }
}
