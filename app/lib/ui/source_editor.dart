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
    _deleteUnused(store.removeSource(sourceId));
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    sync.updateSources(store.sources());
  }

  /// Whether songs of several accounts are also merged by the likely rule
  /// (Stage L); off by default.
  bool get mergeLikely => store.mergeLikely;

  /// Switches the likely rule and merges again at once from the stored
  /// prints of the files, with no network, once no sync is writing.
  Future<void> setMergeLikely(bool on) async {
    await sync.idle;
    store.writeSetting(LibraryStore.mergeLikelySetting, on ? 'on' : null);
    final merge = store.mergeSameSongs();
    _deleteUnused(merge.unusedFiles);
    if (!merge.changed) return;
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    sync.updateSources(store.sources());
  }

  /// Deletes stored audio that no row points at any more.
  void _deleteUnused(List<String> paths) {
    for (final path in paths) {
      if (store.audioPathUsers(path) > 0) continue;
      try {
        File(resolveAudioPath(dataDir, path)).deleteSync();
      } on FileSystemException {
        // Open or already gone: a leftover file is only wasted space.
      }
    }
  }
}
