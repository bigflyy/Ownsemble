import '../library/library_store.dart';
import 'vk_client.dart';

/// Result of reading the VK library page by page.
class VkLibrary {
  const VkLibrary(this.items, this.declaredCount, this.pages);

  /// Raw `audio.get` items, newest first.
  final List<Map<String, dynamic>> items;

  /// Count VK reports, including blocked songs it does not return.
  final int declaredCount;
  final int pages;
}

/// Reads the whole VK library of [ownerId].
///
/// VK omits blocked songs from a page but still counts them in the offset, so
/// the offset advances by the requested page size, never by the number of
/// items received, and reading stops at the declared count.
Future<VkLibrary> fetchVkLibrary(
  VkApiCall call,
  int ownerId, {
  int pageSize = 200,
}) async {
  final items = <Map<String, dynamic>>[];
  var declaredCount = 0;
  var offset = 0;
  var pages = 0;
  do {
    final page = await call('audio.get', {
      'owner_id': '$ownerId',
      'count': '$pageSize',
      'offset': '$offset',
    }) as Map<String, dynamic>;
    pages++;
    declaredCount = page['count'] as int;
    items.addAll((page['items'] as List).cast<Map<String, dynamic>>());
    offset += pageSize;
  } while (offset < declaredCount);
  return VkLibrary(items, declaredCount, pages);
}

/// The library key of a VK song: "ownerId_audioId".
String vkSourceKey(Map<String, dynamic> item) =>
    '${item['owner_id']}_${item['id']}';

/// Converts one `audio.get` item into a library song.
///
/// Covers come from the item's own `thumb` (VK sends one for every song in
/// the test library), else from its album's.
NewTrack vkItemToTrack(Map<String, dynamic> item) {
  final album = item['album'];
  final thumb =
      _mapOrNull(item['thumb']) ??
      (album is Map<String, dynamic> ? _mapOrNull(album['thumb']) : null);
  return NewTrack(
    sourceKey: vkSourceKey(item),
    accessKey: item['access_key'] as String?,
    artist: (item['artist'] as String?)?.trim() ?? '',
    title: (item['title'] as String?)?.trim() ?? '',
    album: album is Map<String, dynamic> ? album['title'] as String? : null,
    durationSec: item['duration'] as int? ?? 0,
    addedAt: item['date'] as int? ?? 0,
    coverUrl: thumb?['photo_135'] as String?,
    coverLargeUrl: thumb?['photo_600'] as String?,
    tint: parseVkColor(item['main_color']),
  );
}

Map<String, dynamic>? _mapOrNull(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// Parses VK's "#rrggbb" color into opaque 0xAARRGGBB, or null.
int? parseVkColor(Object? value) {
  if (value is! String) return null;
  final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value.trim());
  if (match == null) return null;
  return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
}
