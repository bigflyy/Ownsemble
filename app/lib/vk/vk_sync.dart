import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../library/library_store.dart';
import '../library/track.dart';
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
///
/// If the declared count changes between pages, songs were added or removed
/// while reading and the offsets no longer line up (a song could be skipped
/// and then look removed), so reading starts over, up to [restarts] times.
/// [onPage] reports pages read and the pages expected in total.
Future<VkLibrary> fetchVkLibrary(
  VkApiCall call,
  int ownerId, {
  int pageSize = 200,
  int restarts = 2,
  void Function(int pagesRead, int pagesTotal)? onPage,
}) async {
  for (var attempt = 0; ; attempt++) {
    final items = <Map<String, dynamic>>[];
    int? declaredCount;
    var offset = 0;
    var pages = 0;
    var shifted = false;
    do {
      final page = await call('audio.get', {
        'owner_id': '$ownerId',
        'count': '$pageSize',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      pages++;
      final count = page['count'] as int;
      if (declaredCount != null && count != declaredCount) {
        shifted = true;
        break;
      }
      declaredCount = count;
      items.addAll((page['items'] as List).cast<Map<String, dynamic>>());
      offset += pageSize;
      onPage?.call(pages, count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize);
    } while (offset < declaredCount);
    if (!shifted) return VkLibrary(items, declaredCount, pages);
    if (attempt >= restarts) {
      throw VkException('the VK library kept changing while it was read');
    }
  }
}

/// Which of the [missing] songs are gone from VK.
///
/// [missing] maps the keys the library has but VK no longer lists to their
/// access keys. When VK listed every song it counts ([vkHidSongs] false), a
/// missing song is not in the VK library any more. Otherwise VK hid some
/// blocked songs, and a missing song may be one of them, so each is looked up
/// with `audio.getById` (in batches of [batchSize]):
/// - not found: deleted, gone;
/// - found with a stream: VK never hides playable songs, so it was removed
///   from the library, gone;
/// - found without a stream: blocked, maybe one of the hidden songs, kept.
Future<Set<String>> findGoneKeys(
  VkApiCall call,
  Map<String, String?> missing, {
  required bool vkHidSongs,
  int batchSize = 50,
  void Function(int checked, int total)? onChecked,
}) async {
  if (!vkHidSongs) return missing.keys.toSet();
  final gone = <String>{};
  final keys = missing.keys.toList();
  for (var start = 0; start < keys.length; start += batchSize) {
    final batch = keys.sublist(start, min(start + batchSize, keys.length));
    final reply = await call('audio.getById', {
      'audios': [
        for (final key in batch)
          missing[key] == null ? key : '${key}_${missing[key]}',
      ].join(','),
    }) as List;
    final found = {
      for (final item in reply.cast<Map<String, dynamic>>())
        vkSourceKey(item): item,
    };
    for (final key in batch) {
      final item = found[key];
      final hasStream = ((item?['url'] as String?) ?? '').isNotEmpty;
      if (item == null || hasStream) gone.add(key);
    }
    onChecked?.call(start + batch.length, keys.length);
  }
  return gone;
}

/// Where a sync is, for the progress line.
enum SyncStage { connecting, reading, checking, saving }

/// Progress of one sync.
class SyncProgress {
  const SyncProgress(this.stage, {this.done = 0, this.total = 0});

  final SyncStage stage;

  /// Pages read (reading) or songs looked up (checking) so far.
  final int done;
  final int total;

  /// Rough share of the whole sync that is finished, 0 to 1. Reading the
  /// pages is most of the time; the gone check and saving are short.
  double get fraction {
    final part = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return switch (stage) {
      SyncStage.connecting => 0.02,
      SyncStage.reading => 0.05 + 0.75 * part,
      SyncStage.checking => 0.8 + 0.15 * part,
      SyncStage.saving => 0.95,
    };
  }
}

/// What one sync of a VK account changed.
class VkSyncResult {
  const VkSyncResult({
    required this.sourceId,
    required this.listed,
    required this.declared,
    required this.added,
    required this.updated,
    required this.back,
    required this.newlyGone,
  });

  final int sourceId;

  /// Songs VK listed, and the count it declared (it hides some blocked songs).
  final int listed;
  final int declared;

  /// Songs new to the library.
  final int added;

  /// Known songs whose details (title, cover, ...) changed.
  final int updated;

  /// Songs marked gone earlier that VK lists again.
  final int back;

  /// Songs marked gone by this sync.
  final int newlyGone;

  /// Whether the library the UI shows is out of date after this sync.
  bool get changedLibrary => added + updated + back + newlyGone > 0;
}

/// Syncs the VK library of [userId] into [store]: adds new songs, updates
/// changed ones and marks songs VK no longer has as gone (see
/// [findGoneKeys]). Never deletes songs. Records the outcome on the source;
/// on failure records the reason and rethrows, leaving gone marks untouched.
Future<VkSyncResult> syncVkSource({
  required VkApiCall call,
  required int userId,
  required LibraryStore store,
  void Function(SyncProgress progress)? onProgress,
  int pageSize = 200,
}) async {
  final sourceId = store.ensureSource(
    TrackSource.vk,
    account: '$userId',
    name: 'VK',
  );
  try {
    onProgress?.call(const SyncProgress(SyncStage.reading));
    final library = await fetchVkLibrary(
      call,
      userId,
      pageSize: pageSize,
      onPage: (read, total) => onProgress?.call(
        SyncProgress(SyncStage.reading, done: read, total: total),
      ),
    );
    final known = store.trackKeys(sourceId);
    final listed = {for (final item in library.items) vkSourceKey(item)};
    final missing = {
      for (final MapEntry(:key, :value) in known.entries)
        if (value.goneAtMs == null && !listed.contains(key))
          key: value.accessKey,
    };
    final gone = await findGoneKeys(
      call,
      missing,
      vkHidSongs: library.items.length < library.declaredCount,
      onChecked: (checked, total) => onProgress?.call(
        SyncProgress(SyncStage.checking, done: checked, total: total),
      ),
    );

    onProgress?.call(const SyncProgress(SyncStage.saving));
    final fresh = library.items.map(vkItemToTrack).toList();
    final written = store.upsertTracks(sourceId, [
      for (final track in fresh) _keepSameCovers(track, known[track.sourceKey]),
    ]);
    // Only some of VK's image hosts hold a given image, and which one a link
    // names changes with every request. So the newest link replaces the old
    // one, and a cover that failed gets another chance after the next start.
    store.updateCoverLinks(sourceId, fresh);
    final added = listed.where((key) => !known.containsKey(key)).length;
    final back = listed.where((key) => known[key]?.goneAtMs != null).length;
    final newlyGone = store.markGone(sourceId, gone);
    store.recordSync(sourceId);
    return VkSyncResult(
      sourceId: sourceId,
      listed: library.items.length,
      declared: library.declaredCount,
      added: added,
      updated: written.changedIds.length - added - back,
      back: back,
      newlyGone: newlyGone,
    );
  } catch (error) {
    store.recordSync(sourceId, error: describeSyncError(error));
    rethrow;
  }
}

/// [fresh] with the stored cover links of [known] where VK only moved the
/// same image to another host.
///
/// VK serves a cover from a different image server on almost every request
/// (same path and query); without this every sync would count most songs as
/// changed and reload the library.
NewTrack _keepSameCovers(NewTrack fresh, KnownTrack? known) {
  if (known == null) return fresh;
  String? keep(String? stored, String? link) =>
      _sameImage(stored, link) ? stored : link;
  return fresh.withCovers(
    coverUrl: keep(known.coverUrl, fresh.coverUrl),
    coverLargeUrl: keep(known.coverLargeUrl, fresh.coverLargeUrl),
    coverMidUrl: keep(known.coverMidUrl, fresh.coverMidUrl),
    coverFullUrl: keep(known.coverFullUrl, fresh.coverFullUrl),
  );
}

/// Whether two image links differ at most in their host.
bool _sameImage(String? a, String? b) {
  if (a == null || b == null) return a == b;
  final x = Uri.tryParse(a);
  final y = Uri.tryParse(b);
  return x != null && y != null && x.path == y.path && x.query == y.query;
}

/// A short reason for a failed sync, fit for the status bar. Never contains
/// links or tokens.
String describeSyncError(Object error) {
  final text = switch (error) {
    VkException(:final message) when message.startsWith('web_token') =>
      'VK login expired, log in again',
    VkException(:final message) => message,
    SocketException() || HandshakeException() => 'no connection to VK',
    FileSystemException() => 'not logged in to VK',
    TimeoutException() => 'VK did not answer in time',
    _ => error.toString(),
  };
  return text.replaceAll(RegExp(r'https?://\S+'), '<url>');
}

/// The library key of a VK song: "ownerId_audioId".
String vkSourceKey(Map<String, dynamic> item) =>
    '${item['owner_id']}_${item['id']}';

/// Converts one `audio.get` item into a library song.
///
/// Covers come from the item's own `thumb`, else from its album's. A song
/// without a named album has no cover of its own: VK then sends one of its
/// generic gradient placeholders as `thumb` (all 18 such songs of the test
/// library, 3 of them with an album whose title is empty), and the song's
/// stand-in tile says more than that.
NewTrack vkItemToTrack(Map<String, dynamic> item) {
  final album = item['album'];
  final albumTitle = album is Map<String, dynamic>
      ? (album['title'] as String?)?.trim() ?? ''
      : '';
  final thumb = albumTitle.isNotEmpty
      ? _mapOrNull(item['thumb']) ?? _mapOrNull(album['thumb'])
      : null;
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
    coverMidUrl: thumb?['photo_300'] as String?,
    coverFullUrl: thumb?['photo_1200'] as String?,
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
