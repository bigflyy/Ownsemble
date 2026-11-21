/// The library's artists for the places of plan 09 (Stage D): the index of
/// every artist (built on demand, never before the first frame, R12), the
/// Artists place's sort, the round tiles' photos (asked of VK in small
/// batches while the place is open, R2), VK's page of each artist opened
/// (kept for the last [artistPagesKept], R10) and VK's Popular list of an
/// artist as an ordinary VK list place ([ListCatalog], R6).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/artist_credit.dart';
import '../library/artist_index.dart';
import '../library/library_store.dart';
import '../library/play_stats.dart';
import '../library/search_text.dart';
import '../library/track.dart';
import '../vk/vk_artists.dart';
import '../vk/vk_client.dart' show VkApiCall;
import '../vk/vk_sync.dart' show describeSyncError;
import 'albums.dart';
import 'library_controller.dart';
import 'outside_songs.dart';

/// Setting with the Artists place's sort (an [ArtistSort] name).
const artistsSortSetting = 'ui.artists_sort';

/// Keys of the VK lists of an artist's Popular songs start with this, then
/// VK's artist id.
const artistPopularKeyPrefix = 'artist-popular:';

/// Whether [ref] is an artist's Popular list on VK.
bool isArtistListRef(AlbumRef ref) =>
    ref.link?.key.startsWith(artistPopularKeyPrefix) ?? false;

/// How many artists one photo request asks for. VK takes up to 25 in one
/// `execute` (6.1 s, once 14 s); 10 keep each request well inside the
/// click client's 15 s (R2) and let the first tiles fill sooner.
const artistPhotosPerRequest = 10;

/// How many VK artist pages are kept while the app runs.
const artistPagesKept = 30;

/// How many more pages of Popular "Show more" asks for at most (20 songs
/// each): the probe stopped at 10 pages (~200 songs), R7.
const popularPagesMax = 10;

/// How long the photos wait after a request failed before the place asks
/// again.
const artistPhotoRetryAfter = Duration(seconds: 30);

/// How far VK's part of an artist's page got.
enum ArtistVkLoad {
  /// Asking VK.
  loading,

  /// VK's page is in.
  loaded,

  /// VK did not answer; [ArtistVkState.error] says why.
  failed,

  /// VK has no page for the artist (a name-only artist, or VK said none).
  none,

  /// No VK account is logged in.
  noAccount,
}

/// VK's part of one artist's page as the page shows it.
typedef ArtistVkState = ({
  ArtistVkLoad load,
  VkArtistPage? page,
  String? error,
  int? sourceId,
});

/// See the library comment.
class LibraryArtists extends ChangeNotifier implements ListCatalog {
  LibraryArtists({
    required this.library,
    required this.credits,
    required this.outside,
    required this.accounts,
    required this.apiOfSource,
    this.albumKeys,
    this.plays,
    this.loadPhotos,
    this.savePhotos,
    this.readSetting,
    this.writeSetting,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    final saved = readSetting?.call(artistsSortSetting);
    _sort = ArtistSort.values.asNameMap()[saved] ?? ArtistSort.mostSongs;
    library.addListener(_onLibrary);
  }

  final LibraryController library;

  /// Each listed song's artists (LibraryStore.songArtistCredits).
  final Map<int, List<ArtistCredit>> Function() credits;

  /// Each listed song's VK album key (LibraryStore.listedVkAlbumKeys).
  final Map<int, String> Function()? albumKeys;

  /// Every song's plays of all time, for Most heard (SongFilters.allTime).
  final Map<int, SongPlays> Function()? plays;

  final Map<String, StoredArtistPhoto> Function()? loadPhotos;
  final void Function(Map<String, ({String small, String large})?> photos)?
  savePhotos;

  /// The songs of VK lists the library lacks (shared with For you and the
  /// playlists, so a song keeps one id everywhere).
  final OutsideSongs outside;

  /// The logged-in VK accounts; VK's artist pages and photos are read
  /// through the first.
  final List<SourceInfo> Function() accounts;
  final VkApiCall? Function(int sourceId) apiOfSource;

  final String? Function(String key)? readSetting;
  final void Function(String key, String? value)? writeSetting;

  /// One line to perf.log: counts and times only, never names or links.
  final void Function(String line)? log;
  final DateTime Function() _now;

  /// Called when more songs of an artist's Popular list came in, so its
  /// open place shows them (LibraryController.listChanged).
  void Function(AlbumRef list)? onListChanged;

  var _disposed = false;

  // ---- The index ----

  ArtistIndex? _index;
  List<Track>? _builtFor;
  Map<String, Artist>? _byDomain;
  var _rebuildQueued = false;

  /// The library's artists, built now if the library changed since.
  ArtistIndex get index {
    if (_index == null || !identical(_builtFor, library.all)) _build();
    return _index!;
  }

  /// The index as last built, without building: null before the first
  /// build. Song rows use it, so a row never builds it while the first
  /// frame is drawn (R12); [warmUp] builds it after.
  ArtistIndex? get builtIndex => _index;

  /// Builds the index if it is not built for the current library, and says
  /// so to the places.
  void warmUp() {
    if (_disposed) return;
    if (_index != null && identical(_builtFor, library.all)) return;
    _build();
    notifyListeners();
  }

  void _build() {
    final clock = Stopwatch()..start();
    final tracks = library.all;
    _index = ArtistIndex.build(
      tracks,
      credits(),
      albumKeys: albumKeys?.call() ?? const {},
    );
    _builtFor = tracks;
    _byDomain = null;
    _sorted = null;
    log?.call(
      'artists index: ${_index!.length} artists from ${tracks.length} songs '
      'in ${clock.elapsedMilliseconds} ms',
    );
  }

  /// A new version of the library (a sync, an add, a removal): a built
  /// index is built again after this frame, so links and places follow.
  void _onLibrary() {
    if (_index == null || identical(_builtFor, library.all)) return;
    if (_rebuildQueued) return;
    _rebuildQueued = true;
    Timer.run(() {
      _rebuildQueued = false;
      warmUp();
    });
  }

  /// The artist with key [key] (`vk:<id>`, `name:<name key>` or
  /// `domain:<address name>`), or null when the library has none.
  Artist? artistOf(String key) {
    if (key.startsWith('domain:')) {
      return byDomain(key.substring('domain:'.length));
    }
    return index[key];
  }

  /// The library's artist with VK's address name [domain], or null.
  Artist? byDomain(String domain) {
    final map = _byDomain ??= {
      for (final artist in index.artists)
        if (artist.domain case final d? when d.isNotEmpty) d: artist,
    };
    return map[domain];
  }

  /// The key of the artist a Stats row named [text] (a song's whole artist
  /// text) is: the artist of the first song with that text, or the one
  /// artist with that name; null when none.
  String? keyForText(String text) {
    final index = this.index;
    for (final track in library.all) {
      if (track.artist != text) continue;
      final artist = index.artistsOf(track.id).firstOrNull;
      if (artist != null) return artist.key;
    }
    final named = [
      for (final artist in index.artists)
        if (artistNameKey(artist.name) == artistNameKey(text)) artist,
    ];
    return named.length == 1 ? named.single.key : null;
  }

  /// The library songs of the artist [key], newest added first.
  List<Track> songsOf(String key) => artistOf(key)?.songs ?? const [];

  // ---- The place's sort and search ----

  late ArtistSort _sort;
  ArtistSort get sort => _sort;

  List<Artist>? _sorted;

  set sort(ArtistSort value) {
    if (value == _sort) return;
    _sort = value;
    _sorted = null;
    writeSetting?.call(artistsSortSetting, value.name);
    notifyListeners();
  }

  /// The artists the place shows: every one in [sort]'s order, or those
  /// whose name has every word of [query].
  List<Artist> shown(String query) {
    final List<Artist> all;
    if (_sort == ArtistSort.mostHeard) {
      // Plays change with every counted play: asked each time (R5).
      all = index.sorted(_sort, plays: plays?.call() ?? const {});
    } else {
      all = _sorted ??= index.sorted(_sort);
    }
    final words = searchWords(query);
    if (words.isEmpty) return all;
    return [
      for (final artist in all)
        if (matchesAllWords(normalizeForSearch(artist.name), words)) artist,
    ];
  }

  // ---- Photos ----

  Map<String, StoredArtistPhoto>? _photos;
  Map<String, StoredArtistPhoto> get _photoMap =>
      _photos ??= loadPhotos?.call() ?? {};

  /// The stored photo of [artist]; null when none is known yet (or for a
  /// name-only artist). Both links null: VK has none.
  StoredArtistPhoto? photoOf(Artist artist) {
    final id = artist.vkId;
    return id == null ? null : _photoMap[id];
  }

  /// The stored photo of VK's artist [vkId], or null.
  StoredArtistPhoto? photoOfId(String vkId) => _photoMap[vkId];

  var _placeOpen = false;
  var _photosRunning = false;
  List<Artist> _photoOrder = const [];

  /// Artists asked for in this run that VK left out of an answer: asked
  /// again at the next run, never marked as having no photo (R2).
  final _photoAsked = <String>{};
  DateTime? _photoFailedAt;

  /// The Artists place opened or closed: photos are asked only while it is
  /// open.
  void placeOpen(bool open) {
    _placeOpen = open;
    if (open) unawaited(_fetchPhotos());
  }

  /// The grid's artists from the first visible tile on: their photos are
  /// asked first.
  void wantPhotos(List<Artist> order) {
    _photoOrder = order;
    if (_placeOpen) unawaited(_fetchPhotos());
  }

  Future<void> _fetchPhotos() async {
    if (_photosRunning || loadPhotos == null) return;
    final failed = _photoFailedAt;
    if (failed != null && _now().difference(failed) < artistPhotoRetryAfter) {
      return;
    }
    _photosRunning = true;
    try {
      while (_placeOpen && !_disposed) {
        final account = accounts().firstOrNull;
        final call = account == null ? null : apiOfSource(account.id);
        if (call == null) return;
        final wanted = artistsWantingPhotos(
          _photoOrder.where((a) => !_photoAsked.contains(a.vkId)),
          _photoMap,
          nowMs: _now().millisecondsSinceEpoch,
          lifetime: LibraryStore.artistPhotoLifetime,
          limit: artistPhotosPerRequest,
        );
        if (wanted.isEmpty) return;
        final clock = Stopwatch()..start();
        final Map<String, VkArtistPhoto> got;
        try {
          got = await fetchVkArtistPhotos(call, [
            for (final artist in wanted) (id: artist.vkId!, name: artist.name),
          ]);
        } catch (error) {
          _photoFailedAt = _now();
          log?.call(
            'artist photos: ${wanted.length} failed after '
            '${clock.elapsedMilliseconds} ms (${error.runtimeType})',
          );
          return;
        }
        if (_disposed) return;
        for (final artist in wanted) {
          _photoAsked.add(artist.vkId!);
        }
        final stored = photosToStore(got);
        savePhotos?.call(stored);
        final at = _now().millisecondsSinceEpoch;
        for (final MapEntry(key: id, value: photo) in stored.entries) {
          _photoMap[id] = (
            small: photo?.small,
            large: photo?.large,
            fetchedAtMs: at,
          );
        }
        final found = stored.values.where((p) => p != null).length;
        log?.call(
          'artist photos: $found found, ${stored.length - found} none, '
          '${wanted.length - stored.length} not answered of ${wanted.length} '
          'in ${clock.elapsedMilliseconds} ms',
        );
        notifyListeners();
      }
    } finally {
      _photosRunning = false;
    }
  }

  // ---- VK's artist pages ----

  /// Pages by "sourceId:artistId", oldest first.
  final _pages = <String, VkArtistPage>{};

  /// Artist ids by "sourceId:d:domain", for pages opened by address name.
  final _domainIds = <String, String>{};
  final _loading = <String>{};
  final _failures = <String, String>{};

  /// Pages VK answered without an artist.
  final _missing = <String>{};

  /// The account VK's pages are read through: the first logged-in one.
  int? get _sourceId => accounts().firstOrNull?.id;

  String _keyOf(int sourceId, String idOrDomain) {
    final id = _domainIds['$sourceId:d:$idOrDomain'];
    return '$sourceId:${id ?? idOrDomain}';
  }

  /// VK's part of the page of the artist VK knows as [idOrDomain] (an id,
  /// or an address name); [loadVk] asks for it.
  ArtistVkState vkOf(String idOrDomain) {
    final sourceId = _sourceId;
    if (sourceId == null || apiOfSource(sourceId) == null) {
      return (
        load: ArtistVkLoad.noAccount,
        page: null,
        error: null,
        sourceId: null,
      );
    }
    final key = _keyOf(sourceId, idOrDomain);
    final page = _pages[key];
    if (page != null) {
      return (
        load: ArtistVkLoad.loaded,
        page: page,
        error: null,
        sourceId: sourceId,
      );
    }
    if (_missing.contains(key)) {
      return (
        load: ArtistVkLoad.none,
        page: null,
        error: null,
        sourceId: sourceId,
      );
    }
    final error = _failures[key];
    if (error != null && !_loading.contains(key)) {
      return (
        load: ArtistVkLoad.failed,
        page: null,
        error: error,
        sourceId: sourceId,
      );
    }
    return (
      load: ArtistVkLoad.loading,
      page: null,
      error: null,
      sourceId: sourceId,
    );
  }

  /// Asks VK for the page of [idOrDomain] unless it is in, on its way, or
  /// failed (then only with [again]: the Try again button).
  void loadVk(String idOrDomain, {bool again = false}) {
    final sourceId = _sourceId;
    final call = sourceId == null ? null : apiOfSource(sourceId);
    if (sourceId == null || call == null) return;
    final key = _keyOf(sourceId, idOrDomain);
    if (_pages.containsKey(key) ||
        _loading.contains(key) ||
        _missing.contains(key)) {
      return;
    }
    if (_failures.containsKey(key) && !again) return;
    _loading.add(key);
    _failures.remove(key);
    final clock = Stopwatch()..start();
    fetchVkArtistPage(call, idOrDomain)
        .then(
          (page) {
            // A reply for an account no longer first is dropped (R10).
            if (_sourceId != sourceId) return;
            if (page == null) {
              _missing.add(key);
              return;
            }
            if (page.id != idOrDomain) {
              _domainIds['$sourceId:d:$idOrDomain'] = page.id;
            }
            final domain = page.domain;
            if (domain != null && domain.isNotEmpty) {
              _domainIds['$sourceId:d:$domain'] = page.id;
            }
            final byId = '$sourceId:${page.id}';
            _pages.remove(byId);
            _pages[byId] = page;
            while (_pages.length > artistPagesKept) {
              final oldest = _pages.keys.first;
              _pages.remove(oldest);
              _popular.remove(oldest);
            }
            log?.call(
              'artist page: ${page.popular.songs.length} popular, '
              '${page.releases.length} releases, ${page.similar.length} '
              'similar in ${clock.elapsedMilliseconds} ms',
            );
            if (page.hasMoreReleases) _moreReleases(call, sourceId, page);
          },
          onError: (Object error) {
            _failures[key] = describeSyncError(error);
            log?.call(
              'artist page failed after ${clock.elapsedMilliseconds} ms '
              '(${error.runtimeType})',
            );
          },
        )
        .whenComplete(() {
          _loading.remove(key);
          if (!_disposed) notifyListeners();
        });
  }

  /// Pages on [page]'s Releases past VK's first 10 (one more request,
  /// about 0.3 s): the page shows the first ones at once and the rest when
  /// they come. A failure keeps the first ones; the next run asks again.
  void _moreReleases(VkApiCall call, int sourceId, VkArtistPage page) {
    final byId = '$sourceId:${page.id}';
    final clock = Stopwatch()..start();
    fetchVkReleasesMore(call, page).then(
      (all) {
        // Kept only while the same page is held for the same account.
        if (_disposed ||
            _sourceId != sourceId ||
            !identical(_pages[byId], page)) {
          return;
        }
        _pages[byId] = all;
        log?.call(
          'artist releases: ${all.releases.length} after paging in '
          '${clock.elapsedMilliseconds} ms',
        );
        notifyListeners();
      },
      onError: (Object error) {
        log?.call(
          'artist releases paging failed after '
          '${clock.elapsedMilliseconds} ms (${error.runtimeType})',
        );
      },
    );
  }

  // ---- Popular as a VK list ----

  /// Popular as paged on by "Show more", by "sourceId:artistId".
  final _popular = <String, VkSongBlock>{};
  final _paging = <String>{};

  /// The list place of [page]'s Popular songs, read through [sourceId].
  AlbumRef popularRef(VkArtistPage page, int sourceId) => AlbumRef(
    title: 'Popular on VK: ${page.name}',
    artist: page.name,
    link: (
      sourceId: sourceId,
      key: '$artistPopularKeyPrefix${page.id}',
      accessKey: null,
    ),
  );

  String? _popularKey(AlbumRef ref) {
    final link = ref.link;
    if (link == null || !isArtistListRef(ref)) return null;
    return '${link.sourceId}:${link.key.substring(artistPopularKeyPrefix.length)}';
  }

  VkSongBlock? _popularOf(String key) => _popular[key] ?? _pages[key]?.popular;

  /// The Popular songs of [page] read so far, as tracks.
  List<Track> popularTracks(VkArtistPage page, int sourceId) => [
    for (final song in _popularOf('$sourceId:${page.id}')?.songs ?? const [])
      outside.trackOf(song, sourceId),
  ];

  /// Whether more of [ref]'s songs are being asked for.
  bool pagingPopular(AlbumRef ref) => _paging.contains(_popularKey(ref));

  /// How many songs [ref] has on VK: VK's count when it gave one, or the
  /// number read once paging ended (R7); null while unknown.
  int? popularTotal(AlbumRef ref) {
    final key = _popularKey(ref);
    if (key == null) return null;
    final block = _popularOf(key);
    if (block == null) return null;
    if (!block.hasMore) return block.songs.length;
    return _pages[key]?.popularTotal;
  }

  /// Asks VK for the rest of [ref]'s songs, a page at a time, each page
  /// shown as it lands (onListChanged); stops after [popularPagesMax]
  /// pages, when a page brings nothing new, or on an error.
  Future<void> morePopular(AlbumRef ref) async {
    final key = _popularKey(ref);
    final call = apiOfSource(ref.link?.sourceId ?? -1);
    if (key == null || call == null || !_paging.add(key)) return;
    notifyListeners();
    final clock = Stopwatch()..start();
    var pages = 0;
    try {
      while (pages < popularPagesMax && !_disposed) {
        final block = _popularOf(key);
        if (block == null || !block.hasMore) break;
        final next = await fetchVkBlockMore(call, block);
        pages++;
        _popular[key] = next;
        onListChanged?.call(ref);
        if (next.songs.length == block.songs.length) break;
      }
    } catch (error) {
      log?.call('artist popular: page failed (${error.runtimeType})');
    } finally {
      _paging.remove(key);
      log?.call(
        'artist popular: $pages more pages, '
        '${_popularOf(key)?.songs.length ?? 0} songs in '
        '${clock.elapsedMilliseconds} ms',
      );
      if (!_disposed) notifyListeners();
    }
  }

  @override
  List<AlbumSong>? cached(AlbumRef list) {
    final key = _popularKey(list);
    final block = key == null ? null : _popularOf(key);
    if (block == null) return null;
    return outside.albumSongs(block.songs, list.link!.sourceId);
  }

  @override
  bool canFetch(AlbumRef album) =>
      isArtistListRef(album) && apiOfSource(album.link!.sourceId) != null;

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) async {
    final at = cached(album);
    if (at != null) return at;
    final link = album.link;
    final call = link == null ? null : apiOfSource(link.sourceId);
    if (link == null || call == null || !isArtistListRef(album)) {
      throw const AlbumNotListed('log in to a VK account');
    }
    final id = link.key.substring(artistPopularKeyPrefix.length);
    final VkArtistPage? page;
    try {
      page = await fetchVkArtistPage(call, id);
    } catch (error) {
      throw AlbumNotListed('VK did not list it: ${describeSyncError(error)}');
    }
    if (page == null) throw const AlbumNotListed('VK has no page for them');
    final byId = '${link.sourceId}:${page.id}';
    // A page that came in meanwhile (the artist page opened) stays, with
    // its releases paging; a new one pages its releases too (Codex review
    // 2026-11-21).
    final held = _pages[byId];
    if (held == null) {
      _pages[byId] = page;
      if (page.hasMoreReleases) _moreReleases(call, link.sourceId, page);
    }
    return outside.albumSongs((held ?? page).popular.songs, link.sourceId);
  }

  @override
  Track? libraryCopyOf(AlbumSong song) => outside.libraryCopyOf(song.track.id);

  @override
  AlbumRef? albumOf(Track track) => outside.albumOf(track);

  @override
  List<int> libraryIds(AlbumRef album) => const [];

  @override
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds) => const {};

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_onLibrary);
    super.dispose();
  }
}

/// The line under an artist's Popular list: what it is, how many songs VK
/// has, how many the library has, and whether more are coming.
String? artistListDetail(
  LibraryArtists? artists,
  AlbumRef ref,
  AlbumStatus status,
) {
  if (status.load == AlbumLoad.loading) return 'Getting the songs from VK...';
  if (status.load == AlbumLoad.failed) return status.reason;
  final yours = status.inLibrary == 1
      ? '1 in your library'
      : '${status.inLibrary} in your library';
  final total = artists?.popularTotal(ref);
  final paging = artists?.pagingPopular(ref) ?? false;
  return [
    if (total != null) '${total == 1 ? '1 song' : '$total songs'} on VK',
    yours,
    if (paging) 'getting more from VK...',
  ].join(', ');
}
