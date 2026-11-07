import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';

/// History and Stacks as the UI shows them, read from and written to the
/// library database on the UI thread (each call takes well under a
/// millisecond at MVP sizes).
class CollectionsController extends ChangeNotifier implements PlayLog {
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

  /// Records that [track] started playing, with no details.
  void recordPlay(Track track) {
    _store.addPlay(track.id);
    notifyListeners();
    onPlaysChanged?.call(track.id);
  }

  /// Told which song's play counts may have changed: a play of it began,
  /// started to count, or ended (null: a song not known here). The song
  /// list's and Stats' numbers follow; other heard time written while a
  /// song plays is not told.
  void Function(int? trackId)? onPlaysChanged;

  /// Song of each play that has not ended yet, by play id.
  final _openPlays = <int, int>{};

  /// Open plays already told as counted.
  final _countedPlays = <int>{};

  @override
  int beginPlay(
    int trackId, {
    required PlayStart start,
    required bool shuffle,
  }) {
    final id = _store.beginPlay(trackId, start: start, shuffle: shuffle);
    _openPlays[id] = trackId;
    notifyListeners();
    onPlaysChanged?.call(trackId);
    return id;
  }

  /// History shows no heard time, so only [onPlaysChanged] is told: once
  /// when the play passes the counting line (half the song or 4 minutes),
  /// so Plays and Last played show it while it still plays (the user,
  /// 2026-11-08: "when i just played a song. it still says last played
  /// never"), and when it ends.
  @override
  void updatePlay(int playId, {required int listenedMs, PlayEnd? ended}) {
    _store.updatePlay(playId, listenedMs: listenedMs, ended: ended);
    if (ended != null) {
      _countedPlays.remove(playId);
      onPlaysChanged?.call(_openPlays.remove(playId));
      return;
    }
    final trackId = _openPlays[playId];
    if (trackId == null || _countedPlays.contains(playId)) return;
    if (!_store.playCounts(playId)) return;
    _countedPlays.add(playId);
    onPlaysChanged?.call(trackId);
  }

  /// The play a restarted app may go on with is remembered as open.
  @override
  HistoryEntry? lastPlay() {
    final last = _store.lastPlay();
    if (last != null) _openPlays[last.id] = last.trackId;
    return last;
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
