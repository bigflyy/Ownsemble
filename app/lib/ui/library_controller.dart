import 'package:flutter/widgets.dart';

import '../library/search_index.dart';
import '../library/track.dart';
import '../storage/audio_storage.dart';
import 'collections_controller.dart';

/// The views of the sidebar. Artists, Playlists and Charts are planned
/// after the MVP and show a "later" page.
enum ViewKind { songs, artists, downloads, stack, playlists, history, charts }

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
/// their own songs (downloads, History plays, Stack entries) and the search
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

  /// History and Stacks; without it those views are empty.
  final CollectionsController? collections;

  /// Stored audio, for the Downloads view.
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

  /// Time the last search itself took, for the benchmark.
  Duration lastQueryTime = Duration.zero;

  final searchText = TextEditingController();
  final scroll = ScrollController();

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
    _view = view;
    _writeSetting?.call(viewSetting, _encodeView(view));
    _rebuildBase();
    _applySearch();
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  void _onSearchChanged() {
    final query = searchText.text;
    if (query == _appliedQuery) return;
    _appliedQuery = query;
    final clock = Stopwatch()..start();
    _applySearch();
    lastQueryTime = clock.elapsed;
    if (scroll.hasClients) scroll.jumpTo(0);
    notifyListeners();
  }

  /// History or Stacks changed: refresh when one of them is shown.
  void _onSourceChanged() {
    if (!_view.hasEntries) return;
    _rebuildBase();
    _applySearch();
    notifyListeners();
  }

  /// Stored audio changed: the Downloads view may gain or lose songs.
  void _onStorageChanged() {
    if (_view.kind != ViewKind.downloads) return;
    _rebuildBase();
    _applySearch();
    notifyListeners();
  }

  void _rebuildBase() {
    _baseEntryIds = null;
    switch (_view.kind) {
      case ViewKind.songs:
        _base = null;
      case ViewKind.downloads:
        final storage = this.storage;
        _base = [
          for (final track in _all)
            if (storage == null
                ? track.isDownloaded
                : storage.stateOf(track).pinned)
              track,
        ];
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
    notifyListeners();
  }

  @override
  void dispose() {
    collections?.removeListener(_onSourceChanged);
    storage?.removeListener(_onStorageChanged);
    searchText.dispose();
    scroll.dispose();
    super.dispose();
  }
}
