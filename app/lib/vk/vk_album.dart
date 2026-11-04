import 'vk_client.dart';

/// Most songs of one album that are listed; past this the album is cut off.
/// VK's albums have tens of songs, its biggest "albums" (collections) a few
/// hundred.
const vkAlbumSongLimit = 1000;

/// The songs of the VK album [albumKey] ("ownerId_albumId"), in the album's
/// order, as raw `audio.get` items. Read-only: `audio.get` with the album's
/// owner, id and access key (measured 360-430 ms for a 10-13 song album).
///
/// Pages advance by the page size asked for, not by the items received: VK
/// leaves blocked songs out of a page but counts them (see
/// `docs/VK_WEB_ACCESS.md`).
Future<List<Map<String, dynamic>>> fetchVkAlbumItems(
  VkApiCall call,
  String albumKey, {
  String? accessKey,
  int pageSize = 200,
  int limit = vkAlbumSongLimit,
}) async {
  final split = albumKey.lastIndexOf('_');
  if (split <= 0) throw ArgumentError.value(albumKey, 'albumKey');
  final owner = albumKey.substring(0, split);
  final album = albumKey.substring(split + 1);
  final items = <Map<String, dynamic>>[];
  for (var offset = 0; offset < limit; offset += pageSize) {
    final reply = await call('audio.get', {
      'owner_id': owner,
      'album_id': album,
      'access_key': ?accessKey,
      'count': '$pageSize',
      'offset': '$offset',
    }) as Map<String, dynamic>;
    items.addAll((reply['items'] as List).cast<Map<String, dynamic>>());
    final declared = reply['count'] as int? ?? 0;
    if (offset + pageSize >= declared) break;
  }
  return items.length > limit ? items.sublist(0, limit) : items;
}
