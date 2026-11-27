import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../sync/background_sync.dart';
import '../sync/file_check.dart';
import '../vk/vk_sync.dart';

/// A VK account that logged in and whose first sync has not made it a
/// source yet. Shown at once, so a login is seen to have worked (user,
/// 2026-11-27: "it shows no visible effect when i add vk account ... it
/// needs to show it is loading the account immediately").
class NewAccount {
  const NewAccount({
    required this.account,
    this.progress,
    this.waiting = false,
    this.error,
  });

  /// VK user id.
  final String account;

  /// How far its first sync is; null while it waits or after it failed.
  final SyncProgress? progress;

  /// Whether it waits for a sync of the other accounts to end.
  final bool waiting;

  /// Why its first sync failed; null while it runs or waits.
  final String? error;

  /// What the status bar and the accounts list say about it.
  String get state {
    final error = this.error;
    if (error != null) return 'first sync failed: $error';
    final progress = this.progress;
    if (progress == null) {
      return waiting ? 'adding, after the sync that runs' : 'adding...';
    }
    final percent = (progress.fraction * 100).round();
    return switch (progress.stage) {
      SyncStage.connecting => 'adding: connecting to VK',
      SyncStage.reading => 'adding: reading its songs, $percent%',
      _ => 'adding: saving its songs, $percent%',
    };
  }
}

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
  Completer<void>? _stopCheck;

  /// Accounts that logged in and wait for their first sync, oldest first,
  /// each with the sync of that account alone.
  final _waiting = <String, SyncRunner>{};

  /// The account whose first sync runs now.
  String? _addingNow;

  /// Why an added account's first sync failed, by account.
  final _addFailed = <String, String>{};

  /// All sources; notifies only when they change, unlike this controller,
  /// which also does at every step of a sync.
  ValueListenable<List<SourceInfo>> get sourceList => _sourceList;
  late final _sourceList = ValueNotifier(_sources);

  /// Sources that sync (VK accounts), with their counts and last sync.
  List<SourceInfo> get syncedSources =>
      _sources.where((source) => source.kind == TrackSource.vk).toList();

  bool _isSource(String account) => _sources.any(
    (source) => source.kind == TrackSource.vk && source.account == account,
  );

  /// Accounts logged in whose songs are not in the library yet: the one
  /// whose first sync runs, those waiting for theirs, and those it failed.
  List<NewAccount> get newAccounts => [
    if (_addingNow case final account? when _stillLoggedIn(account))
      NewAccount(account: account, progress: syncing ? _progress : null),
    for (final account in _waiting.keys)
      if (account != _addingNow && !_isSource(account))
        NewAccount(account: account, waiting: _running),
    for (final MapEntry(key: account, value: error) in _addFailed.entries)
      if (!_waiting.containsKey(account) && !_isSource(account))
        NewAccount(account: account, error: error),
  ];

  /// Whether the running sync is a new account's first, which leaves the
  /// other accounts as they are.
  bool get addingAccount => syncing && _addingNow != null;

  /// Whether [account] is the new account whose first sync runs: its source
  /// may exist already (it is made before VK lists the songs), and is shown
  /// as the new account's row until that sync ends.
  bool isBeingAdded(String? account) =>
      account != null && account == _addingNow;

  /// The accounts logged in, as the app last said; null before it did.
  Set<String>? _loggedIn;

  bool _stillLoggedIn(String account) => _loggedIn?.contains(account) ?? true;

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

  /// Syncs [account], logged in a moment ago, with [alone], a sync of that
  /// account only: before the other accounts, so its songs show as soon as
  /// VK has listed them. A file check that runs stops for it; a sync that
  /// runs ends first. All accounts sync after it, which merges the songs
  /// they share and reads the album titles. An account already in the
  /// library (a login again) syncs like a login always did.
  Future<SyncOutcome?> addAccount(String account, SyncRunner alone) {
    if (_isSource(account)) return syncAfterRunning();
    _addFailed.remove(account);
    _waiting[account] = alone;
    notifyListeners();
    if (_running) {
      _runAgain = true;
      _stopCheck?.complete();
      _stopCheck = null;
      return _current!;
    }
    _running = true;
    _synced = Completer<SyncOutcome?>();
    return _current = _sync(null);
  }

  /// Forgets the new accounts that are no longer logged in: a login undone
  /// before its first sync.
  void keepNewAccounts(Set<String> loggedIn) {
    _loggedIn = loggedIn;
    final before = _waiting.length + _addFailed.length;
    _waiting.removeWhere((account, _) => !loggedIn.contains(account));
    _addFailed.removeWhere((account, _) => !loggedIn.contains(account));
    if (_waiting.length + _addFailed.length != before) notifyListeners();
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

  /// Runs the first sync of the oldest waiting new account; null when none
  /// waits.
  Future<SyncOutcome>? _addNext() {
    final account = _waiting.keys.firstOrNull;
    if (account == null) return null;
    return _runOnce(_waiting[account]!, adding: account);
  }

  /// Runs [runner], or a new account's first sync when [runner] is null,
  /// then whatever must follow.
  Future<SyncOutcome?> _sync(SyncRunner? runner) async {
    _progress = const SyncProgress(SyncStage.connecting);
    notifyListeners();
    try {
      var next = runner;
      while (true) {
        var outcome = await (next == null ? _addNext()! : _runOnce(next));
        while (true) {
          final added = _addNext();
          if (added != null) {
            outcome = await added;
            continue;
          }
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
        if (_waiting.isNotEmpty) {
          next = null;
        } else if (!_runAgain || following == null) {
          return outcome;
        } else {
          next = following;
        }
        _runAgain = false;
        _synced = Completer<SyncOutcome?>();
      }
    } catch (error) {
      // The runner reports sync failures in its outcome; this is a bug in
      // the runner itself, still shown instead of a stuck progress line.
      _lastOutcome = SyncOutcome(sources: _sources, errors: ['$error']);
      _finishSynced(_lastOutcome);
      // Accounts still waiting for their first sync say why it did not
      // come; Sync now tries them with the others.
      for (final account in _waiting.keys) {
        _addFailed[account] = '$error';
      }
      _waiting.clear();
      return _lastOutcome;
    } finally {
      _runAgain = false;
      _running = false;
      _checking = null;
      _synced = null;
      _addingNow = null;
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
    // A new account that logged in meanwhile is not kept waiting.
    if (_waiting.isNotEmpty) return;
    _checking = const FileCheckProgress(done: 0, total: 0);
    final stop = _stopCheck = Completer<void>();
    notifyListeners();
    try {
      final outcome = _lastCheck = await checker((progress) {
        _checking = progress;
        notifyListeners();
      }, stop.future);
      onFilesChecked?.call(outcome);
    } on Object {
      return;
    } finally {
      if (identical(_stopCheck, stop)) _stopCheck = null;
      _checking = null;
      notifyListeners();
    }
  }

  /// One run of [runner], with its outcome taken over. The outcome kept and
  /// returned no longer holds the new library: [onLibraryChanged] has it.
  /// With [adding], it is that new account's first sync: all accounts sync
  /// after it.
  Future<SyncOutcome> _runOnce(SyncRunner runner, {String? adding}) async {
    _addingNow = adding;
    _progress = const SyncProgress(SyncStage.connecting);
    notifyListeners();
    final SyncOutcome outcome;
    try {
      outcome = await runner((progress) {
        _progress = progress;
        notifyListeners();
      });
    } catch (error) {
      if (adding != null && _stillLoggedIn(adding)) {
        _addFailed[adding] = '$error';
      }
      rethrow;
    } finally {
      if (adding != null) {
        _waiting.remove(adding);
        _runAgain = true;
      }
      _addingNow = null;
    }
    final kept = _lastOutcome = outcome.withoutLibrary();
    _sources = _sourceList.value = outcome.sources;
    // A login undone meanwhile leaves no row behind (review 6).
    if (adding != null && !_isSource(adding) && _stillLoggedIn(adding)) {
      _addFailed[adding] = outcome.error ?? 'VK listed no songs';
    }
    final library = outcome.library;
    if (library != null) onLibraryChanged(library);
    return kept;
  }
}
