import 'package:flutter/widgets.dart';

import '../library/library_store.dart';
import '../library/track.dart';

/// State of the library screen: all songs, the search text and what is shown.
class LibraryController extends ChangeNotifier {
  LibraryController(this._store, this._all) : _visible = _all {
    searchText.addListener(_onSearchChanged);
  }

  final LibraryStore _store;
  final List<Track> _all;
  List<Track> _visible;
  String _appliedQuery = '';

  /// Time the last search took in the database, for the benchmark.
  Duration lastQueryTime = Duration.zero;

  final searchText = TextEditingController();
  final scroll = ScrollController();

  List<Track> get all => _all;

  /// Songs matching the search, in library order (newest first).
  List<Track> get visible => _visible;

  void _onSearchChanged() {
    final query = searchText.text;
    if (query == _appliedQuery) return;
    _appliedQuery = query;
    final clock = Stopwatch()..start();
    final ids = _store.search(query);
    _visible = ids == null
        ? _all
        : [
            for (final track in _all)
              if (ids.contains(track.id)) track,
          ];
    lastQueryTime = clock.elapsed;
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  /// The song after [track] in the visible list, for auto-advance.
  Track? nextAfter(Track track) {
    final index = _visible.indexWhere((t) => t.id == track.id);
    if (index < 0 || index + 1 >= _visible.length) return null;
    return _visible[index + 1];
  }

  @override
  void dispose() {
    searchText.dispose();
    scroll.dispose();
    super.dispose();
  }
}
