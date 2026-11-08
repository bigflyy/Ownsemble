import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../library/library_records.dart';
import '../library/search_index.dart';
import '../library/search_text.dart';
import '../library/song_filter.dart';
import '../library/song_version.dart';
import '../library/track.dart';
import '../playback/stream_route.dart';
import '../playback/version_book.dart';
import '../storage/audio_storage.dart';
import 'albums.dart';
import 'collections_controller.dart';
import 'place_history.dart';
import 'song_filters.dart';
import 'type_jump.dart';

/// Height of one song row; fixed so the list can skip layout of hidden rows.
const rowHeight = 58.0;

/// The views of the sidebar. Artists and Playlists are planned after the
/// MVP and show a "later" page; Stats is a page of numbers, not a list.
///
/// Downloads holds the songs kept for good; stored holds everything that
/// plays without the network, cached songs too ("On this computer"). An
/// album is not in the sidebar: it opens from a song's album name.
enum ViewKind {
  songs,

  /// The user's favorite songs, the newest favorite first (plan 05).
  favorites,
  artists,
  downloads,
  stored,

  /// Songs whose VK file was swapped for another recording (Stage M3).
  changed,
  stack,
  playlists,
  history,

  /// Listening stats for the page's period (plan 04, D1).
  stats,
  album,

  /// The uploads of one song on VK, to listen to and choose from (plan 03).
  versions,
}

/// One view: its kind and, for a Stack, an album or a song's versions,
/// which one.
@immutable
class LibraryView {
  const LibraryView(this.kind, {this.stackId, this.album, this.versionsOf});

  static const songs = LibraryView(ViewKind.songs);

  final ViewKind kind;
  final int? stackId;
  final AlbumRef? album;

  /// The library row whose versions are shown.
  final int? versionsOf;

  /// Whether the view lists songs outside the library (an album's, a
  /// song's versions), which the search index does not hold.
  bool get listsOutside => kind == ViewKind.album || kind == ViewKind.versions;

  /// Whether this view is a page planned for later, without songs yet.
  bool get isLater => switch (kind) {
    ViewKind.artists || ViewKind.playlists => true,
    _ => false,
  };

  /// Whether the view is a page instead of a song list: a later page or
  /// Stats.
  bool get isPage => isLater || kind == ViewKind.stats;

  /// Whether a song can appear more than once (History, Stacks).
  bool get hasEntries => kind == ViewKind.history || kind == ViewKind.stack;

  /// Whether the songs of this view depend on what is stored.
  bool get listsStorage =>
      kind == ViewKind.downloads || kind == ViewKind.stored;

  @override
  bool operator ==(Object other) =>
      other is LibraryView &&
      other.kind == kind &&
      other.stackId == stackId &&
      other.album == album &&
      other.versionsOf == versionsOf;

  @override
  int get hashCode => Object.hash(kind, stackId, album, versionsOf);
}

/// How far an open album's song list got.
enum AlbumLoad {
  /// The library's songs show; the source's full list is on its way.
  loading,

  /// The source's full list is in.
  loaded,

  /// Only the library's songs: the source could not list the album.
  failed,
}

/// What the album heading says about the open album: how far its list got,
/// why the full list is missing when it failed, and how many of its songs
/// the library has.
typedef AlbumStatus = ({AlbumLoad load, String? reason, int inLibrary});

/// State of the song list: all songs, the view chosen in the sidebar, the
/// source filter, the search text and what is shown.
///
/// Songs searches the whole library through the index. Other views list
/// their own songs (stored songs, History plays, Stack entries) and the search
/// keeps those that match, in the view's order; History and Stacks may list
/// a song more than once. The source filter keeps, in every view, the songs
/// one account has; a song merged from several accounts counts for each.
class LibraryController extends ChangeNotifier {
  LibraryController(
    this._all, {
    this.collections,
    this.storage,
    this.albums,
    this.versions,
    this.filters,
    String? Function(String key)? readSetting,
    this._writeSetting,
  }) : _index = SearchIndex(_all),
       _visible = _all {
    _byId = {for (final track in _all) track.id: track};
    _playedFrom = _decodePlayedFrom(readSetting?.call(playedFromSetting));
    searchText.addListener(_onSearchChanged);
    collections?.addListener(_onSourceChanged);
    storage?.addListener(_onStorageChanged);
    versions?.addListener(_onVersionsChanged);
    filters?.addListener(_onFiltersChanged);
    final saved = _decodeView(readSetting?.call(viewSetting));
    if (saved != null) _view = saved;
    _source = int.tryParse(readSetting?.call(sourceSetting) ?? '');
    if (saved != null || _source != null || (filters?.active ?? false)) {
      _rebuildBase();
      _applySearch();
    }
  }

  /// Setting with the view shown when the app closed.
  static const viewSetting = 'ui.view';

  /// Setting with the source the lists were filtered to when the app closed;
  /// absent for all sources.
  static const sourceSetting = 'ui.source';

  /// Setting with the list the playing song was started from: its view, on
  /// the next line its search text, and on the third its source filter
  /// (empty for all sources; older versions wrote no third line).
  static const playedFromSetting = 'ui.played_from';

  final void Function(String key, String? value)? _writeSetting;

  /// A view as stored in [viewSetting]: its kind, plus the id for a Stack.
  /// An album is stored as its kind alone, which reads back as no view.
  static String _encodeView(LibraryView view) => view.stackId == null
      ? view.kind.name
      : '${view.kind.name}:${view.stackId}';

  /// The view stored as [text], or null when there is none to go back to,
  /// for example a Stack that no longer exists. An album is not reopened in
  /// the next run: its full list would need VK before the first frame.
  LibraryView? _decodeView(String? text) {
    if (text == null) return null;
    final parts = text.split(':');
    final kind = ViewKind.values.asNameMap()[parts.first];
    if (kind == null || kind == ViewKind.album || kind == ViewKind.versions) {
      return null;
    }
    if (kind != ViewKind.stack || parts.length < 2) return LibraryView(kind);
    final stackId = int.tryParse(parts[1]);
    final exists = collections?.stacks.any((s) => s.id == stackId) ?? false;
    return exists ? LibraryView(kind, stackId: stackId) : null;
  }

  /// The list stored as [text] in [playedFromSetting], if there is one.
  Place? _decodePlayedFrom(String? text) {
    if (text == null) return null;
    final lines = text.split('\n');
    if (lines.length < 2) return null;
    final view = _decodeView(lines[0]);
    if (view == null) return null;
    return Place(
      view: view,
      search: lines[1],
      source: lines.length > 2 ? int.tryParse(lines[2]) : null,
    );
  }

  /// Sources the lists can be filtered to: those with songs. Empty until
  /// [watchSources]; fewer than two means there is nothing to choose.
  List<SourceInfo> get filterSources => _filterSources;
  List<SourceInfo> _filterSources = const [];
  ValueListenable<List<SourceInfo>>? _sources;

  /// Follows the library's sources, for [filterSources]. A filter whose
  /// source left, or that no longer has another source to choose instead,
  /// is dropped: no control would show it, and it would hide songs.
  void watchSources(ValueListenable<List<SourceInfo>> sources) {
    _sources?.removeListener(_onSourcesChanged);
    _sources = sources..addListener(_onSourcesChanged);
    _onSourcesChanged();
  }

  void _onSourcesChanged() {
    _filterSources = [
      for (final source in _sources!.value)
        if (source.songCount > 0) source,
    ];
    if (_filterSourceValid(_source)) {
      notifyListeners();
      return;
    }
    _source = null;
    _writeSetting?.call(sourceSetting, null);
    if (_playedFrom != null && !_filterSourceValid(_playedFrom!.source)) {
      _playedFrom = Place(view: _playedFrom!.view, search: _playedFrom!.search);
    }
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  /// Whether the lists may be filtered to [source] (null: all sources).
  bool _filterSourceValid(int? source) =>
      source == null ||
      (_filterSources.length > 1 && _filterSources.any((s) => s.id == source));

  /// History and Stacks; without it those views are empty.
  final CollectionsController? collections;

  /// Stored audio, for the Downloads and On this computer views.
  final AudioStorage? storage;

  /// Albums' songs; without it no album opens.
  final AlbumCatalog? albums;

  /// The versions chosen for swapped songs, for the Changed on VK view.
  final VersionBook? versions;

  /// The chips, period and sort of the Songs list (plan 04, C2).
  final SongFilters? filters;

  /// [SongFilters.generation] the Songs list was last built with.
  int _filtersGeneration = -1;

  /// Chips, period or sort changed: Songs is built again when on screen.
  /// New play numbers alone change nothing here (rows show them).
  void _onFiltersChanged() {
    final generation = filters!.generation;
    if (generation == _filtersGeneration) return;
    if (_view.kind != ViewKind.songs) return;
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
  }

  /// How many songs Changed on VK lists; null until counted again.
  int? _changedCount;

  /// How many library songs have a version choice: their VK file was
  /// swapped (Stage M3).
  int get changedCount =>
      _changedCount ??= versions == null ? 0 : _changedSongs().length;

  List<Track> _changedSongs() {
    final versions = this.versions;
    if (versions == null) return const [];
    return [
      for (final track in _all)
        if (versions.choiceFor(track) != null) track,
    ];
  }

  /// A choice was made, changed or dropped: the count and, when it is on
  /// screen, the Changed on VK view follow.
  void _onVersionsChanged() {
    _changedCount = null;
    if (_view.kind == ViewKind.versions) {
      _onVersionListChanged();
      return;
    }
    if (_view.kind != ViewKind.changed) return;
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

  /// The versions of the song whose versions place is open, and the song.
  VersionList? _versionList;
  Track? _versionsRow;

  /// The upload behind each row of the versions place, by the row's id.
  final _versionOfRow = <int, SongVersion>{};

  /// The library song whose versions are open; null in other views.
  Track? get versionsRow =>
      _view.kind == ViewKind.versions ? _versionsRow : null;

  /// The versions of [versionsRow], as they come in.
  VersionList? get versionList =>
      _view.kind == ViewKind.versions ? _versionList : null;

  /// The upload a row of the versions place plays; null for other rows.
  SongVersion? versionOf(Track track) =>
      _view.kind == ViewKind.versions ? _versionOfRow[track.id] : null;

  /// Opens [track]'s versions as a new place, like an album: what the last
  /// search found at once, VK's answer and the measured lengths as they
  /// come in through [route] (null: only what is stored).
  void openVersions(Track track, StreamRoute? route, {bool refresh = false}) {
    final versions = this.versions;
    if (versions == null || !track.inLibrary) return;
    _watchVersions(track, versions.listOf(track, route, refresh: refresh));
    final view = LibraryView(ViewKind.versions, versionsOf: track.id);
    if (view == _view && _appliedQuery.isEmpty && _source == null) {
      _onVersionListChanged();
      return;
    }
    _places.leave(_here);
    _showList(view, '', null);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void _watchVersions(Track row, VersionList list) {
    _versionsRow = row;
    if (identical(list, _versionList)) return;
    _versionList?.removeListener(_onVersionListChanged);
    _versionList = list..addListener(_onVersionListChanged);
  }

  /// New uploads or lengths came in: the place follows when on screen.
  void _onVersionListChanged() {
    if (_view.kind != ViewKind.versions) return;
    _rebuildBase();
    _applySearch();
    notifyListeners();
  }

  /// The rows of the versions place: VK's file for the song first, then
  /// the upload that plays instead of it, then the rest by how close their
  /// listed length is to the song's. The order stays put while lengths are
  /// measured, so rows do not jump under the pointer.
  List<Track> _versionSongs() {
    final versions = this.versions;
    final rowId = _view.versionsOf;
    final row = rowId == null ? null : _byId[rowId] ?? _versionsRow;
    if (versions == null || row == null) return const [];
    if (_versionList == null || _versionList!.trackId != row.id) {
      _watchVersions(row, versions.listOf(row, null));
    }
    _versionsRow = row;
    final list = _versionList!;
    final chosen = versions.choiceFor(row)?.fileKey;
    final others = [
      for (final upload in list.uploads)
        if (upload.key != chosen) upload,
    ];
    // Dart's sort is not stable: the found order breaks ties.
    final order = {for (final (i, v) in others.indexed) v.key: i};
    others.sort((a, b) {
      final byLength = (a.listedSec - row.durationSec).abs().compareTo(
        (b.listedSec - row.durationSec).abs(),
      );
      return byLength != 0 ? byLength : order[a.key]! - order[b.key]!;
    });
    final shown = [
      ?list.current,
      ...list.uploads.where((upload) => upload.key == chosen),
      ...others,
    ];
    _versionOfRow.clear();
    final tracks = <Track>[];
    for (final version in shown) {
      final track = versions.versionTrack(row, version);
      _versionOfRow[track.id] = version;
      tracks.add(track);
    }
    return tracks;
  }

  /// The full lists of albums opened in this run, oldest first, so that
  /// going back to one does not ask VK again. A few are kept: each holds its
  /// songs.
  final _albumLists = <AlbumRef, List<AlbumSong>>{};
  static const _albumListsKept = 8;

  /// Albums whose full list is being asked for, and why the last ask of an
  /// album failed.
  final _albumsLoading = <AlbumRef>{};
  final _albumFailures = <AlbumRef, String>{};

  SearchIndex _index;
  List<Track> _all;
  late Map<int, Track> _byId;
  LibraryView _view = LibraryView.songs;

  /// Library id of the source the lists are filtered to; null for all.
  int? _source;

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

  /// Called after [replaceTracks] with the new version's lookup, so lists
  /// kept elsewhere (the play list) can take over its songs and the old
  /// version can be freed.
  void Function(Track? Function(int id) find)? onTracksReplaced;

  List<Track> get all => _all;
  LibraryView get view => _view;

  /// Library id of the source the lists are filtered to; null for all.
  int? get sourceFilter => _source;

  /// The song with library id [id], if it is in the library.
  Track? byId(int id) => _byId[id];

  /// Songs of the view before searching.
  int get viewCount => _base?.length ?? _all.length;

  /// Songs of the view matching the search, in the view's order.
  List<Track> get visible => _visible;

  /// History or Stack entry id of the visible row [index], for views where
  /// a song can appear more than once; null otherwise.
  int? entryIdAt(int index) => _visibleEntryIds?[index];

  /// The album [track] is from, if it can be opened. A row of the versions
  /// place opens its upload's album, through the account of the song whose
  /// versions are shown.
  AlbumRef? albumOf(Track track) {
    final version = versionOf(track);
    if (version == null) return albums?.albumOf(track);
    // VK's file for the song is the song's own: its album as the list shows.
    final row = _versionsRow;
    if (version.isCurrentFile && row != null) return albums?.albumOf(row);
    final title = version.album;
    if (title == null || title.isEmpty) return null;
    // Without VK's link only the library's songs of the album would show,
    // and the library rarely has an upload's album: an empty place.
    final key = version.albumKey;
    if (key == null) return null;
    return AlbumRef(
      title: title,
      artist: version.artist,
      link: (
        sourceId: track.sourceId,
        key: key,
        accessKey: version.albumAccessKey,
      ),
    );
  }

  /// Opens the album [track] is from, as a new place: its songs in the
  /// library at once, and the rest once its source lists them. The search
  /// and the source filter stay with the place that is left.
  void openAlbum(Track track) {
    final album = albumOf(track);
    if (album == null) return;
    final view = LibraryView(ViewKind.album, album: album);
    if (view == _view && _appliedQuery.isEmpty && _source == null) return;
    // Opening an album whose list failed asks again; Back and Forward to it
    // do not.
    _albumFailures.remove(album);
    _places.leave(_here);
    _showList(view, '', null);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  /// What the open album's heading says; null when no album is shown.
  AlbumStatus? get albumStatus {
    final album = _view.album;
    if (_view.kind != ViewKind.album || album == null) return null;
    final base = _base ?? const <Track>[];
    final inLibrary = base.where((track) => track.inLibrary).length;
    if (_albumLists.containsKey(album)) {
      return (load: AlbumLoad.loaded, reason: null, inLibrary: inLibrary);
    }
    if (_albumsLoading.contains(album)) {
      return (load: AlbumLoad.loading, reason: null, inLibrary: inLibrary);
    }
    return (
      load: AlbumLoad.failed,
      reason: _albumFailures[album],
      inLibrary: inLibrary,
    );
  }

  /// The songs of [album]. Once its full list is in: in the album's order,
  /// the library's own song in place of each one it has, then the library's
  /// songs the list does not name (another version, a copy VK put in the
  /// album). Until then: the library's songs, and the full list is asked for
  /// unless the last ask failed: the rebuild after a failure lands here too,
  /// and must not ask VK again and again.
  List<Track> _albumSongs(AlbumRef album) {
    final catalog = albums;
    if (catalog == null) return const [];
    final libraryIds = catalog.libraryIds(album);
    final listed = _albumLists[album];
    _albumCovers = const {};
    if (listed == null) {
      if (!_albumFailures.containsKey(album)) _fetchAlbum(album);
      return [for (final id in libraryIds) ?_byId[id]];
    }
    final owned = catalog.libraryIdsByVkTrackId([
      for (final song in listed) ?song.vkTrackId,
    ]);
    final shown = <int>{};
    final tracks = <Track>[];
    final covers = <int, Track>{};
    Track? firstCover;
    for (final song in listed) {
      final own = _byId[owned[song.vkTrackId]];
      final track = own ?? song.track;
      if (!shown.add(track.id)) continue;
      tracks.add(track);
      if (!song.track.hasCover) continue;
      firstCover ??= song.track;
      if (own != null) covers[own.id] = song.track;
    }
    for (final id in libraryIds) {
      final track = _byId[id];
      if (track == null || !shown.add(id)) continue;
      tracks.add(track);
      if (firstCover != null) covers[id] = firstCover;
    }
    _albumCovers = covers;
    return tracks;
  }

  /// Library songs of the album on screen, each with the album song whose
  /// cover its row shows. Set when the album's VK list is in.
  Map<int, Track> _albumCovers = const {};

  /// [track] as its row in the current place shows it. In an album's place
  /// every row shows the album's cover and the album's name, the user's own
  /// songs too (user, 2026-11-07 for covers, 2026-11-08 for names): their
  /// copy is often tied to a single or a compilation. Everywhere else, and
  /// in the player, a song keeps its own cover and album.
  Track rowCover(Track track) {
    if (_view.kind != ViewKind.album) return track;
    final cover = _albumCovers[track.id];
    final name = _view.album?.title;
    final renamed = name != null && track.album != name;
    if (cover == null && !renamed) return track;
    return track.withCoversOf(cover ?? track, album: renamed ? name : null);
  }

  /// Asks the album's source for its full list, unless it is on its way or
  /// there is nothing to ask. The list shows when it arrives, if the album
  /// is still on screen.
  void _fetchAlbum(AlbumRef album) {
    final catalog = albums;
    if (catalog == null || _albumsLoading.contains(album)) return;
    if (!catalog.canFetch(album)) {
      _albumFailures[album] = album.link == null
          ? 'only your songs: the next sync links this album to VK'
          : 'only your songs: log in to the account it came from';
      return;
    }
    _albumsLoading.add(album);
    _albumFailures.remove(album);
    catalog
        .fetch(album)
        .then(
          (songs) {
            _albumLists[album] = songs;
            if (_albumLists.length > _albumListsKept) {
              _albumLists.remove(_albumLists.keys.first);
            }
          },
          onError: (Object error) {
            _albumFailures[album] = error is AlbumNotListed
                ? error.reason
                : 'VK did not list the album';
          },
        )
        .whenComplete(() {
          _albumsLoading.remove(album);
          if (_disposed || _view.album != album) return;
          _rebuildBase();
          _applySearch();
          jump.clear();
          notifyListeners();
        });
  }

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

  /// Filters every view to the songs of source [sourceId], or shows all
  /// sources again for null, keeping the view and the search.
  void showSource(int? sourceId) {
    if (sourceId == _source) return;
    _places.leave(_here);
    _source = sourceId;
    _writeSetting?.call(sourceSetting, sourceId?.toString());
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
    source: _source,
    scroll: scroll.hasClients ? scroll.offset : 0,
  );

  /// Remembers the list on screen as the one the song being started comes
  /// from, for [goToSong]. Saved, since the song comes back in the next run.
  void notePlayedFrom() {
    final from = Place(view: _view, search: _appliedQuery, source: _source);
    if (_playedFrom == from) return;
    _playedFrom = from;
    _writeSetting?.call(
      playedFromSetting,
      '${_encodeView(from.view)}\n${from.search}\n${from.source ?? ''}',
    );
  }

  /// Goes to [track]'s row in the list it was played from and outlines it;
  /// when that list no longer has it, in All songs. With a song repeated in
  /// the list, [listRow] (its row when it started) tells which one it is.
  ///
  /// A song outside the library (from an album) is only in the album's list.
  void goToSong(Track track, {int? listRow}) {
    final from =
        _playedFrom ?? const Place(view: LibraryView.songs, search: '');
    final inLibrary = byId(track.id) != null;
    if (!inLibrary && !from.view.listsOutside) return;
    final here = _here;
    _showList(from.view, from.search, from.source);
    var row = _rowOf(track, listRow);
    if (row == null && inLibrary) {
      _showList(LibraryView.songs, '', null);
      row = _rowOf(track, listRow);
    }
    if (row == null) return;
    final sameList =
        _view == here.view &&
        _appliedQuery == here.search &&
        _source == here.source;
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
    // A place filtered to a source that left shows all sources.
    _showList(
      place.view,
      place.search,
      _filterSourceValid(place.source) ? place.source : null,
    );
    jump.clear();
    _afterLayout(() {
      if (!scroll.hasClients) return;
      final position = scroll.position;
      scroll.jumpTo(
        place.scroll.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  /// Shows the list of [view] filtered by [search] and to [source], unless it
  /// is on screen. The search box follows, without counting as a new search.
  void _showList(LibraryView view, String search, int? source) {
    if (view == _view && search == _appliedQuery && source == _source) return;
    _view = view;
    _writeSetting?.call(viewSetting, _encodeView(view));
    if (source != _source) {
      _source = source;
      _writeSetting?.call(sourceSetting, source?.toString());
    }
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
    final favoriteChip =
        _view.kind == ViewKind.songs &&
        filters?.filter.ruleFor(FilterField.favorite) != null;
    if (_view.kind == ViewKind.favorites || favoriteChip) {
      final before = _base;
      _rebuildBase();
      if (_sameSongs(before, _base)) {
        _base = before;
        return;
      }
      _applySearch();
      jump.clear();
      notifyListeners();
      return;
    }
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
    final offlineChip =
        _view.kind == ViewKind.songs &&
        filters?.filter.ruleFor(FilterField.offline) != null;
    if (!_view.listsStorage && !offlineChip) return;
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
        final filters = this.filters;
        _filtersGeneration = filters?.generation ?? -1;
        _base = filters != null && filters.active ? filters.apply(_all) : null;
      case ViewKind.favorites:
        _base = [
          for (final favorite in collections?.favorites ?? const <Favorite>[])
            ?_byId[favorite.trackId],
        ];
      case ViewKind.downloads:
        _base = _storedSongs((state) => state.path != null && state.pinned);
      case ViewKind.stored:
        _base = _storedSongs((state) => state.path != null);
      case ViewKind.changed:
        _base = _changedSongs();
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
      case ViewKind.album:
        final album = _view.album;
        _base = album == null ? const [] : _albumSongs(album);
      case ViewKind.versions:
        _base = _versionSongs();
      case ViewKind.artists || ViewKind.playlists || ViewKind.stats:
        _base = const [];
    }
    _filterBaseBySource();
  }

  /// Keeps only the songs [_source] has in the view's songs, with their entry
  /// ids; Songs then gets its own list instead of the whole library.
  void _filterBaseBySource() {
    final source = _source;
    if (source == null) return;
    final base = _base ?? _all;
    final ids = _baseEntryIds;
    final tracks = <Track>[];
    final keptIds = ids == null ? null : <int>[];
    for (var i = 0; i < base.length; i++) {
      if (!base[i].isFrom(source)) continue;
      tracks.add(base[i]);
      keptIds?.add(ids![i]);
    }
    _base = tracks;
    _baseEntryIds = keptIds;
  }

  void _applySearch() {
    final base = _base;
    // An album's songs outside the library are not in the index; an album
    // is short, so its rows are matched one by one.
    if (_view.listsOutside && base != null) {
      final words = searchWords(_appliedQuery);
      _visible = words.isEmpty
          ? base
          : [
              for (final track in base)
                if (matchesAllWords(searchTextOf(track), words)) track,
            ];
      _visibleEntryIds = null;
      return;
    }
    final matches = _index.search(_appliedQuery);
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
    _changedCount = null;
    // A sync may merge songs, which moves their plays and favorites to one
    // row.
    if (filters?.loaded ?? false) filters!.reload();
    collections?.reloadFavorites();
    _rebuildBase();
    _applySearch();
    jump.clear();
    notifyListeners();
    onTracksReplaced?.call(byId);
  }

  /// Set by [dispose]: an album list that arrives later is dropped.
  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _sources?.removeListener(_onSourcesChanged);
    collections?.removeListener(_onSourceChanged);
    storage?.removeListener(_onStorageChanged);
    versions?.removeListener(_onVersionsChanged);
    filters?.removeListener(_onFiltersChanged);
    _versionList?.removeListener(_onVersionListChanged);
    jump.dispose();
    searchText.dispose();
    scroll.dispose();
    super.dispose();
  }
}
