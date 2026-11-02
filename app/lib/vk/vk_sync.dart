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

/// What VK puts as the title of a song's album when it keeps the real title
/// to the album itself.
const _unnamedAlbum = 'unnamed';

/// The albums of [items] that VK calls "unnamed" and [titles] has no title
/// for, each once, by [vkAlbumKey].
Map<String, Map<String, dynamic>> unnamedAlbums(
  List<Map<String, dynamic>> items,
  Map<String, String> titles,
) => {
  for (final item in items)
    if (item['album'] case final Map<String, dynamic> album
        when album['title'] == _unnamedAlbum &&
            !titles.containsKey(vkAlbumKey(album)))
      vkAlbumKey(album): album,
};

/// Asks VK for the real title of each of [albums] and hands every title found
/// to [onTitle] at once, so a sync that ends early keeps them.
///
/// `audio.getById` says "unnamed" again even for an album's release copy; only
/// `audio.getPlaylistById` knows the title, and it takes one call per album.
/// [gap] keeps the pace: at 150 ms VK answered 293 of 300 calls with no limit.
///
/// Titles are extras, so a failure never fails the sync. VK refuses a few
/// albums (errors 15 and 100): that album stays blank and the next sync asks
/// again. A dead line or an overloaded VK stops the
/// lookups: the songs matter more than waiting out every album's retries.
Future<void> lookUpAlbumTitles(
  VkApiCall call,
  Map<String, Map<String, dynamic>> albums, {
  required void Function(String albumKey, String title) onTitle,
  Duration gap = const Duration(milliseconds: 150),
  void Function(int asked, int total)? onAsked,
}) async {
  var asked = 0;
  for (final MapEntry(:key, value: album) in albums.entries) {
    if (asked > 0) await Future<void>.delayed(gap);
    try {
      final reply = await call('audio.getPlaylistById', {
        'owner_id': '${album['owner_id']}',
        'playlist_id': '${album['id']}',
        if (album['access_key'] case final String accessKey)
          'access_key': accessKey,
      }) as Map<String, dynamic>;
      final title = (reply['title'] as String?)?.trim() ?? '';
      if (title.isNotEmpty) onTitle(key, title);
    } catch (error) {
      if (isTransientVkError(error)) return;
    }
    onAsked?.call(++asked, albums.length);
  }
}

/// Where a sync is, for the progress line.
enum SyncStage { connecting, reading, checking, albums, saving }

/// Progress of one sync.
class SyncProgress {
  const SyncProgress(this.stage, {this.done = 0, this.total = 0});

  final SyncStage stage;

  /// Pages read (reading), songs looked up (checking) or albums asked about
  /// (albums) so far.
  final int done;
  final int total;

  /// Rough share of the whole sync that is finished, 0 to 1. Reading the
  /// pages is most of the time; the gone check and saving are short.
  double get fraction {
    final part = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return switch (stage) {
      SyncStage.connecting => 0.02,
      SyncStage.reading => 0.05 + 0.75 * part,
      SyncStage.checking => 0.8 + 0.05 * part,
      SyncStage.albums => 0.85 + 0.1 * part,
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
    this.albumsSkipped = 0,
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

  /// "Unnamed" albums a first sync did not ask about; see [syncVkSource].
  final int albumsSkipped;

  /// Whether the library the UI shows is out of date after this sync.
  bool get changedLibrary => added + updated + back + newlyGone > 0;
}

/// Syncs the VK library of [userId] into [store]: adds new songs, updates
/// changed ones and marks songs VK no longer has as gone (see
/// [findGoneKeys]). Never deletes songs. Records the outcome on the source;
/// on failure records the reason and rethrows, leaving gone marks untouched.
///
/// Asks VK for the album titles it does not give ([lookUpAlbumTitles]). A
/// first sync leaves that out and says so in [VkSyncResult.albumsSkipped]: a
/// big library can have hundreds of such albums, and a new user's list must
/// not stay empty meanwhile. The caller then runs one more sync.
Future<VkSyncResult> syncVkSource({
  required VkApiCall call,
  required int userId,
  required LibraryStore store,
  void Function(SyncProgress progress)? onProgress,
  int pageSize = 200,
  Duration albumGap = const Duration(milliseconds: 150),
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

    final albumTitles = store.vkAlbumTitles();
    final unnamed = unnamedAlbums(library.items, albumTitles);
    if (known.isNotEmpty) {
      await lookUpAlbumTitles(
        call,
        unnamed,
        gap: albumGap,
        onTitle: (key, title) {
          store.saveVkAlbumTitle(key, title);
          albumTitles[key] = title;
        },
        onAsked: (asked, total) => onProgress?.call(
          SyncProgress(SyncStage.albums, done: asked, total: total),
        ),
      );
    }

    onProgress?.call(const SyncProgress(SyncStage.saving));
    final fresh = [
      for (final item in library.items)
        vkItemToTrack(item, albumTitles: albumTitles),
    ];
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
      albumsSkipped: known.isEmpty ? unnamed.length : 0,
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

/// What the status bar says when VK no longer accepts the saved session.
const vkLoginExpired = 'VK login expired, log in again';

/// A short reason for a failed sync, fit for the status bar. Never contains
/// links or tokens.
String describeSyncError(Object error) {
  final text = switch (error) {
    VkException(:final message) when message.startsWith('web_token') =>
      vkLoginExpired,
    VkException(:final message) => message,
    SocketException() || HandshakeException() => 'no connection to VK',
    TimeoutException() => 'VK did not answer in time',
    _ => error.toString(),
  };
  return text.replaceAll(RegExp(r'https?://\S+'), '<url>');
}

/// The library key of a VK song: "ownerId_audioId".
String vkSourceKey(Map<String, dynamic> item) =>
    '${item['owner_id']}_${item['id']}';

/// The key of an album in a song's reply: "ownerId_albumId".
String vkAlbumKey(Map<String, dynamic> album) =>
    '${album['owner_id']}_${album['id']}';

/// Converts one `audio.get` item into a library song.
///
/// The album's name is VK's title for it. "unnamed" stands for a real album
/// whose title is in [albumTitles] (by [vkAlbumKey]) once a sync found it, and
/// shows nothing until then.
///
/// Covers come from the item's own `thumb`, else from its album's. A song
/// without a named album has no cover of its own: VK then sends one of its
/// generic gradient placeholders as `thumb` (all 18 such songs of the test
/// library, 3 of them with an album whose title is empty), and the song's
/// stand-in tile says more than that.
NewTrack vkItemToTrack(
  Map<String, dynamic> item, {
  Map<String, String> albumTitles = const {},
}) {
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
    album: switch (albumTitle) {
      '' => null,
      _unnamedAlbum => albumTitles[vkAlbumKey(album as Map<String, dynamic>)],
      _ => albumTitle,
    },
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
