import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';

/// History and Stacks as the UI shows them, read from and written to the
/// library database on the UI thread (each call takes well under a
/// millisecond at MVP sizes).
class CollectionsController extends ChangeNotifier {
  CollectionsController(this._store) {
    _reloadStacks();
  }

  final LibraryStore _store;
  List<StackInfo> _stacks = const [];

  /// Most History entries shown; older plays stay in the database.
  static const historyLimit = 2000;

  /// All Stacks in creation order, with their entry counts.
  List<StackInfo> get stacks => _stacks;

  /// Plays, newest first.
  List<HistoryEntry> history() => _store.history(limit: historyLimit);

  /// Entries of [stackId], top (newest) first.
  List<StackEntry> stackEntries(int stackId) => _store.stackEntries(stackId);

  /// Records that [track] started playing.
  void recordPlay(Track track) {
    _store.addPlay(track.id);
    notifyListeners();
  }

  /// Creates a Stack named [name] (trimmed); returns its id.
  int createStack(String name) {
    final id = _store.createStack(name.trim());
    _reloadStacks();
    notifyListeners();
    return id;
  }

  /// Puts [track] on top of [stackId]; it may already be on it lower down.
  void addToStack(int stackId, Track track) {
    _store.addToStack(stackId, track.id);
    _reloadStacks();
    notifyListeners();
  }

  /// Removes one entry from a Stack; other entries of the song stay.
  void removeStackEntry(int entryId) {
    _store.removeStackEntry(entryId);
    _reloadStacks();
    notifyListeners();
  }

  void _reloadStacks() => _stacks = _store.stacks();
}
