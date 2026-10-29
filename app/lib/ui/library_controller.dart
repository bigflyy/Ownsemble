import 'package:flutter/widgets.dart';

import '../library/search_index.dart';
import '../library/track.dart';

/// State of the library screen: all songs, the search text and what is shown.
class LibraryController extends ChangeNotifier {
  LibraryController(this._all) : _index = SearchIndex(_all), _visible = _all {
    searchText.addListener(_onSearchChanged);
  }

  SearchIndex _index;
  List<Track> _all;
  List<Track> _visible;
  String _appliedQuery = '';

  /// Time the last search itself took, for the benchmark.
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
    _visible = _index.search(query) ?? _all;
    lastQueryTime = clock.elapsed;
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  /// Shows a new version of the library (after a sync), keeping the search
  /// and the scroll position. [index] must be built from [tracks].
  void replaceTracks(List<Track> tracks, SearchIndex index) {
    _all = tracks;
    _index = index;
    _visible = _index.search(_appliedQuery) ?? _all;
    notifyListeners();
  }

  @override
  void dispose() {
    searchText.dispose();
    scroll.dispose();
    super.dispose();
  }
}
