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
///
/// Edits (plan 08, Stage C) are written to VK at once and the playlist is
/// then read back, also when the write failed (VK may have done it), so the
/// app holds VK's own keys and order. Edits and refreshes run one after
/// another ([VkPlaylists._inTurn]): a refresh never lands on top of an
/// edit. A removal or an unfollow waits for its Undo bar ([HeldEdit]): a
/// removed copy of another owner's song cannot be added back
/// (probe-edits-28h).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_playlist_edits.dart';
import '../vk/vk_playlists.dart';
import '../vk/vk_recommendations.dart';
import '../vk/vk_sync.dart' show describeSyncError;
import 'albums.dart';
import 'for_you.dart' show recSongFromJson, recSongToJson, songCacheVersion;
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

/// How an edit ended, in words for the bar at the bottom.
class PlaylistEdit {
  const PlaylistEdit(this.ok, this.note, {this.key});

  /// Whether VK has the change now.
  final bool ok;
  final String note;

  /// The playlist made by [VkPlaylists.create].
  final String? key;
}

/// A removal or an unfollow shown at once and sent when its Undo bar
/// closes without Undo ([commit]); [undo] before that sends nothing.
class HeldEdit {
  HeldEdit._(this._undo, this._commit);

  final void Function() _undo;
  final Future<PlaylistEdit> Function() _commit;
  Future<PlaylistEdit>? _sent;
  bool _undone = false;

  /// Whether the edit is still only shown, not sent.
  bool get waiting => _sent == null && !_undone;

  /// Takes the edit back; too late once it is sent.
  void undo() {
    if (!waiting) return;
    _undone = true;
    _undo();
  }

  /// Sends the edit to VK (once).
  Future<PlaylistEdit> commit() {
    if (_undone) return Future.value(const PlaylistEdit(true, ''));
    return _sent ??= _commit();
  }
}

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

  /// How often the songs of each playlist were set by a refresh or an
  /// edit: an on-demand fetch keeps what it read only if no one set them
  /// meanwhile.
  final _songsSet = <String, int>{};

  /// Songs hidden by a removal that waits for its Undo bar, by playlist.
  final _heldSongs = <String, Set<String>>{};

  /// Playlists hidden by an unfollow that waits for its Undo bar.
  final _heldLists = <String>{};

  /// The end of the line of refreshes and edits; null while none waits or
  /// runs (a new line starts in the caller's zone, so tests that fake time
  /// run it).
  Future<void>? _line;
  int _inLine = 0;
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
                  if (list.kind != VkPlaylistKind.album &&
                      !_heldLists.contains(list.key))
                    list,
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

  /// The songs of the playlist [key] as they are at hand, without the ones
  /// a removal waiting for its Undo bar hides.
  List<VkRecSong> songsOf(String key) {
    _loadCache();
    return _shownSongs(key) ?? const [];
  }

  List<VkRecSong>? _shownSongs(String key) {
    final songs = _songs[key];
    final held = _heldSongs[key];
    if (songs == null || held == null || held.isEmpty) return songs;
    return [
      for (final song in songs)
        if (!held.contains(song.key)) song,
    ];
  }

  void _setSongs(String key, List<VkRecSong> songs) {
    _songs[key] = songs;
    _songsSet[key] = (_songsSet[key] ?? 0) + 1;
  }

  /// The playlists of [sourceId] that take edits (made by the account), in
  /// VK's order.
  List<VkPlaylist> editableOf(int sourceId) => [
    for (final list in allOf(sourceId))
      if (list.editable &&
          list.kind == VkPlaylistKind.made &&
          !_heldLists.contains(list.key))
        list,
  ];

  /// The current title of the playlist a place shows (a rename keeps the
  /// place); the place's own for any other.
  String titleOf(AlbumRef ref) => playlistOf(ref)?.title ?? ref.title;

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
  Future<void> refresh() => _waitingRefresh ??= _inTurn(() {
    _waitingRefresh = null;
    return _refresh();
  });

  /// A refresh asked for that has not begun: a second ask joins it.
  Future<void>? _waitingRefresh;

  /// Runs [job] after every refresh and edit asked before it.
  Future<T> _inTurn<T>(Future<T> Function() job) {
    _inLine++;
    final result = (_line ?? Future<void>.value()).then((_) => job());
    final end = result.then<void>((_) {}, onError: (Object _) {});
    _line = end.whenComplete(() {
      if (--_inLine == 0) _line = null;
    });
    return result;
  }

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
    // A made playlist is read every time: a reorder or a rename on vk.com
    // moves neither its update time nor its count (probe-edits-28a, B17).
    final changed = [
      for (final list in fresh)
        if (list.kind == VkPlaylistKind.made ||
            !(old[list.key]?.sameSongsAs(list) ?? false) ||
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
              _setSongs(list.key, await fetchVkPlaylistSongs(call, list));
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
      if (!keys.contains(key)) {
        _songs.remove(key);
        _songsSet.remove(key);
      }
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

  // ---- Edits (plan 08, Stage C) ----

  VkPlaylist? _listOf(int sourceId, String key) =>
      allOf(sourceId).where((list) => list.key == key).firstOrNull;

  /// The account's VK client and the playlist [key], or null with [refuse]
  /// told why an edit cannot go.
  ({VkApiCall call, VkPlaylist list})? _editable(
    int sourceId,
    String key,
    void Function(String why) refuse,
  ) {
    final list = _listOf(sourceId, key);
    final call = apiOfSource(sourceId);
    if (list == null) {
      refuse('VK no longer lists this playlist');
    } else if (!list.editable) {
      refuse('Only your own playlists can be changed');
    } else if (call == null) {
      refuse('Log in to the account the playlist is on');
    } else {
      return (call: call, list: list);
    }
    return null;
  }

  /// Whether the playlist [key] has [track]: the same VK key (any account's
  /// copy of a library song), a song the library matches to [track] (as
  /// the place shows it), or a copy VK made of the same recording (track
  /// id and length, [playlistHasSong]).
  bool hasSong(String key, Track track) {
    final songs = songsOf(key);
    final keys = {
      ?track.sourceKey,
      for (final copy in track.allCopies) ?copy.sourceKey,
    };
    for (final song in songs) {
      if (keys.contains(song.key)) return true;
      if (track.inLibrary &&
          outside.libraryCopyOfSong(song.song)?.id == track.id) {
        return true;
      }
    }
    final rec = outside.songOf(track.id);
    return rec != null &&
        playlistHasSong(
          songs,
          rec.key,
          rec.song.vkTrackId,
          rec.song.durationSec,
        );
  }

  /// [track] as VK's audio_ids take it for the account [sourceId]: that
  /// account's copy of a library song when it has one.
  String? _songRefOf(int sourceId, Track track) {
    final rec = outside.songOf(track.id);
    if (rec != null) return vkSongRef(rec.key, rec.song.accessKey);
    final copies = [
      for (final copy in track.allCopies)
        if (copy.sourceKey != null) copy,
    ];
    final best =
        copies
            .where((c) => c.sourceId == sourceId && c.goneAtMs == null)
            .firstOrNull ??
        copies.where((c) => c.goneAtMs == null).firstOrNull ??
        copies.firstOrNull;
    return best == null ? null : vkSongRef(best.sourceKey!, best.accessKey);
  }

  /// Reads the playlist [list] back from VK and keeps VK's state: true
  /// when VK answered (also when the playlist is gone), false when not.
  Future<bool> _readBack(int sourceId, VkApiCall call, VkPlaylist list) async {
    try {
      final fresh = await fetchVkPlaylist(
        call,
        list.key,
        accessKey: list.accessKey,
      );
      if (fresh == null) {
        _drop(sourceId, list.key);
      } else {
        final songs = await fetchVkPlaylistSongs(call, fresh);
        _put(sourceId, fresh);
        _setSongs(fresh.key, songs);
      }
    } on VkException catch (error) {
      if (!_meansGone(error)) {
        log?.call('playlist read-back failed: ${describeSyncError(error)}');
        return false;
      }
      _drop(sourceId, list.key);
    } catch (error) {
      log?.call('playlist read-back failed: ${describeSyncError(error)}');
      return false;
    }
    _saveCache();
    _notify();
    return true;
  }

  /// VK's answer for a playlist that is not there (any more).
  static bool _meansGone(VkException error) => error.code == 100;

  /// Puts [list] in place of the account's entry with its key, or on top
  /// for a new one.
  void _put(int sourceId, VkPlaylist list) {
    final lists = [...allOf(sourceId)];
    final at = lists.indexWhere((l) => l.key == list.key);
    if (at < 0) {
      lists.insert(0, list);
    } else {
      lists[at] = list;
    }
    _lists[sourceId] = lists;
  }

  void _drop(int sourceId, String key) {
    _lists[sourceId] = [
      for (final list in allOf(sourceId))
        if (list.key != key) list,
    ];
    _songs.remove(key);
    _songsSet.remove(key);
    _heldSongs.remove(key);
    _heldLists.remove(key);
  }

  static String _noAnswer(Object? error) => error == null
      ? 'VK did not answer'
      : 'VK did not answer: ${describeSyncError(error)}';

  /// Puts [track] on top of the playlist [key] of [sourceId], as VK does.
  Future<PlaylistEdit> addSong(int sourceId, String key, Track track) =>
      _inTurn(() async {
        String? why;
        final at = _editable(sourceId, key, (w) => why = w);
        if (at == null) return PlaylistEdit(false, why!);
        final (:call, :list) = at;
        if (hasSong(key, track)) {
          return PlaylistEdit(false, 'Already in ${list.title}');
        }
        final ref = _songRefOf(sourceId, track);
        if (ref == null) {
          return const PlaylistEdit(false, 'This song is not on VK');
        }
        Object? error;
        try {
          await addToVkPlaylist(call, key, ref);
        } catch (e) {
          error = e;
        }
        if (!await _readBack(sourceId, call, list)) {
          return PlaylistEdit(false, _noAnswer(error));
        }
        final title = _listOf(sourceId, key)?.title ?? list.title;
        if (hasSong(key, track)) return PlaylistEdit(true, 'Added to $title');
        return PlaylistEdit(
          false,
          error == null ? 'VK did not add it to $title' : _noAnswer(error),
        );
      });

  /// Hides the song [songKey] of the playlist [key] now; [HeldEdit.commit]
  /// takes it out on VK.
  HeldEdit removeSong(int sourceId, String key, String songKey) {
    (_heldSongs[key] ??= {}).add(songKey);
    _notify();
    void show() {
      _heldSongs[key]?.remove(songKey);
      _notify();
    }

    return HeldEdit._(
      show,
      () => _inTurn(() async {
        String? why;
        final at = _editable(sourceId, key, (w) => why = w);
        if (at == null) {
          show();
          return PlaylistEdit(false, why!);
        }
        final (:call, :list) = at;
        Object? error;
        try {
          await removeFromVkPlaylist(call, key, songKey);
        } catch (e) {
          error = e;
        }
        final answered = await _readBack(sourceId, call, list);
        show();
        if (!answered) return PlaylistEdit(false, _noAnswer(error));
        final still = (_songs[key] ?? const []).any((s) => s.key == songKey);
        if (!still) return PlaylistEdit(true, 'Taken out of ${list.title}');
        return PlaylistEdit(
          false,
          error == null ? 'VK did not take the song out' : _noAnswer(error),
        );
      }),
    );
  }

  /// Moves the song [songKey] of the playlist [key] just before
  /// [beforeKey] or just after [afterKey] (keys as the playlist read gives
  /// them); shown at once.
  Future<PlaylistEdit> moveSong(
    int sourceId,
    String key,
    String songKey, {
    String? beforeKey,
    String? afterKey,
  }) {
    final confirmed = _songs[key];
    final neighbour = beforeKey ?? afterKey;
    if (confirmed != null) {
      final moved = [...confirmed];
      final from = moved.indexWhere((s) => s.key == songKey);
      if (from >= 0) {
        final song = moved.removeAt(from);
        final next = moved.indexWhere((s) => s.key == neighbour);
        if (next >= 0) {
          moved.insert(beforeKey != null ? next : next + 1, song);
          _songs[key] = moved;
          _notify();
        }
      }
    }
    bool inPlace() {
      final keys = [
        for (final song in _songs[key] ?? const <VkRecSong>[]) song.key,
      ];
      final at = keys.indexOf(songKey);
      if (at < 0) return false;
      return beforeKey != null
          ? at + 1 < keys.length && keys[at + 1] == beforeKey
          : at > 0 && keys[at - 1] == afterKey;
    }

    return _inTurn(() async {
      String? why;
      final at = _editable(sourceId, key, (w) => why = w);
      if (at == null) {
        if (confirmed != null) _songs[key] = confirmed;
        _notify();
        return PlaylistEdit(false, why!);
      }
      final (:call, :list) = at;
      Object? error;
      try {
        await moveInVkPlaylist(
          call,
          key,
          songKey,
          beforeKey: beforeKey,
          afterKey: afterKey,
        );
      } catch (e) {
        error = e;
      }
      if (!await _readBack(sourceId, call, list)) {
        if (confirmed != null) _songs[key] = confirmed;
        _notify();
        return PlaylistEdit(false, _noAnswer(error));
      }
      if (inPlace()) return const PlaylistEdit(true, 'Moved');
      return PlaylistEdit(
        false,
        error == null ? 'VK did not move the song' : _noAnswer(error),
      );
    });
  }

  /// Names the playlist [key] [title]; shown at once.
  Future<PlaylistEdit> rename(int sourceId, String key, String title) {
    final before = _listOf(sourceId, key);
    if (before != null && before.editable) {
      _put(sourceId, before.withTitle(title));
      _notify();
    }
    return _inTurn(() async {
      String? why;
      final at = _editable(sourceId, key, (w) => why = w);
      if (at == null) return PlaylistEdit(false, why!);
      final (:call, :list) = at;
      Object? error;
      try {
        await renameVkPlaylist(call, key, title);
      } catch (e) {
        error = e;
      }
      if (!await _readBack(sourceId, call, list)) {
        if (before != null) _put(sourceId, before);
        _notify();
        return PlaylistEdit(false, _noAnswer(error));
      }
      if (_listOf(sourceId, key)?.title == title) {
        return PlaylistEdit(true, 'Renamed to $title');
      }
      return PlaylistEdit(
        false,
        error == null ? 'VK did not rename it' : _noAnswer(error),
      );
    });
  }

  /// Makes a playlist [title] on the account [sourceId], with [first] in
  /// it; [PlaylistEdit.key] is the new playlist's.
  Future<PlaylistEdit> create(int sourceId, String title, {Track? first}) =>
      _inTurn(() async {
        final call = apiOfSource(sourceId);
        final account = accounts().where((a) => a.id == sourceId).firstOrNull;
        final owner = int.tryParse(account?.account ?? '');
        if (call == null || owner == null) {
          return const PlaylistEdit(false, 'Log in to the account first');
        }
        final ref = first == null ? null : _songRefOf(sourceId, first);
        final VkPlaylist made;
        try {
          made = await createVkPlaylist(call, owner, title, songs: [?ref]);
        } catch (error) {
          // VK may have made it: the account's playlists are read again.
          await _refreshAccount(sourceId, call, owner);
          _saveCache();
          _notify();
          return PlaylistEdit(false, _noAnswer(error));
        }
        _put(sourceId, made);
        _setSongs(made.key, const []);
        await _readBack(sourceId, call, made);
        _saveCache();
        _notify();
        return PlaylistEdit(true, 'Made $title', key: made.key);
      });

  /// Deletes the playlist [key] of [sourceId] on VK (the caller asks
  /// first: it cannot come back).
  Future<PlaylistEdit> delete(int sourceId, String key) => _inTurn(() async {
    String? why;
    final at = _editable(sourceId, key, (w) => why = w);
    if (at == null) return PlaylistEdit(false, why!);
    final (:call, :list) = at;
    return _deleteOnVk(sourceId, call, list, 'Deleted ${list.title}');
  });

  Future<PlaylistEdit> _deleteOnVk(
    int sourceId,
    VkApiCall call,
    VkPlaylist list,
    String done,
  ) async {
    Object? error;
    try {
      await deleteVkPlaylist(call, list.key);
      _drop(sourceId, list.key);
      _saveCache();
      _notify();
      return PlaylistEdit(true, done);
    } catch (e) {
      error = e;
    }
    if (!await _readBack(sourceId, call, list)) {
      return PlaylistEdit(false, _noAnswer(error));
    }
    if (_listOf(sourceId, list.key) == null) return PlaylistEdit(true, done);
    return PlaylistEdit(false, _noAnswer(error));
  }

  /// Hides the followed playlist [key] now; [HeldEdit.commit] unfollows it
  /// on VK (deletes the account's copy; the original stays).
  HeldEdit unfollow(int sourceId, String key) {
    _heldLists.add(key);
    _notify();
    void show() {
      _heldLists.remove(key);
      _notify();
    }

    return HeldEdit._(
      show,
      () => _inTurn(() async {
        final list = _listOf(sourceId, key);
        final call = apiOfSource(sourceId);
        if (list == null || call == null) {
          show();
          return PlaylistEdit(
            false,
            list == null
                ? 'VK no longer lists this playlist'
                : 'Log in to the account the playlist is on',
          );
        }
        final edit = await _deleteOnVk(
          sourceId,
          call,
          list,
          'Unfollowed ${list.title}',
        );
        show();
        return edit;
      }),
    );
  }

  // ---- ListCatalog ----

  @override
  List<AlbumSong>? cached(AlbumRef list) {
    final link = list.link;
    if (link == null || !isPlaylistRef(list)) return null;
    _loadCache();
    final songs = _shownSongs(link.key.substring(playlistKeyPrefix.length));
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
      final setBefore = _songsSet[list.key];
      final songs = await fetchVkPlaylistSongs(call, list);
      // A refresh or an edit that set the songs meanwhile read them later.
      if (_songsSet[list.key] == setBefore) {
        _setSongs(list.key, songs);
        _saveCache();
      }
      return outside.albumSongs(
        _shownSongs(list.key) ?? songs,
        album.link!.sourceId,
      );
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
      if (json['version'] != songCacheVersion) return;
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
      'version': songCacheVersion,
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
