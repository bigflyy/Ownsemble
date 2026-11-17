// The account's playlists on VK (plan 08): the ones the user made, the
// ones they follow, and the albums they follow, as audio.getPlaylists lists
// them on VK's "My playlists", and the songs of each.
//
// Stage A (tool/probe_playlists.dart, 2026-11-17): every item has the
// account as owner, followed ones too (they carry `original`); followed
// albums have type "album"; VK may state one more playlist than it gives
// (one held back), so pages advance by the asked size; songs read with
// audio.get album_id as albums do (album_id and playlist_id read the same).

import 'vk_album.dart';
import 'vk_client.dart';
import 'vk_recommendations.dart';

/// What a playlist is to the account.
enum VkPlaylistKind {
  /// Made by the user.
  made,

  /// Someone else's playlist the user follows.
  followed,

  /// An album the user follows (shown in an Albums view later, not with
  /// the playlists: user, 2026-11-17).
  album,
}

/// One playlist of the account, as VK's playlist list gives it.
class VkPlaylist {
  const VkPlaylist({
    required this.key,
    required this.accessKey,
    required this.title,
    required this.kind,
    required this.count,
    required this.updateTime,
    this.coverUrl,
    this.description = '',
  });

  /// "ownerId_id" of the account's own entry ([fetchVkPlaylistSongs]).
  final String key;
  final String? accessKey;
  final String title;
  final VkPlaylistKind kind;

  /// The song count VK states.
  final int count;

  /// When the playlist last changed, in seconds since 1970 UTC: a list
  /// whose time and count did not move has the same songs.
  final int updateTime;

  /// The playlist's own picture (300 px), or the first song cover VK shows
  /// for a made playlist without one; null when there is neither.
  final String? coverUrl;
  final String description;

  /// Whether the songs read before still stand: same time and count.
  bool sameSongsAs(VkPlaylist other) =>
      other.key == key &&
      other.updateTime == updateTime &&
      other.count == count;

  Map<String, Object?> toJson() => {
    'key': key,
    'accessKey': accessKey,
    'title': title,
    'kind': kind.name,
    'count': count,
    'updateTime': updateTime,
    'coverUrl': coverUrl,
    'description': description,
  };

  static VkPlaylist fromJson(Map<String, dynamic> json) => VkPlaylist(
    key: json['key'] as String,
    accessKey: json['accessKey'] as String?,
    title: json['title'] as String? ?? '',
    kind: VkPlaylistKind.values.byName(json['kind'] as String),
    count: json['count'] as int? ?? 0,
    updateTime: json['updateTime'] as int? ?? 0,
    coverUrl: json['coverUrl'] as String?,
    description: json['description'] as String? ?? '',
  );
}

/// One item of audio.getPlaylists as a [VkPlaylist]; null when it lacks
/// what a playlist needs (an id and an owner).
VkPlaylist? vkPlaylistOf(Object? item) {
  if (item is! Map<String, dynamic>) return null;
  final id = item['id'];
  final owner = item['owner_id'];
  if (id is! int || owner is! int) return null;
  final kind = item['type'] == 'album'
      ? VkPlaylistKind.album
      : item['original'] is Map
      ? VkPlaylistKind.followed
      : VkPlaylistKind.made;
  String? photoOf(Object? photo) => photo is Map
      ? (photo['photo_300'] ?? photo['photo_270']) as String?
      : null;
  final thumbs = item['thumbs'];
  return VkPlaylist(
    key: '${owner}_$id',
    accessKey: item['access_key'] as String?,
    title: item['title'] as String? ?? '',
    kind: kind,
    count: item['count'] as int? ?? 0,
    updateTime: item['update_time'] as int? ?? 0,
    coverUrl:
        photoOf(item['photo']) ??
        (thumbs is List && thumbs.isNotEmpty ? photoOf(thumbs.first) : null),
    description: item['description'] as String? ?? '',
  );
}

/// The playlists asked in one page.
const vkPlaylistPage = 200;

/// Every playlist of [ownerId] on VK's "My playlists", in VK's order.
Future<List<VkPlaylist>> fetchVkPlaylists(VkApiCall call, int ownerId) async {
  final lists = <VkPlaylist>[];
  final seen = <String>{};
  for (var offset = 0; ; offset += vkPlaylistPage) {
    final reply = await call('audio.getPlaylists', {
      'owner_id': '$ownerId',
      'count': '$vkPlaylistPage',
      'offset': '$offset',
    });
    if (reply is! Map<String, dynamic>) break;
    final items = reply['items'] as List? ?? const [];
    for (final item in items) {
      if (vkPlaylistOf(item) case final list? when seen.add(list.key)) {
        lists.add(list);
      }
    }
    // VK may state one more than it gives: the next page is asked by the
    // asked size, never by what came.
    final count = reply['count'] as int? ?? 0;
    if (items.isEmpty || offset + vkPlaylistPage >= count) break;
  }
  return lists;
}

/// The most songs read of one playlist (A1 saw 749).
const vkPlaylistSongLimit = 5000;

/// The songs of [list] in its order; VK gives no file for some
/// ([VkRecSong.restricted]).
Future<List<VkRecSong>> fetchVkPlaylistSongs(
  VkApiCall call,
  VkPlaylist list,
) async => vkRecSongsOf(
  await fetchVkAlbumItems(
    call,
    list.key,
    accessKey: list.accessKey,
    pageSize: 500,
    limit: vkPlaylistSongLimit,
  ),
);
