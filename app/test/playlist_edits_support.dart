// A fake VK for playlist edits (plan 08, Stage C) that does what real VK did
// on the test account (tool/probe_playlist_edits.dart, logs
// probe-edits-28a..h, plan 08 A2):
// - a new song goes on top; createPlaylist's audio_ids go in one by one, so
//   the last is on top;
// - a song of another owner goes in as a copy: the account as owner, a new
//   id, the same track_id, title, artist and length; adding that original
//   again makes another copy; a key of the account already there adds
//   nothing (but the reply still has one item);
// - a copy removed is gone: adding its key again replies an empty list;
// - removeFromPlaylist answers 1, or 0 when the key is not there;
// - audio.reorder answers 1 even when nothing moved; a song named by a key
//   that is not in the playlist with the playlist's owner: error 15;
// - update_time moves on add (when something went in), not on rename,
//   reorder or remove;
// - a followed playlist's copy has permissions edit=false: edits get 15.

import 'dart:async';

import 'package:ownsemble/vk/vk_client.dart';

/// One song as VK's audio.get items give it.
Map<String, dynamic> vkSongItem(
  int owner,
  int id, {
  int? trackId,
  String title = 'Песня',
  String artist = 'Исполнитель',
  int duration = 200,
}) => {
  'owner_id': owner,
  'id': id,
  'artist': artist,
  'title': title,
  'duration': duration,
  'url': 'https://example.invalid/$owner/$id.mp3',
  'track_id': ?trackId,
};

class FakePlaylist {
  FakePlaylist(this.id, this.title, {this.followedFrom});
  final int id;
  String title;
  final List<Map<String, dynamic>> songs = [];
  int updateTime = 1000;

  /// "ownerId_id" of the original, for a followed playlist's copy.
  final String? followedFrom;
}

class EditVk {
  EditVk({this.me = 10000});

  final int me;
  final playlists = <FakePlaylist>[];

  /// Every song VK knows by its key ("ownerId_id"), the account's library
  /// and others alike.
  final known = <String, Map<String, dynamic>>{};
  int _nextId = 9000;
  int _clock = 1000;

  /// Calls in order: "method key=value ...", ids only.
  final calls = <String>[];

  /// While set, each call waits for it (a slow VK).
  Completer<void>? gate;

  /// Methods that fail as if the connection broke (after VK did the work
  /// when in [failAfterDoing]).
  final failing = <String>{};
  final failAfterDoing = <String>{};

  Map<String, dynamic> song(int owner, int id, {int? trackId, int? duration}) {
    final item = vkSongItem(
      owner,
      id,
      trackId: trackId,
      duration: duration ?? 200,
      title: 'Песня $id',
    );
    known['${owner}_$id'] = item;
    return item;
  }

  FakePlaylist made(
    String title, [
    List<Map<String, dynamic>> songs = const [],
  ]) {
    final list = FakePlaylist(_nextId++, title)..songs.addAll(songs);
    playlists.insert(0, list);
    return list;
  }

  FakePlaylist followed(String title, String originalKey) {
    final list = FakePlaylist(_nextId++, title, followedFrom: originalKey);
    playlists.insert(0, list);
    return list;
  }

  FakePlaylist byId(int id) => playlists.firstWhere((list) => list.id == id);

  List<String> keysOf(FakePlaylist list) => [
    for (final item in list.songs) '${item['owner_id']}_${item['id']}',
  ];

  Map<String, dynamic> _item(FakePlaylist list) => {
    'id': list.id,
    'owner_id': me,
    'title': list.title,
    'count': list.songs.length,
    'update_time': list.updateTime,
    'access_key': 'ak-${list.id}',
    'permissions': {'edit': list.followedFrom == null},
    if (list.followedFrom case final from?)
      'original': {
        'owner_id': int.parse(from.split('_')[0]),
        'playlist_id': int.parse(from.split('_')[1]),
        'access_key': 'ak-original',
      },
  };

  /// Adds [ref] ("o_i" or "o_i_accessKey") on top of [list]; whether
  /// something went in.
  bool _add(FakePlaylist list, String ref) {
    final parts = ref.split('_');
    final key = '${parts[0]}_${parts[1]}';
    final item = known[key];
    if (item == null) return false;
    if (item['owner_id'] == me) {
      if (keysOf(list).contains(key)) return true;
      list.songs.insert(0, item);
      return true;
    }
    // Another owner's song: a copy of the account's, with a new id.
    final copy = {...item, 'owner_id': me, 'id': _nextId++};
    known['${me}_${copy['id']}'] = copy;
    list.songs.insert(0, copy);
    return true;
  }

  FakePlaylist _editable(Map<String, String> params) {
    final list = byId(int.parse(params['playlist_id']!));
    if (list.followedFrom != null || params['owner_id'] != '$me') {
      throw VkException('error 15: Access denied', code: 15);
    }
    return list;
  }

  Future<Object?> call(String method, Map<String, String> params) async {
    calls.add(
      [
        method,
        for (final name in [
          'playlist_id',
          'album_id',
          'audio_ids',
          'audio_id',
          'before',
          'after',
          'title',
        ])
          if (params[name] case final value?) '$name=$value',
      ].join(' '),
    );
    await Future<void>.delayed(Duration.zero);
    if (gate case final waiting?) await waiting.future;
    if (failing.contains(method)) {
      throw VkException('$method: connection lost', transient: true);
    }
    final reply = _do(method, params);
    if (failAfterDoing.contains(method)) {
      throw VkException('$method: connection lost', transient: true);
    }
    return reply;
  }

  Object? _do(String method, Map<String, String> params) {
    switch (method) {
      case 'audio.getPlaylists':
        return {
          'count': playlists.length,
          'items': [for (final list in playlists) _item(list)],
        };
      case 'audio.getPlaylistById':
        final id = int.parse(params['playlist_id']!);
        final list = playlists.where((l) => l.id == id).firstOrNull;
        if (list == null) {
          throw VkException('error 100: playlist not found', code: 100);
        }
        return _item(list);
      case 'audio.get':
        final id = int.parse((params['album_id'] ?? params['playlist_id'])!);
        final list = playlists.where((l) => l.id == id).firstOrNull;
        if (list == null) {
          throw VkException('error 100: playlist not found', code: 100);
        }
        final offset = int.parse(params['offset'] ?? '0');
        final count = int.parse(params['count'] ?? '100');
        return {
          'count': list.songs.length,
          'items': list.songs.skip(offset).take(count).toList(),
        };
      case 'audio.createPlaylist':
        final list = made(params['title']!);
        for (final ref in (params['audio_ids'] ?? '').split(',')) {
          if (ref.isNotEmpty) _add(list, ref);
        }
        list.updateTime = ++_clock;
        return _item(list);
      case 'audio.editPlaylist':
        final list = _editable(params);
        if (params['title'] case final title?) list.title = title;
        return 1;
      case 'audio.addToPlaylist':
        final list = _editable(params);
        final went = [
          for (final ref in params['audio_ids']!.split(','))
            if (_add(list, ref)) {'audio_id': ref},
        ];
        if (went.isNotEmpty) list.updateTime = ++_clock;
        return went;
      case 'audio.removeFromPlaylist':
        final list = _editable(params);
        final key = params['audio_ids']!;
        final at = keysOf(list).indexOf(key);
        if (at < 0) return 0;
        final removed = list.songs.removeAt(at);
        // A removed copy is gone for good.
        if (removed['owner_id'] == me && !_isLibrary(key)) known.remove(key);
        return 1;
      case 'audio.reorder':
        final list = _editable({...params, 'owner_id': '$me'});
        final key = '${params['owner_id']}_${params['audio_id']}';
        final keys = keysOf(list);
        final from = keys.indexOf(key);
        if (from < 0) throw VkException('error 15: Access denied', code: 15);
        final neighbourId = params['before'] ?? params['after'];
        final to = keys.indexWhere((k) => k.split('_')[1] == neighbourId);
        if (to < 0 || to == from) return 1;
        final item = list.songs.removeAt(from);
        final at = keysOf(list)
            .indexWhere((k) => k.split('_')[1] == neighbourId);
        list.songs.insert(params['before'] != null ? at : at + 1, item);
        return 1;
      case 'audio.deletePlaylist':
        final id = int.parse(params['playlist_id']!);
        final had = playlists.length;
        playlists.removeWhere((list) => list.id == id);
        return playlists.length < had ? 1 : 0;
    }
    throw StateError('unexpected $method');
  }

  /// Keys of the account's library songs (they stay known when taken out
  /// of a playlist); set by the test.
  final library = <String>{};
  bool _isLibrary(String key) => library.contains(key);
}
