import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../library/library_store.dart';
import '../library/search_index.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_sync.dart';

/// The library read back after a sync changed it, with its search index
/// already built, so the UI only has to swap it in.
class LoadedLibrary {
  const LoadedLibrary(this.tracks, this.index);

  final List<Track> tracks;
  final SearchIndex index;
}

/// What a finished sync hands back to the UI.
class SyncOutcome {
  const SyncOutcome({
    required this.sources,
    this.results = const [],
    this.errors = const [],
    this.library,
  });

  /// All sources with their song counts and last sync, as stored now.
  final List<SourceInfo> sources;

  /// What the sync changed, per account that synced.
  final List<VkSyncResult> results;

  /// Why accounts failed, each fit for the status bar; empty on success.
  final List<String> errors;

  /// The new library when the sync changed it; null when nothing changed.
  final LoadedLibrary? library;

  /// This outcome without [library], to keep once the library was handed
  /// over: a kept copy would hold that version of the library in memory
  /// after the next one replaced it.
  SyncOutcome withoutLibrary() => library == null
      ? this
      : SyncOutcome(sources: sources, results: results, errors: errors);

  /// The first account's result, for a library with one account.
  VkSyncResult? get result => results.firstOrNull;

  /// The first failure, if any.
  String? get error => errors.firstOrNull;

  /// What the sync changed in [sourceId], if that account synced.
  VkSyncResult? resultOf(int sourceId) =>
      results.where((result) => result.sourceId == sourceId).firstOrNull;
}

/// Runs one sync and reports progress; how the app starts a sync.
typedef SyncRunner = Future<SyncOutcome> Function(
  void Function(SyncProgress) onProgress,
);

/// One VK session to sync: plain data, so it can go to the background isolate.
class VkSyncSession {
  const VkSyncSession(this.account, this.cookies);

  /// VK user id; null until VK says whose session this is.
  final String? account;
  final List<SessionCookie> cookies;
}

/// Syncs the VK accounts of [sessions] into the library at [dbPath], one after
/// another, in a background isolate with its own database connection, so
/// network waits, writes and reloading the library never block the UI. Then
/// merges the songs the accounts share. One account failing does not stop the
/// others.
Future<SyncOutcome> syncVkInBackground({
  required String dbPath,
  required List<VkSyncSession> sessions,
  required void Function(SyncProgress) onProgress,
}) async {
  final progress = ReceivePort();
  progress.listen((message) => onProgress(message as SyncProgress));
  try {
    return await _runInIsolate(dbPath, sessions, progress.sendPort);
  } finally {
    progress.close();
  }
}

// A separate function so the isolate's closure captures only these three
// values (a closure sent to an isolate carries everything its scope captures).
Future<SyncOutcome> _runInIsolate(
  String dbPath,
  List<VkSyncSession> sessions,
  SendPort progress,
) => Isolate.run(() => _syncAll(dbPath, sessions, progress));

/// The isolate's work: sync each account, merge, then reload if anything
/// changed.
Future<SyncOutcome> _syncAll(
  String dbPath,
  List<VkSyncSession> sessions,
  SendPort progress,
) async {
  final store = LibraryStore.open(dbPath);
  final clients = <VkClient>[];
  try {
    final results = <VkSyncResult>[];
    final errors = <String>[];
    for (final (index, session) in sessions.indexed) {
      void report(SyncProgress step) =>
          progress.send(step.inAccount(index, sessions.length));
      var reachedSource = false;
      try {
        report(const SyncProgress(SyncStage.connecting));
        // A sync runs in the background, so it may wait out a slow line: a
        // page of 200 songs can take well over 15 s at a few KB/s. Dropped
        // or stalled requests are sent again instead of failing the sync.
        final client = VkClient(
          session.cookies,
          requestTimeout: const Duration(minutes: 3),
          silenceTimeout: const Duration(seconds: 30),
        );
        clients.add(client);
        await retryTransient(client.ensureToken);
        reachedSource = true;
        results.add(
          await syncVkSource(
            call: retryingVkCall(client.call),
            userId: client.userId,
            store: store,
            onProgress: report,
          ),
        );
      } catch (failure) {
        final error = describeSyncError(failure);
        errors.add(error);
        // Without a token syncVkSource never ran, so the failure is noted on
        // the session's account, or on every VK source when it is not known.
        if (!reachedSource) {
          for (final source in store.sources()) {
            if (source.kind == TrackSource.vk &&
                (session.account == null ||
                    source.account == session.account)) {
              store.recordSync(source.id, error: error);
            }
          }
        }
      }
    }
    await _nameAccounts(store, clients);
    final merge = store.mergeSameSongs();
    _deleteUnused(store, merge.unusedFiles, p.dirname(dbPath));
    LoadedLibrary? library;
    if (merge.merged > 0 || results.any((result) => result.changedLibrary)) {
      final tracks = store.loadAll();
      library = LoadedLibrary(tracks, SearchIndex(tracks));
    }
    return SyncOutcome(
      sources: store.sources(),
      results: results,
      errors: errors,
      library: library,
    );
  } finally {
    for (final client in clients) {
      client.close();
    }
    store.close();
  }
}

/// With several accounts "VK" says nothing, so each that still has that name
/// gets the account's own name. A failure leaves it for the next sync.
Future<void> _nameAccounts(LibraryStore store, List<VkClient> clients) async {
  final accounts = store.sources().where((s) => s.kind == TrackSource.vk);
  if (accounts.length < 2) return;
  for (final client in clients) {
    final source = accounts
        .where((s) => s.account == '${client.userId}')
        .firstOrNull;
    if (source == null || source.name != vkDefaultSourceName) continue;
    try {
      final name = await fetchVkAccountName(client.call, client.userId);
      if (name == null) continue;
      store.nameSource(source.id, name, placeholder: vkDefaultSourceName);
    } catch (_) {
      // A name is a nicety: the sync itself went fine.
    }
  }
}

/// Deletes stored audio a merge left without a row. A file still open or
/// already gone is only wasted space, so failures are ignored.
void _deleteUnused(LibraryStore store, List<String> paths, String dataDir) {
  for (final path in paths) {
    if (store.audioPathUsers(path) > 0) continue;
    try {
      File(resolveAudioPath(dataDir, path)).deleteSync();
    } on FileSystemException {
      continue;
    }
  }
}
