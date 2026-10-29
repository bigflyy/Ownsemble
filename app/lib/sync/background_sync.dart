import 'dart:io';
import 'dart:isolate';

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
    this.result,
    this.error,
    this.library,
  });

  /// All sources with their song counts and last sync, as stored now.
  final List<SourceInfo> sources;

  /// What the sync changed; null when it failed.
  final VkSyncResult? result;

  /// Why the sync failed, fit for the status bar; null on success.
  final String? error;

  /// The new library when the sync changed it; null when nothing changed.
  final LoadedLibrary? library;
}

/// Runs one sync and reports progress; how the app starts a sync.
typedef SyncRunner = Future<SyncOutcome> Function(
  void Function(SyncProgress) onProgress,
);

/// Syncs the VK account of the session in [sessionPath] into the library at
/// [dbPath], in a background isolate with its own database connection, so
/// network waits, writes and reloading the library never block the UI.
Future<SyncOutcome> syncVkInBackground({
  required String dbPath,
  required String sessionPath,
  required void Function(SyncProgress) onProgress,
}) async {
  final progress = ReceivePort();
  progress.listen((message) => onProgress(message as SyncProgress));
  try {
    return await _runInIsolate(dbPath, sessionPath, progress.sendPort);
  } finally {
    progress.close();
  }
}

// A separate function so the isolate's closure captures only these three
// values (a closure sent to an isolate carries everything its scope captures).
Future<SyncOutcome> _runInIsolate(
  String dbPath,
  String sessionPath,
  SendPort progress,
) => Isolate.run(() => _syncVk(dbPath, sessionPath, progress));

/// The isolate's work: sync, then reload the library if it changed.
Future<SyncOutcome> _syncVk(
  String dbPath,
  String sessionPath,
  SendPort progress,
) async {
  final store = LibraryStore.open(dbPath);
  VkClient? vk;
  try {
    VkSyncResult? result;
    String? error;
    var reachedSource = false;
    try {
      progress.send(const SyncProgress(SyncStage.connecting));
      vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
      await vk.ensureToken();
      reachedSource = true;
      result = await syncVkSource(
        call: vk.call,
        userId: vk.userId,
        store: store,
        onProgress: progress.send,
      );
    } catch (failure) {
      error = describeSyncError(failure);
      // Without a token the account is unknown, so syncVkSource never ran;
      // the failure belongs to the VK sources the library already has.
      if (!reachedSource) {
        for (final source in store.sources()) {
          if (source.kind == TrackSource.vk) {
            store.recordSync(source.id, error: error);
          }
        }
      }
    }
    LoadedLibrary? library;
    if (result != null && result.changedLibrary) {
      final tracks = store.loadAll();
      library = LoadedLibrary(tracks, SearchIndex(tracks));
    }
    return SyncOutcome(
      sources: store.sources(),
      result: result,
      error: error,
      library: library,
    );
  } finally {
    vk?.close();
    store.close();
  }
}
