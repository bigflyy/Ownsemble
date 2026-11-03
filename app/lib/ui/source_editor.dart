import 'dart:io';

import '../library/library_store.dart';
import '../library/search_index.dart';
import 'library_controller.dart';
import 'sync_controller.dart';

/// Changes to the library's sources that the user makes: a name, a color, or
/// removing an account. Each ends with the sync bar and the lists up to date.
class SourceEditor {
  SourceEditor({
    required this.store,
    required this.sync,
    required this.library,
    required this.dataDir,
  });

  final LibraryStore store;
  final SyncController sync;
  final LibraryController library;

  /// Folder that stored audio paths are relative to.
  final String dataDir;

  void rename(int sourceId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    store.renameSource(sourceId, trimmed);
    sync.updateSources(store.sources());
  }

  void setColor(int sourceId, int color) {
    store.setSourceColor(sourceId, color);
    sync.updateSources(store.sources());
  }

  /// Takes the account out of the library, once no sync is writing to it.
  /// See [LibraryStore.removeSource] for what stays. Nothing changes on VK.
  Future<void> remove(int sourceId) async {
    await sync.idle;
    for (final path in store.removeSource(sourceId)) {
      if (store.audioPathUsers(path) > 0) continue;
      try {
        File(resolveAudioPath(dataDir, path)).deleteSync();
      } on FileSystemException {
        // Open or already gone: a leftover file is only wasted space.
      }
    }
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    sync.updateSources(store.sources());
  }
}
