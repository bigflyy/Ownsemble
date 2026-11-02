import 'package:flutter/widgets.dart';

import '../library/search_index.dart';
import '../library/track.dart';
import '../storage/audio_storage.dart';
import 'collections_controller.dart';
import 'place_history.dart';
import 'type_jump.dart';

/// Height of one song row; fixed so the list can skip layout of hidden rows.
const rowHeight = 58.0;

/// The views of the sidebar. Artists, Playlists and Charts are planned
/// after the MVP and show a "later" page.
///
/// Downloads holds the songs kept for good; stored holds everything that
/// plays without the network, cached songs too ("On this computer").
enum ViewKind {
  songs,
  artists,
  downloads,
  stored,
  stack,
  playlists,
  history,
  charts,
}

/// One view: its kind and, for a Stack, which one.
@immutable
class LibraryView {
  const LibraryView(this.kind, {this.stackId});

  static const songs = LibraryView(ViewKind.songs);

  final ViewKind kind;
  final int? stackId;

  /// Whether this view is a page planned for later, without songs yet.
  bool get isLater => switch (kind) {
    ViewKind.artists || ViewKind.playlists || ViewKind.charts => true,
    _ => false,
  };

  /// Whether a song can appear more than once (History, Stacks).
  bool get hasEntries => kind == ViewKind.history || kind == ViewKind.stack;

  /// Whether the songs of this view depend on what is stored.
  bool get listsStorage =>
      kind == ViewKind.downloads || kind == ViewKind.stored;

  @override
  bool operator ==(Object other) =>
      other is LibraryView && other.kind == kind && other.stackId == stackId;

  @override
  int get hashCode => Object.hash(kind, stackId);
}

/// State of the song list: all songs, the view chosen in the sidebar, the
/// search text and what is shown.
///
/// Songs searches the whole library through the index. Other views list
/// their own songs (stored songs, History plays, Stack entries) and the search
/// keeps those that match, in the view's order; History and Stacks may list
/// a song more than once.
class LibraryController extends ChangeNotifier {
  LibraryController(
    this._all, {
    this.collections,
    this.storage,
    String? Function(String key)? readSetting,
    this._writeSetting,
  }) : _index = SearchIndex(_all),
       _visible = _all {
    _byId = {for (final track in _all) track.id: track};
    _playedFrom = _decodePlayedFrom(readSetting?.call(playedFromSetting));
    searchText.addListener(_onSearchChanged);
    collections?.addListener(_onSourceChanged);
    storage?.addListener(_onStorageChanged);
    final saved = _decodeView(readSetting?.call(viewSetting));
    if (saved != null) {
      _view = saved;
      _rebuildBase();
      _applySearch();
    }
  }

  /// Setting with the view shown when the app closed.
  static const viewSetting = 'ui.view';

  /// Setting with the list the playing song was started from: its view and,
  /// on the next line, its search text.
  static const playedFromSetting = 'ui.played_from';

  final void Function(String key, String? value)? _writeSetting;

  /// A view as stored in [viewSetting]: its kind, plus the id for a Stack.
  static String _encodeView(LibraryView view) => view.stackId == null
      ? view.kind.name
      : '${view.kind.name}:${view.stackId}';

  /// The view stored as [text], or null when there is none to go back to,
  /// for example a Stack that no longer exists.
  LibraryView? _decodeView(String? text) {
    if (text == null) return null;
    final parts = text.split(':');
    final kind = ViewKind.values.asNameMap()[parts.first];
    if (kind == null) return null;
    if (kind != ViewKind.stack || parts.length < 2) return LibraryView(kind);
    final stackId = int.tryParse(parts[1]);
    final exists = collections?.stacks.any((s) => s.id == stackId) ?? false;
    return exists ? LibraryView(kind, stackId: stackId) : null;
  }

  /// The list stored as [text] in [playedFromSetting], if there is one.
  Place? _decodePlayedFrom(String? text) {
    if (text == null) return null;
    final lineEnd = text.indexOf('\n');
    if (lineEnd < 0) return null;
    final view = _decodeView(text.substring(0, lineEnd));
    if (view == null) return null;
    return Place(view: view, search: text.substring(lineEnd + 1));
  }

  /// History and Stacks; without it those views are empty.
  final CollectionsController? collections;

  /// Stored audio, for the Downloads and On this computer views.
  final AudioStorage? storage;

  SearchIndex _index;
  List<Track> _all;
  late Map<int, Track> _byId;
  LibraryView _view = LibraryView.songs;

  /// The view's songs before searching (null for Songs: the whole library),
  /// with History or Stack entry ids alongside when the view has entries.
  List<Track>? _base;
  List<int>? _baseEntryIds;

  List<Track> _visible;
  List<int>? _visibleEntryIds;
  String _appliedQuery = '';

  /// Previous and next places, for going back and forward.
  final _places = PlaceHistory();

  /// The list the playing song was started from.
  Place? _playedFrom;

  /// Time the last search itself took, for the benchmark.
  Duration lastQueryTime = Duration.zero;

  final searchText = TextEditingController();
  final scroll = ScrollController();

  /// Typing on the list jumps to a song. Any change of the rows ends a jump,
  /// since it holds a row number.
  late final jump = TypeJump(rows: () => _visible, reveal: _revealRow);

  List<Track> get all => _all;
  LibraryView get view => _view;

  /// The song with library id [id], if it is in the library.
  Track? byId(int id) => _byId[id];

  /// Songs of the view before searching.
  int get viewCount => _base?.length ?? _all.length;

  /// Songs of the view matching the search, in the view's order.
  List<Track> get visible => _visible;

  /// History or Stack entry id of the visible row [index], for views where
  /// a song can appear more than once; null otherwise.
  int? entryIdAt(int index) => _visibleEntryIds?[index];

  /// Switches the list to [view] and scrolls to its top.
  void showView(LibraryView view) {
    if (view != _view) _places.leave(_here);
    _view = view;
    _writeSetting?.call(viewSetting, _encodeView(view));
    _rebuildBase();
    _applySearch();
    jump.clear();
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  /// Where the list is now.
  Place get _here => Place(
    view: _view,
    search: _appliedQuery,
    scroll: scroll.hasClients ? scroll.offset : 0,
  );

  /// Remembers the list on screen as the one the song being started comes
  /// from, for [goToSong]. Saved, since the song comes back in the next run.
  void notePlayedFrom() {
    final from = _here;
    if (_playedFrom?.view == from.view && _playedFrom?.search == from.search) {
      return;
    }
    _playedFrom = Place(view: from.view, search: from.search);
    _writeSetting?.call(
      playedFromSetting,
      '${_encodeView(from.view)}\n${from.search}',
    );
  }

  /// Goes to [track]'s row in the list it was played from and outlines it;
  /// when that list no longer has it, in All songs. With a song repeated in
  /// the list, [listRow] (its row when it started) tells which one it is.
  void goToSong(Track track, {int? listRow}) {
    if (byId(track.id) == null) return;
    final here = _here;
    final from =
        _playedFrom ?? const Place(view: LibraryView.songs, search: '');
    _showList(from.view, from.search);
    var row = _rowOf(track, listRow);
    if (row == null) {
      _showList(LibraryView.songs, '');
      row = _rowOf(track, listRow);
    }
    if (row == null) return;
    final sameList = _view == here.view && _appliedQuery == here.search;
    // Only the outline changes then, which is not a place to come back from.
    if (!sameList || !_rowInSight(row)) _places.leave(here);
    jump.mark(row);
    // Scroll offsets of another list only hold after its layout.
    final target = row;
    if (sameList) {
      _revealRow(target);
    } else {
      _afterLayout(() => _revealRow(target));
    }
  }

  /// Goes to the previous place, if there is one.
  void goBack() => _showPlace(_places.back(_here));

  /// Goes to the next place, if going back left one.
  void goForward() => _showPlace(_places.forward(_here));

  void _showPlace(Place? place) {
    if (place == null) return;
    _showList(place.view, place.search);
    jump.clear();
    _afterLayout(() {
      if (!scroll.hasClients) return;
      final position = scroll.position;
      scroll.jumpTo(
        place.scroll.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  /// Shows the list of [view] filtered by [search], unless it is on screen.
  /// The search box follows, without counting as a new search.
  void _showList(LibraryView view, String search) {
    if (view == _view && search == _appliedQuery) return;
    _view = view;
    _writeSetting?.call(viewSetting, _encodeView(view));
    _appliedQuery = search;
    searchText.value = TextEditingValue(
      text: search,
      selection: TextSelection.collapsed(offset: search.length),
    );
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  /// The visible row of [track]: row [listRow] if that is the song, else its
  /// first row, else null.
  int? _rowOf(Track track, int? listRow) {
    if (listRow != null &&
        listRow >= 0 &&
        listRow < _visible.length &&
        _visible[listRow].id == track.id) {
      return listRow;
    }
    final row = _visible.indexWhere((t) => t.id == track.id);
    return row < 0 ? null : row;
  }

  void _afterLayout(VoidCallback action) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => action());

  /// Whether row [index] is fully on screen.
  bool _rowInSight(int index) {
    if (!scroll.hasClients) return false;
    final position = scroll.position;
    final top = index * rowHeight;
    return top >= position.pixels &&
        top + rowHeight <= position.pixels + position.viewportDimension;
  }

  /// Scrolls row [index] into view: not at all if it is fully visible, else
  /// to a third of the way down, with the rows above it for orientation.
  void _revealRow(int index) {
    if (!scroll.hasClients || _rowInSight(index)) return;
    final position = scroll.position;
    scroll.jumpTo(
      (index * rowHeight - position.viewportDimension / 3).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  /// A new search, not more or fewer letters of the same one. The first and
  /// the last letter count: those start and leave a search.
  bool _isNewSearch(String old, String query) =>
      old.isEmpty ||
      query.isEmpty ||
      !(old.startsWith(query) || query.startsWith(old));

  void _onSearchChanged() {
    final query = searchText.text;
    if (query == _appliedQuery) return;
    if (_isNewSearch(_appliedQuery, query)) _places.leave(_here);
    _appliedQuery = query;
    final clock = Stopwatch()..start();
    _applySearch();
    lastQueryTime = clock.elapsed;
    jump.clear();
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  /// History or Stacks changed: refresh when one of them is shown.
  void _onSourceChanged() {
    if (!_view.hasEntries) return;
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  /// Stored audio changed: the view on screen may gain or lose songs. Saves
  /// starting and ending also land here without changing its rows, and those
  /// must not end a jump. A new mark on a row is the list's own business: it
  /// listens to the storage itself.
  void _onStorageChanged() {
    if (!_view.listsStorage) return;
    final before = _base;
    _rebuildBase();
    if (_sameSongs(before, _base)) {
      _base = before;
      return;
    }
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  /// Whether [a] and [b] are the same songs in the same order.
  static bool _sameSongs(List<Track>? a, List<Track>? b) {
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// The songs whose stored state passes [keep], in library order.
  List<Track> _storedSongs(bool Function(StoredState state) keep) {
    final storage = this.storage;
    return [
      for (final track in _all)
        if (keep(
          storage?.stateOf(track) ??
              (path: track.localPath, pinned: track.pinned),
        ))
          track,
    ];
  }

  void _rebuildBase() {
    _baseEntryIds = null;
    switch (_view.kind) {
      case ViewKind.songs:
        _base = null;
      case ViewKind.downloads:
        _base = _storedSongs((state) => state.path != null && state.pinned);
      case ViewKind.stored:
        _base = _storedSongs((state) => state.path != null);
      case ViewKind.history || ViewKind.stack:
        final collections = this.collections;
        final entries =
            collections == null ||
                (_view.kind == ViewKind.stack && _view.stackId == null)
            ? const <({int id, int trackId})>[]
            : _view.kind == ViewKind.history
            ? [
                for (final e in collections.history())
                  (id: e.id, trackId: e.trackId),
              ]
            : [
                for (final e in collections.stackEntries(_view.stackId!))
                  (id: e.id, trackId: e.trackId),
              ];
        final tracks = <Track>[];
        final ids = <int>[];
        for (final entry in entries) {
          final track = _byId[entry.trackId];
          if (track == null) continue;
          tracks.add(track);
          ids.add(entry.id);
        }
        _base = tracks;
        _baseEntryIds = ids;
      case ViewKind.artists || ViewKind.playlists || ViewKind.charts:
        _base = const [];
    }
  }

  void _applySearch() {
    final matches = _index.search(_appliedQuery);
    final base = _base;
    if (base == null) {
      _visible = matches ?? _all;
      _visibleEntryIds = null;
      return;
    }
    if (matches == null) {
      _visible = base;
      _visibleEntryIds = _baseEntryIds;
      return;
    }
    final wanted = {for (final track in matches) track.id};
    final tracks = <Track>[];
    final ids = _baseEntryIds == null ? null : <int>[];
    for (var i = 0; i < base.length; i++) {
      if (!wanted.contains(base[i].id)) continue;
      tracks.add(base[i]);
      ids?.add(_baseEntryIds![i]);
    }
    _visible = tracks;
    _visibleEntryIds = ids;
  }

  /// Shows a new version of the library (after a sync), keeping the view,
  /// the search and the scroll position. [index] must be built from
  /// [tracks].
  void replaceTracks(List<Track> tracks, SearchIndex index) {
    _all = tracks;
    _index = index;
    _byId = {for (final track in _all) track.id: track};
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    collections?.removeListener(_onSourceChanged);
    storage?.removeListener(_onStorageChanged);
    jump.dispose();
    searchText.dispose();
    scroll.dispose();
    super.dispose();
  }
}
