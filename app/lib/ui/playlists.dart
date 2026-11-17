/// The Playlists place's data (plan 08, B1): every logged-in VK account's
/// playlists from VK's "My playlists" (made and followed; followed albums
/// are kept for an Albums view later, not shown), mirrored at each sync
/// (user, 2026-11-17: "yes changed made show up in the app").
///
/// A refresh asks VK for each account's list of playlists (one call per 200)
/// and then only the songs of playlists whose update time or count moved
/// (A1: update_time moves when the songs change). A playlist VK did not
/// answer for keeps the songs it had and is asked again at the next refresh.
/// The cache file playlists.json holds the lists and songs as the library
/// stores them (names, lengths, keys, cover links), never a stream link.
///
/// A playlist opens as an ordinary song list ([ListCatalog]): the library's
/// own song in place of each one it has, + on the others.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_playlists.dart';
import '../vk/vk_recommendations.dart';
import '../vk/vk_sync.dart' show describeSyncError;
import 'albums.dart';
import 'for_you.dart' show recSongFromJson, recSongToJson;
import 'outside_songs.dart';

/// Keys of playlist places start with this (VK's recommended lists have
/// keys of the same "ownerId_id" shape).
const playlistKeyPrefix = 'playlist:';

/// Whether the place [ref] is one of the account's playlists.
bool isPlaylistRef(AlbumRef ref) =>
    ref.link?.key.startsWith(playlistKeyPrefix) ?? false;

/// How many playlists' songs are read from VK at once.
const playlistReadsAtOnce = 4;

/// One account's playlists as the place shows them.
typedef AccountPlaylists = ({SourceInfo account, List<VkPlaylist> lists});

/// The account's playlists of every logged-in VK account.
class VkPlaylists extends ChangeNotifier implements ListCatalog {
  VkPlaylists({
    required this.accounts,
    required this.apiOfSource,
    required this.outside,
    this.cacheDir,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The VK accounts that are logged in, in the sources' order.
  final List<SourceInfo> Function() accounts;
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// The songs the library lacks, shared with For you.
  final OutsideSongs outside;

  /// Where playlists.json is kept; null keeps nothing (tests).
  final String? cacheDir;

  /// One line to perf.log: times and counts only.
  final void Function(String line)? log;
  final DateTime Function() _now;

  /// Each account's playlists in VK's order, by source id.
  final _lists = <int, List<VkPlaylist>>{};

  /// The songs of each playlist read so far, by its VK key.
  final _songs = <String, List<VkRecSong>>{};

  /// When each account's playlists last came from VK.
  final _fetchedAt = <int, DateTime>{};
  final _errors = <int, Object>{};
  bool _loadedCache = false;
  bool _refreshing = false;
  bool _disposed = false;

  /// Whether VK is being asked now.
  bool get refreshing => _refreshing;

  /// Whether any account's playlists came from VK once (now or in an
  /// earlier run).
  bool get hasLists {
    _loadCache();
    return accounts().any((a) => _lists.containsKey(a.id));
  }

  /// When the playlists of [sourceId] came from VK; null before the first
  /// answer.
  DateTime? fetchedAt(int sourceId) => _fetchedAt[sourceId];

  /// Why the last refresh of [sourceId] failed, in words for the banner;
  /// null when it did not. Never holds a link.
  String? errorOf(int sourceId) =>
      _errors[sourceId] == null ? null : describeSyncError(_errors[sourceId]!);

  /// The made and followed playlists of each logged-in account that has
  /// any, in VK's order; followed albums are left out.
  List<AccountPlaylists> get shown {
    _loadCache();
    return [
      for (final account in accounts())
        if (_lists[account.id] case final lists?)
          if ([
                for (final list in lists)
                  if (list.kind != VkPlaylistKind.album) list,
              ]
              case final shownLists when shownLists.isNotEmpty)
            (account: account, lists: shownLists),
    ];
  }

  /// Every playlist of [sourceId] VK gave, followed albums too.
  List<VkPlaylist> allOf(int sourceId) {
    _loadCache();
    return _lists[sourceId] ?? const [];
  }

  /// The songs of the playlist [key] as they are at hand.
  List<VkRecSong> songsOf(String key) {
    _loadCache();
    return _songs[key] ?? const [];
  }

  // ---- Opening and refreshing ----

  /// The place opened: the cached playlists at once, then VK in the
  /// background for an account never asked in this run.
  void open() {
    _loadCache();
    final asked = accounts().every((a) => _askedThisRun.contains(a.id));
    if (!asked) scheduleMicrotask(() => unawaited(refresh()));
  }

  final _askedThisRun = <int>{};

  /// Asks VK for every logged-in account's playlists and the songs of
  /// those whose update time or count moved. While VK is being asked, the
  /// same ask is returned; one asked for meanwhile runs after it.
  Future<void> refresh() {
    final running = _running;
    if (running == null) {
      return _running = _refresh().whenComplete(() => _running = null);
    }
    return _again ??= running.then((_) {
      _again = null;
      return refresh();
    });
  }

  Future<void>? _running;
  Future<void>? _again;

  Future<void> _refresh() async {
    _loadCache();
    final asking = [
      for (final account in accounts())
        if (apiOfSource(account.id) case final call?)
          if (int.tryParse(account.account ?? '') case final owner?)
            (account: account, call: call, owner: owner),
    ];
    if (asking.isEmpty) return;
    _refreshing = true;
    _notify();
    try {
      for (final (:account, :call, :owner) in asking) {
        await _refreshAccount(account.id, call, owner);
      }
      _saveCache();
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  Future<void> _refreshAccount(int sourceId, VkApiCall call, int owner) async {
    final clock = Stopwatch()..start();
    _askedThisRun.add(sourceId);
    final List<VkPlaylist> fresh;
    try {
      fresh = await fetchVkPlaylists(call, owner);
    } catch (error) {
      _errors[sourceId] = error;
      log?.call(
        'playlists refresh failed after ${clock.elapsedMilliseconds} ms: '
        '${describeSyncError(error)}',
      );
      return;
    }
    final listMs = clock.elapsedMilliseconds;
    final old = {for (final list in allOf(sourceId)) list.key: list};
    final changed = [
      for (final list in fresh)
        if (!(old[list.key]?.sameSongsAs(list) ?? false) ||
            !_songs.containsKey(list.key))
          list,
    ];
    final failed = <String>{};
    final queue = [...changed];
    await Future.wait([
      for (var i = 0; i < playlistReadsAtOnce; i++)
        () async {
          while (queue.isNotEmpty) {
            final list = queue.removeLast();
            try {
              _songs[list.key] = await fetchVkPlaylistSongs(call, list);
            } catch (_) {
              failed.add(list.key);
            }
          }
        }(),
    ]);
    // A playlist VK did not answer for keeps its songs and its old entry
    // (so the next refresh asks again); one VK no longer lists leaves.
    _lists[sourceId] = [
      for (final list in fresh)
        if (failed.contains(list.key)) old[list.key] ?? list else list,
    ];
    final keys = {for (final list in fresh) list.key};
    for (final key in old.keys) {
      if (!keys.contains(key)) _songs.remove(key);
    }
    _fetchedAt[sourceId] = _now();
    _errors.remove(sourceId);
    log?.call(
      'playlists refresh: list $listMs ms, ${changed.length} of '
      '${fresh.length} playlists read in '
      '${clock.elapsedMilliseconds - listMs} ms, ${failed.length} failed',
    );
  }

  // ---- The playlists as places ----

  /// The playlist [list] of the account [sourceId] as a place to open.
  AlbumRef refOf(int sourceId, VkPlaylist list) => AlbumRef(
    title: list.title,
    link: (
      sourceId: sourceId,
      key: '$playlistKeyPrefix${list.key}',
      accessKey: list.accessKey,
    ),
  );

  /// The playlist a place shows, or null for another place.
  VkPlaylist? playlistOf(AlbumRef ref) {
    final link = ref.link;
    if (link == null || !isPlaylistRef(ref)) return null;
    final key = link.key.substring(playlistKeyPrefix.length);
    return allOf(link.sourceId).where((list) => list.key == key).firstOrNull;
  }

  // ---- ListCatalog ----

  @override
  List<AlbumSong>? cached(AlbumRef list) {
    final link = list.link;
    if (link == null || !isPlaylistRef(list)) return null;
    _loadCache();
    final songs = _songs[link.key.substring(playlistKeyPrefix.length)];
    return songs == null ? null : outside.albumSongs(songs, link.sourceId);
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
  bool canFetch(AlbumRef album) =>
      cached(album) != null ||
      isPlaylistRef(album) && apiOfSource(album.link!.sourceId) != null;

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) async {
    final at = cached(album);
    if (at != null) return at;
    final list = playlistOf(album);
    final call = album.link == null ? null : apiOfSource(album.link!.sourceId);
    if (call == null) {
      throw const AlbumNotListed('log in to the account it came from');
    }
    if (list == null) {
      throw const AlbumNotListed(
        'VK no longer lists this playlist for the account',
      );
    }
    try {
      final songs = await fetchVkPlaylistSongs(call, list);
      _songs[list.key] = songs;
      _saveCache();
      return outside.albumSongs(songs, album.link!.sourceId);
    } catch (error) {
      throw AlbumNotListed('VK did not list it: ${describeSyncError(error)}');
    }
  }

  // ---- The cache file ----

  File? get _cacheFile =>
      cacheDir == null ? null : File('$cacheDir/playlists.json');

  void _loadCache() {
    if (_loadedCache) return;
    _loadedCache = true;
    final file = _cacheFile;
    if (file == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['version'] != 1) return;
      for (final MapEntry(:key, :value)
          in (json['accounts'] as Map<String, dynamic>).entries) {
        final account = value as Map<String, dynamic>;
        final id = int.parse(key);
        _lists[id] = [
          for (final list in account['lists'] as List)
            VkPlaylist.fromJson(list as Map<String, dynamic>),
        ];
        _fetchedAt[id] = DateTime.fromMillisecondsSinceEpoch(
          account['savedAtMs'] as int,
        );
      }
      for (final MapEntry(:key, :value)
          in (json['songs'] as Map<String, dynamic>).entries) {
        _songs[key] = [
          for (final song in value as List)
            recSongFromJson(song as Map<String, dynamic>),
        ];
      }
    } catch (error) {
      // A broken cache is as if there were none: VK is asked.
      _lists.clear();
      _songs.clear();
      _fetchedAt.clear();
      log?.call('playlists cache unreadable: ${error.runtimeType}');
    }
  }

  void _saveCache() {
    final file = _cacheFile;
    if (file == null) return;
    final json = {
      'version': 1,
      'accounts': {
        for (final MapEntry(:key, :value) in _lists.entries)
          '$key': {
            'savedAtMs': (_fetchedAt[key] ?? _now()).millisecondsSinceEpoch,
            'lists': [for (final list in value) list.toJson()],
          },
      },
      'songs': {
        for (final MapEntry(:key, :value) in _songs.entries)
          key: [for (final song in value) recSongToJson(song)],
      },
    };
    try {
      final temp = File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(json), flush: true);
      temp.renameSync(file.path);
    } on FileSystemException catch (error) {
      log?.call('playlists cache not saved: ${error.osError?.errorCode}');
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

/// The list catalog of the running app: the playlists answer for playlist
/// places, For you for its lists; both share one [OutsideSongs], so a song
/// is the same in either.
class CombinedLists implements ListCatalog {
  const CombinedLists({required this.playlists, required this.others});

  final VkPlaylists playlists;
  final ListCatalog others;

  ListCatalog _of(AlbumRef ref) => isPlaylistRef(ref) ? playlists : others;

  @override
  List<AlbumSong>? cached(AlbumRef list) => _of(list).cached(list);

  @override
  bool canFetch(AlbumRef album) => _of(album).canFetch(album);

  @override
  Future<List<AlbumSong>> fetch(AlbumRef album) => _of(album).fetch(album);

  @override
  Track? libraryCopyOf(AlbumSong song) =>
      playlists.libraryCopyOf(song) ?? others.libraryCopyOf(song);

  @override
  AlbumRef? albumOf(Track track) =>
      playlists.albumOf(track) ?? others.albumOf(track);

  @override
  List<int> libraryIds(AlbumRef album) => const [];

  @override
  Map<int, int> libraryIdsByVkTrackId(Iterable<int> vkTrackIds) => const {};
}
