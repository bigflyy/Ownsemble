// Remove from library (plan 06, C5): a song leaves the library and each
// account's VK library, its row slides out, and a note offers Undo for a few
// seconds, which puts it back on VK and in the library under the same row.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../playback/version_book.dart' show searchFailure;
import '../vk/vk_catalog.dart';
import '../vk/vk_client.dart';

/// One account's copy that a remove took out: what Undo puts back.
/// [wasGone]: VK no longer had it, so only the library changed.
typedef RemovedCopy = ({int sourceId, String sourceKey, bool wasGone});

/// What one remove did: the copies it took out (Undo puts them back) and
/// what the note at the bottom says.
class RemoveResult {
  const RemoveResult(this.track, this.removed, this.note);

  /// The listed song the remove was asked for.
  final Track track;
  final List<RemovedCopy> removed;
  final String note;

  /// Whether anything was removed, so Undo has something to put back.
  bool get canUndo => removed.isNotEmpty;
}

/// Removes songs from the library and from the accounts' VK libraries, and
/// puts them back on Undo. The song list reads [leaving] (rows sliding out)
/// and [flashing] (the row Undo just brought back).
class SongRemover extends ChangeNotifier {
  SongRemover({
    required this.store,
    required this._sources,
    required this.apiOfSource,
    required this.onLibraryChanged,
    this.onRestored,
    this.slideTime = const Duration(milliseconds: 250),
    this.flashTime = const Duration(milliseconds: 900),
    this.log,
  });

  final LibraryStore store;
  final ValueListenable<List<SourceInfo>> _sources;

  /// Calls VK as a source's account; null when it is not logged in.
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// Reloads the lists from [store] (main.dart: loadAll, the search index,
  /// the sources' counts).
  final void Function() onLibraryChanged;

  /// After an Undo put songs back on VK (main.dart: a sync after the
  /// running one, which may have read VK while the song was removed and
  /// would mark it gone).
  final void Function()? onRestored;

  /// How long a removed row takes to slide out: the list reloads (and the
  /// row is gone) no sooner than this after the click.
  final Duration slideTime;

  /// How long the row Undo brought back is marked.
  final Duration flashTime;

  /// One line to perf.log: counts and times only.
  final void Function(String line)? log;

  /// Library ids of the songs whose rows slide out while VK removes them.
  final leaving = <int>{};

  /// Library id of the song Undo just brought back; null when none.
  int? get flashing => _flashing;
  int? _flashing;
  Timer? _flashTimer;
  var _disposed = false;

  /// The accounts that hold [track] in the library now, in the order of
  /// [LibraryStore.holdersOf]: the account of the listed row first. Empty
  /// for a song Remove does not apply to (outside the library, generated).
  List<SourceInfo> accountsOf(Track track) {
    if (!track.inLibrary || track.source != TrackSource.vk) return const [];
    final byId = {for (final source in _sources.value) source.id: source};
    final seen = <int>{};
    return [
      for (final holder in store.holdersOf(track.id))
        if (seen.add(holder.sourceId)) ?byId[holder.sourceId],
    ];
  }

  String _nameOf(int sourceId) {
    for (final source in _sources.value) {
      if (source.id == sourceId) return source.name;
    }
    return 'VK';
  }

  /// Removes [track] from the library and from VK: from every account that
  /// holds it, or only from [onlySource]. A copy a sync found gone (VK no
  /// longer has it) leaves only the library, and its Undo only lists it
  /// again. An account that fails keeps its copy, and
  /// the note says why; when no account removed it, nothing changed.
  Future<RemoveResult> remove(Track track, {int? onlySource}) async {
    final holders = [
      for (final holder in store.holdersOf(track.id))
        if (onlySource == null || holder.sourceId == onlySource) holder,
    ];
    final title = '"${track.title}"';
    if (holders.isEmpty) return RemoveResult(track, const [], '');
    if (!leaving.add(track.id)) return RemoveResult(track, const [], '');
    notifyListeners();
    final clock = Stopwatch()..start();
    final removed = <RemovedCopy>[];
    final from = <String>[];
    final fromIds = <int>{};
    final refused = <String>[];
    for (final holder in holders) {
      final name = _nameOf(holder.sourceId);
      // A copy a sync found gone leaves only the library: VK answers
      // "removed" even for a song the account does not have (probe
      // 2026-11-16), so its answer says nothing, and a restore of it fails.
      if (!holder.gone) {
        final call = apiOfSource(holder.sourceId);
        if (call == null) {
          refused.add('$name: not logged in');
          continue;
        }
        try {
          if (!await deleteVkSong(call, holder.sourceKey)) {
            refused.add('$name: VK did not remove it');
            continue;
          }
        } catch (error) {
          refused.add('$name: ${searchFailure(error)}');
          continue;
        }
      }
      store.markRemoved(holder.sourceId, [holder.sourceKey]);
      removed.add((
        sourceId: holder.sourceId,
        sourceKey: holder.sourceKey,
        wasGone: holder.gone,
      ));
      if (fromIds.add(holder.sourceId)) from.add(name);
    }
    final vkMs = clock.elapsedMilliseconds;
    if (removed.isNotEmpty) {
      // The row finishes sliding out before the list drops it.
      final left = slideTime - clock.elapsed;
      if (left > Duration.zero) await Future<void>.delayed(left);
      if (!_disposed) onLibraryChanged();
    }
    leaving.remove(track.id);
    if (!_disposed) notifyListeners();
    log?.call(
      'remove: ${removed.length} of ${holders.length} copies, VK $vkMs ms, '
      'list ${clock.elapsedMilliseconds} ms',
    );
    final stays = [
      for (final source in accountsOf(track))
        if (!fromIds.contains(source.id)) source.name,
    ];
    final note = removed.isEmpty
        ? '$title not removed: ${refused.join('; ')}'
        : [
            'Removed $title from ${from.join(' and ')}',
            if (refused.isNotEmpty) 'Not removed: ${refused.join('; ')}',
            if (refused.isEmpty && stays.isNotEmpty)
              'It stays in ${stays.join(' and ')}',
          ].join('. ');
    return RemoveResult(track, removed, note);
  }

  /// Puts back what [result] removed: on VK (same key, same place) and in
  /// the library (same row, so its plays, Stacks and stored audio). Returns
  /// a note when some copy could not come back, else null.
  Future<String?> undo(RemoveResult result) async {
    final clock = Stopwatch()..start();
    var back = 0;
    final failed = <String>[];
    for (final copy in result.removed) {
      if (copy.wasGone) {
        if (store.unmarkRemoved(copy.sourceId, copy.sourceKey)) back++;
        continue;
      }
      final name = _nameOf(copy.sourceId);
      final call = apiOfSource(copy.sourceId);
      if (call == null) {
        failed.add('$name: not logged in');
        continue;
      }
      try {
        final song = await restoreVkSong(call, copy.sourceKey);
        store.restoreRemoved(copy.sourceId, song);
        back++;
      } catch (error) {
        failed.add('$name: ${searchFailure(error)}');
      }
    }
    if (_disposed) return null;
    if (back > 0) {
      onLibraryChanged();
      onRestored?.call();
      _flashing = result.track.id;
      _flashTimer?.cancel();
      _flashTimer = Timer(flashTime, () {
        _flashing = null;
        if (!_disposed) notifyListeners();
      });
      notifyListeners();
    }
    log?.call(
      'undo remove: $back of ${result.removed.length} copies in '
      '${clock.elapsedMilliseconds} ms',
    );
    if (failed.isEmpty) return null;
    final title = '"${result.track.title}"';
    return back == 0
        ? 'Could not bring back $title: ${failed.join('; ')}'
        : 'Brought back $title. Not brought back: ${failed.join('; ')}';
  }

  @override
  void dispose() {
    _disposed = true;
    _flashTimer?.cancel();
    super.dispose();
  }
}
