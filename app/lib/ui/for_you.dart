/// The For you place's data (plan 07, C2): what VK recommends to the first
/// VK account, kept in a cache file so the place opens at once, and asked
/// again in the background when the place opens and the cache is older than
/// [ForYou.staleAfter].
///
/// VK rewrites its lists in place and says when (update_time, A3): a
/// refresh reads the music page (one call, 2-3 s) and then only the lists
/// whose time moved, all at once. A list VK did not answer for keeps the
/// songs it had. The cache file holds the songs as the library stores them
/// (names, lengths, keys, cover links), never a stream link.
///
/// Its lists open as an ordinary song list in the library screen
/// ([ListCatalog]: VK's lists, "Similar to" songs and VK Mix): the library's
/// own song in place of each recommended song it has, + on the others.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_recommendations.dart';
import '../vk/vk_sync.dart' show describeSyncError;
import 'albums.dart';

/// An album catalog for lists that are not albums (VK's recommended lists):
/// their songs may be at hand already, and each song names its library copy.
abstract interface class ListCatalog implements AlbumCatalog {
  /// The songs of [list] when they are at hand without asking anyone.
  List<AlbumSong>? cached(AlbumRef list);

  /// The library's song that [song] of a list is (same key, the same VK
  /// recording, or the same name and length), or null.
  Track? libraryCopyOf(AlbumSong song);
}

/// Keys of the lists that are not one of VK's own lists.
const forYouMixKey = 'mix';
const _similarKeyPrefix = 'similar:';

/// Ids of recommended songs start here and go down, below the album songs
/// (-1, -2, ...) and versions (-1e9 - n), above found songs (-2e9 - n).
const _firstRecId = -1500000000;

/// The For you place's lists and songs for the first VK account.
class ForYou extends ChangeNotifier implements ListCatalog {
  ForYou({
    required this.accounts,
    required this.apiOfSource,
    required this.libraryCopyOfSong,
    this.cacheDir,
    this.staleAfter = const Duration(minutes: 10),
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The VK accounts that are logged in, first one first: VK recommends to
  /// each account its own; the place shows the first account's.
  final List<SourceInfo> Function() accounts;
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// The library's song that a VK song is ([ListCatalog.libraryCopyOf]).
  final Track? Function(NewTrack song) libraryCopyOfSong;

  /// Where the cache file and the dislike record are kept; null keeps
  /// nothing (tests).
  final String? cacheDir;
  final Duration staleAfter;

  /// One line to perf.log: times and counts only.
  final void Function(String line)? log;
  final DateTime Function() _now;

  VkMusicPage? _page;
  final _songs = <String, List<VkRecSong>>{};
  DateTime? _fetchedAt;
  int? _sourceId;
  bool _loadedCache = false;
  bool _refreshing = false;
  Object? _error;
  bool _disposed = false;

  /// The account whose recommendations show; null with no VK account.
  SourceInfo? get account => accounts().firstOrNull;

  /// VK's own lists, in the page's order (empty before the first answer).
  List<VkRecList> get lists => _page?.lists ?? const [];

  /// The "Similar to" shelves.
  List<VkSongShelf> get similar => _page?.similar ?? const [];

  bool get hasMix => _page?.hasMix ?? false;

  /// When the lists shown came from VK; null before the first answer.
  DateTime? get fetchedAt => _fetchedAt;

  /// Whether VK is being asked now.
  bool get refreshing => _refreshing;

  /// Why the last refresh failed, in words for the banner; null when it
  /// did not. Never holds a link.
  String? get error => _error == null ? null : describeSyncError(_error!);

  /// Whether anything can show: VK answered once (now or in an earlier run).
  bool get hasLists => _page != null;

  /// The songs of the VK list [key] as they are at hand.
  List<VkRecSong> songsOf(String key) => _songs[key] ?? const [];

  // ---- Opening and refreshing ----

  /// The place opened: the cached lists at once, then VK in the background
  /// when they are older than [staleAfter] (or of another account).
  void open() {
    _loadCache();
    final fetched = _fetchedAt;
    final stale =
        fetched == null ||
        _now().difference(fetched) > staleAfter ||
        _sourceId != account?.id;
    if (stale) unawaited(refresh());
  }

  /// Asks VK for the music page and the lists whose update time moved.
  /// While VK is being asked, the same ask is returned.
  Future<void> refresh() =>
      _running ??= _refresh().whenComplete(() => _running = null);

  Future<void>? _running;

  Future<void> _refresh() async {
    final source = account;
    final call = source == null ? null : apiOfSource(source.id);
    if (source == null || call == null) return;
    _refreshing = true;
    _notify();
    final clock = Stopwatch()..start();
    try {
      final page = await fetchVkMusicPage(call);
      final pageMs = clock.elapsedMilliseconds;
      final sameAccount = _sourceId == source.id;
      final old = {for (final list in lists) list.key: list.updateTime};
      final changed = [
        for (final list in page.lists)
          if (!sameAccount ||
              old[list.key] != list.updateTime ||
              !_songs.containsKey(list.key))
            list,
      ];
      if (!sameAccount) _songs.clear();
      final failed = <String>[];
      await Future.wait([
        for (final list in changed)
          () async {
            try {
              _songs[list.key] = await fetchVkListSongs(call, list);
            } catch (_) {
              failed.add(list.key);
            }
          }(),
      ]);
      // A list VK no longer offers leaves; one it did not answer for now
      // keeps the songs it had.
      final keys = {for (final list in page.lists) list.key};
      _songs.removeWhere((key, _) => !keys.contains(key) && !_isOwnKey(key));
      _page = page;
      _sourceId = source.id;
      _fetchedAt = _now();
      _error = null;
      log?.call(
        'for-you refresh: page $pageMs ms, ${changed.length} of '
        '${page.lists.length} lists read in '
        '${clock.elapsedMilliseconds - pageMs} ms, ${failed.length} failed, '
        '${page.similar.length} similar shelves',
      );
      _saveCache();
    } catch (error) {
      _error = error;
      log?.call(
        'for-you refresh failed after ${clock.elapsedMilliseconds} ms: '
        '${describeSyncError(error)}',
      );
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  static bool _isOwnKey(String key) =>
      key == forYouMixKey || key.startsWith(_similarKeyPrefix);

  // ---- The lists as places ----

  /// [list] as a place to open: an album ref whose link names the list.
  AlbumRef refOf(VkRecList list) => AlbumRef(
    title: list.title,
    link: (sourceId: _sourceId ?? 0, key: list.key, accessKey: list.accessKey),
  );

  /// The VK list a place shows, or null for another place.
  VkRecList? listOf(AlbumRef ref) =>
      lists.where((list) => list.key == ref.link?.key).firstOrNull;

  /// The "Similar to" shelf [shelf] as a place.
  AlbumRef refOfShelf(VkSongShelf shelf) {
    _songs['$_similarKeyPrefix${shelf.title}'] = shelf.songs;
    return AlbumRef(
      title: shelf.title,
      link: (
        sourceId: _sourceId ?? 0,
        key: '$_similarKeyPrefix${shelf.title}',
        accessKey: null,
      ),
    );
  }

  /// VK Mix as a place: the songs it played so far.
  AlbumRef get mixRef => AlbumRef(
    title: 'VK Mix',
    link: (sourceId: _sourceId ?? 0, key: forYouMixKey, accessKey: null),
  );

  // ---- Tracks ----

  final _ids = <String, int>{};
  final _byId = <int, VkRecSong>{};
  final _sourceOfId = <int, int>{};

  /// [song] as a song outside the library, streamed through the account
  /// it was recommended to. The same song keeps its id while the app runs.
  Track trackOf(VkRecSong song, [int? sourceId]) {
    final source = sourceId ?? _sourceId ?? 0;
    final id = _ids.putIfAbsent(
      '$source:${song.key}',
      () => _firstRecId - _ids.length,
    );
    _byId[id] = song;
    _sourceOfId[id] = source;
    final s = song.song;
    return Track(
      id: id,
      sourceId: source,
      source: TrackSource.vk,
      artist: s.artist,
      title: s.title,
      album: s.album,
      durationSec: s.durationSec,
      sourceKey: s.sourceKey,
      accessKey: s.accessKey,
      coverUrl: s.coverUrl,
      coverLargeUrl: s.coverLargeUrl,
      coverMidUrl: s.coverMidUrl,
      coverFullUrl: s.coverFullUrl,
      tint: s.tint,
    );
  }

  /// The recommended song behind the outside track [id], or null.
  VkRecSong? recSongOf(int id) => _byId[id];

  /// Whether [id] is a recommended song outside the library.
  bool isRec(int id) => _byId.containsKey(id);

  /// VK's restriction code of the outside track [id] (it cannot play);
  /// null for a song that plays and for any other song.
  int? restrictionOf(int id) => _byId[id]?.restricted;

  List<AlbumSong> _albumSongs(List<VkRecSong> songs) => [
    for (final song in songs)
      (track: trackOf(song), vkTrackId: song.song.vkTrackId),
  ];

  // ---- ListCatalog ----

  @override
  List<AlbumSong>? cached(AlbumRef list) {
    final key = list.link?.key;
    final songs = key == null ? null : _songs[key];
    return songs == null ? null : _albumSongs(songs);
  }

  @override
  Track? libraryCopyOf(AlbumSong song) {
    final rec = _byId[song.track.id];
    return rec == null ? null : libraryCopyOfSong(rec.song);
  }

  @override
  AlbumRef? albumOf(Track track) {
    final song = _byId[track.id]?.song;
    final title = song?.album;
    final key = song?.vkAlbumKey;
    if (song == null || title == null || title.isEmpty || key == null) {
      return null;
    }
    return AlbumRef(
      title: title,
      artist: song.artist,
      link: (
        sourceId: _sourceOfId[track.id] ?? track.sourceId,
        key: key,
        accessKey: song.vkAlbumAccessKey,
      ),
    );
  }

  @override
  List<int> libraryIds(AlbumRef album) => const [];

  @override
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds) => const {};

  @override
  bool canFetch(AlbumRef album) {
    final key = album.link?.key;
    if (key == null) return false;
    if (_isOwnKey(key)) return _songs.containsKey(key);
    return apiOfSource(album.link!.sourceId) != null;
  }

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) async {
    final link = album.link;
    if (link == null) throw const AlbumNotListed('VK did not list it');
    final at = cached(album);
    if (at != null) return at;
    final list = listOf(album);
    final call = apiOfSource(link.sourceId);
    if (list == null || call == null) {
      throw const AlbumNotListed('log in to the account it came from');
    }
    try {
      final songs = await fetchVkListSongs(call, list);
      _songs[list.key] = songs;
      _saveCache();
      return _albumSongs(songs);
    } catch (error) {
      throw AlbumNotListed('VK did not list it: ${describeSyncError(error)}');
    }
  }

  // ---- VK Mix ----

  bool _mixAsking = false;

  /// The songs VK Mix played or lined up in this run.
  List<VkRecSong> get mixSongs => songsOf(forYouMixKey);

  /// The next VK Mix songs as tracks: asked of VK and added to the mix's
  /// list. Empty when VK gives none or is asked already.
  Future<List<Track>> moreMix() async {
    final source = account;
    final call = source == null ? null : apiOfSource(source.id);
    if (call == null || _mixAsking) return const [];
    _mixAsking = true;
    final clock = Stopwatch()..start();
    try {
      final known = {for (final song in mixSongs) song.key};
      final fresh = [
        for (final song in await fetchVkMixSongs(call))
          if (song.playable && known.add(song.key)) song,
      ];
      _songs[forYouMixKey] = [...mixSongs, ...fresh];
      log?.call(
        'for-you mix: ${fresh.length} songs in ${clock.elapsedMilliseconds} ms',
      );
      _notify();
      return [for (final song in fresh) trackOf(song, source!.id)];
    } finally {
      _mixAsking = false;
    }
  }

  /// Whether [list], a play list, is VK Mix's.
  bool isMixList(List<Track> list) =>
      list.isNotEmpty && list.every((track) => _isMixSong(track.id));

  bool _isMixSong(int id) {
    final song = _byId[id];
    return song != null && mixSongs.any((s) => s.key == song.key);
  }

  // ---- Similar songs (C5) ----

  /// Songs VK finds similar to the VK song [sourceKey] (or to [artist] -
  /// [title] when VK has no recording id for it), as a place; null when VK
  /// knows nothing similar. Asked again, the place gets the new ones.
  Future<AlbumRef?> similarTo({
    required int sourceId,
    required String artist,
    required String title,
    String? sourceKey,
    bool hasTrackId = false,
  }) async {
    final call = apiOfSource(sourceId);
    if (call == null) return null;
    final clock = Stopwatch()..start();
    final target = await similarTargetOf(
      call,
      artist: artist,
      title: title,
      sourceKey: sourceKey,
      hasTrackId: hasTrackId,
    );
    if (target == null) return null;
    final key = '$_similarKeyPrefix$target';
    final known = {for (final song in songsOf(key)) song.key};
    final songs = [
      ...songsOf(key),
      for (final song in await fetchVkSimilarSongs(call, target))
        if (known.add(song.key)) song,
    ];
    log?.call(
      'for-you similar: ${songs.length} songs in '
      '${clock.elapsedMilliseconds} ms',
    );
    if (songs.isEmpty) return null;
    _songs[key] = songs;
    for (final song in songs) {
      trackOf(song, sourceId);
    }
    return AlbumRef(
      title: 'Similar to $artist - $title',
      link: (sourceId: sourceId, key: key, accessKey: null),
    );
  }

  /// Asks VK once more for songs similar to the place [ref] shows and adds
  /// the new ones (VK gives about 5 new a call). Returns how many came.
  Future<int> moreSimilar(AlbumRef ref) async {
    final key = ref.link?.key;
    final call = ref.link == null ? null : apiOfSource(ref.link!.sourceId);
    if (key == null || call == null || !key.startsWith(_similarKeyPrefix)) {
      return 0;
    }
    final target = key.substring(_similarKeyPrefix.length);
    final known = {for (final song in songsOf(key)) song.key};
    final fresh = [
      for (final song in await fetchVkSimilarSongs(call, target))
        if (known.add(song.key)) song,
    ];
    _songs[key] = [...songsOf(key), ...fresh];
    _notify();
    return fresh.length;
  }

  // ---- Dislike (A6) ----

  /// The thumb-down: a local record of the song, and VK's dislike mark on
  /// it through the account it came from (A6: VK's own app sends the same).
  /// Returns what the note says. The caller skips the song.
  Future<String> dislike(Track track) async {
    _recordDislike(track);
    final key = track.sourceKey;
    final call = apiOfSource(track.sourceId);
    if (track.source != TrackSource.vk || key == null || call == null) {
      return 'Skipped. Not sent to VK: no VK account for this song';
    }
    try {
      await dislikeVkSong(call, key);
      log?.call('for-you dislike sent');
      return 'Skipped. VK will recommend songs like this less often';
    } catch (error) {
      log?.call('for-you dislike failed: ${describeSyncError(error)}');
      return 'Skipped. VK did not take the dislike: '
          '${describeSyncError(error)}';
    }
  }

  void _recordDislike(Track track) {
    final dir = cacheDir;
    if (dir == null) return;
    try {
      File('$dir/dislikes.jsonl').writeAsStringSync(
        '${jsonEncode({'at': _now().toUtc().toIso8601String(), 'source': track.sourceId, 'key': track.sourceKey, 'artist': track.artist, 'title': track.title, 'length': track.durationSec})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      // The record is a convenience; the skip and VK's mark still happen.
    }
  }

  // ---- The cache file ----

  File? get _cacheFile =>
      cacheDir == null ? null : File('$cacheDir/for-you.json');

  void _loadCache() {
    if (_loadedCache) return;
    _loadedCache = true;
    final file = _cacheFile;
    if (file == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['version'] != 1) return;
      final page = json['page'] as Map<String, dynamic>;
      _page = VkMusicPage(
        lists: [
          for (final list in page['lists'] as List)
            VkRecList.fromJson(list as Map<String, dynamic>),
        ],
        similar: [
          for (final shelf in page['similar'] as List)
            VkSongShelf(
              title: shelf['title'] as String,
              blockId: shelf['blockId'] as String?,
              nextFrom: shelf['nextFrom'] as String?,
              songs: _songsFromJson(shelf['songs']),
            ),
        ],
        hasMix: page['hasMix'] == true,
      );
      for (final MapEntry(:key, :value)
          in (json['songs'] as Map<String, dynamic>).entries) {
        _songs[key] = _songsFromJson(value);
      }
      _sourceId = json['sourceId'] as int?;
      _fetchedAt = DateTime.fromMillisecondsSinceEpoch(
        json['savedAtMs'] as int,
      );
    } catch (error) {
      // A broken cache is as if there were none: VK is asked.
      _page = null;
      _songs.clear();
      _fetchedAt = null;
      log?.call('for-you cache unreadable: ${error.runtimeType}');
    }
  }

  void _saveCache() {
    final file = _cacheFile;
    final page = _page;
    if (file == null || page == null) return;
    final json = {
      'version': 1,
      'sourceId': _sourceId,
      'savedAtMs': (_fetchedAt ?? _now()).millisecondsSinceEpoch,
      'page': {
        'lists': [for (final list in page.lists) list.toJson()],
        'similar': [
          for (final shelf in page.similar)
            {
              'title': shelf.title,
              'blockId': shelf.blockId,
              'nextFrom': shelf.nextFrom,
              'songs': [for (final song in shelf.songs) recSongToJson(song)],
            },
        ],
        'hasMix': page.hasMix,
      },
      'songs': {
        for (final list in page.lists)
          if (_songs[list.key] case final songs?)
            list.key: [for (final song in songs) recSongToJson(song)],
      },
    };
    try {
      final temp = File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(json), flush: true);
      temp.renameSync(file.path);
    } on FileSystemException catch (error) {
      log?.call('for-you cache not saved: ${error.osError?.errorCode}');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A recommended song as the cache file keeps it: the library's fields and
/// the restriction code, no stream link.
Map<String, Object?> recSongToJson(VkRecSong song) {
  final s = song.song;
  return {
    'artist': s.artist,
    'title': s.title,
    'album': s.album,
    'length': s.durationSec,
    'date': s.addedAt,
    'key': s.sourceKey,
    'accessKey': s.accessKey,
    'cover': s.coverUrl,
    'coverLarge': s.coverLargeUrl,
    'coverMid': s.coverMidUrl,
    'coverFull': s.coverFullUrl,
    'tint': s.tint,
    'trackId': s.vkTrackId,
    'albumKey': s.vkAlbumKey,
    'albumAccessKey': s.vkAlbumAccessKey,
    'restricted': song.restricted,
  };
}

VkRecSong recSongFromJson(Map<String, dynamic> json) => VkRecSong(
  NewTrack(
    artist: json['artist'] as String? ?? '',
    title: json['title'] as String? ?? '',
    album: json['album'] as String?,
    durationSec: json['length'] as int? ?? 0,
    addedAt: json['date'] as int? ?? 0,
    sourceKey: json['key'] as String,
    accessKey: json['accessKey'] as String?,
    coverUrl: json['cover'] as String?,
    coverLargeUrl: json['coverLarge'] as String?,
    coverMidUrl: json['coverMid'] as String?,
    coverFullUrl: json['coverFull'] as String?,
    tint: json['tint'] as int?,
    vkTrackId: json['trackId'] as int?,
    vkAlbumKey: json['albumKey'] as String?,
    vkAlbumAccessKey: json['albumAccessKey'] as String?,
  ),
  restricted: json['restricted'] as int?,
);

List<VkRecSong> _songsFromJson(Object? list) => [
  for (final item in list as List? ?? const [])
    recSongFromJson(item as Map<String, dynamic>),
];
