/// Finding songs on VK and changing an account's VK library (plan 06, C1).
///
/// Search reads only. Add, delete and restore WRITE to the account the
/// [VkApiCall] belongs to; agent checks use the test account only. None of
/// these calls is retried or hedged here on its own: sending an add twice
/// makes two copies on VK (A2), so the caller decides what may be repeated.
///
/// Answer shapes as VK gave them on 2026-11-08 (tool/probe_add_song.dart,
/// tool/probe_add_edges.dart):
/// - `audio.search`: `{count, items: [audio]}`, each audio shaped like an
///   `audio.get` item; blocked songs are left out.
/// - `audio.add`: a batch, `{items_count, errors_count, items: [{new_audio_id,
///   new_owner_id, audio_raw_id}], errors: [{audio_raw_id, error_code,
///   error_msg}]}`, not the bare id of VK's old docs. A refused song is an
///   entry in `errors`, not a VK error: error_code is TEXT, "15;Access
///   denied", and error_msg "no access to audio".
/// - `audio.delete`: `{audio_ids: ["ownerId_audioId"]}`, whole keys as text.
/// - `audio.restore`: the whole song, back under its old id and place.
library;

import '../library/library_store.dart';
import 'vk_client.dart';
import 'vk_sync.dart';

/// How many songs one search page asks for.
const vkSearchPageSize = 50;

/// One page of `audio.search`.
class VkSearchPage {
  const VkSearchPage({
    required this.songs,
    required this.total,
    required this.nextOffset,
  });

  /// The songs found on this page, in VK's order, each key once.
  final List<NewTrack> songs;

  /// How many songs VK says the search found in all.
  final int total;

  /// The offset of the next page: the requested offset plus the requested
  /// count, never plus the songs received, since VK leaves blocked songs out
  /// of a page but still counts them (the same rule as `audio.get`).
  final int nextOffset;

  /// Whether a next page may hold more songs.
  bool get hasMore => nextOffset < total;
}

/// Searches VK for [query] and returns the page that starts at [offset].
///
/// An empty query asks nothing and finds nothing. VK's answer is read
/// defensively: a missing or odd `items` list is an empty page.
Future<VkSearchPage> searchVkSongs(
  VkApiCall call,
  String query, {
  int offset = 0,
  int count = vkSearchPageSize,
}) async {
  final words = query.trim();
  if (words.isEmpty) {
    return VkSearchPage(songs: const [], total: 0, nextOffset: offset);
  }
  final reply = await call('audio.search', {
    'q': words,
    'count': '$count',
    'offset': '$offset',
  });
  final map = reply is Map<String, dynamic> ? reply : const {};
  final items = map['items'] is List
      ? (map['items'] as List).whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];
  final readable = await _withReleaseNames(call, items);
  final seen = <String>{};
  final songs = [
    for (final item in readable)
      if (item['id'] is int &&
          item['owner_id'] is int &&
          seen.add(vkSourceKey(item)))
        vkItemToTrack(item),
  ];
  return VkSearchPage(
    songs: songs,
    total: map['count'] is int ? map['count'] as int : songs.length,
    nextOffset: offset + count,
  );
}

/// Whether [name] is one of the names VK keeps as question marks: old
/// uploads (many from zaycev.net) whose Cyrillic tags broke on upload and
/// are stored as "?4??4??1?" (real VK 2026-11-12). Three or more '?' that
/// make up at least a third of the name; "Why?" and "Who are you???" stay.
bool isQuestionMarkName(String name) {
  final letters = name.runes.where((rune) => rune != 0x20).length;
  final marks = name.runes.where((rune) => rune == 0x3F).length;
  return marks >= 3 && marks * 3 >= letters;
}

bool _hasQuestionMarkName(Map<String, dynamic> item) =>
    isQuestionMarkName(item['artist'] as String? ?? '') ||
    isQuestionMarkName(item['title'] as String? ?? '');

/// [items] with each question-mark song ([isQuestionMarkName]) swapped for
/// VK's own release of it, which has the real names: such uploads still name
/// that release in `release_audio_id` (7 of 7 on a real page, 2026-11-12).
/// All the releases come in one `audio.getById` (about 0.3 s), asked only
/// when the page has such a song. A song without a release, or whose
/// release VK does not give, moves to the end of the page; a failed call
/// moves them all there and changes nothing else, so the search still shows.
Future<List<Map<String, dynamic>>> _withReleaseNames(
  VkApiCall call,
  List<Map<String, dynamic>> items,
) async {
  final broken = [
    for (final item in items)
      if (_hasQuestionMarkName(item)) item,
  ];
  if (broken.isEmpty) return items;
  final releaseKeys = {
    for (final item in broken)
      if (item['release_audio_id'] case final String key when key.isNotEmpty)
        key,
  };
  final releases = <String, Map<String, dynamic>>{};
  if (releaseKeys.isNotEmpty) {
    try {
      final reply = await call('audio.getById', {
        'audios': releaseKeys.join(','),
      });
      if (reply is List) {
        for (final release in reply.whereType<Map<String, dynamic>>()) {
          if (release['id'] is int &&
              release['owner_id'] is int &&
              !_hasQuestionMarkName(release)) {
            releases[vkSourceKey(release)] = release;
          }
        }
      }
    } catch (_) {
      // Any failure here, VK's or the network's: the page VK already gave
      // still shows, and these songs keep VK's names, at the end.
    }
  }
  final kept = <Map<String, dynamic>>[];
  final unresolved = <Map<String, dynamic>>[];
  for (final item in items) {
    if (!_hasQuestionMarkName(item)) {
      kept.add(item);
      continue;
    }
    final release = releases[item['release_audio_id']];
    if (release != null) {
      kept.add(release);
    } else {
      unresolved.add(item);
    }
  }
  return [...kept, ...unresolved];
}

/// VK's error code for a song the account may not have: "Access denied: no
/// access to audio" (A2, a blocked song of the library).
const vkNoAccessCode = 15;

/// What one `audio.add` did: either the new copy's key, or VK's reason for
/// not adding it.
class VkAddResult {
  const VkAddResult.added(String this.newKey)
    : errorCode = null,
      errorText = null;

  const VkAddResult.refused(this.errorCode, this.errorText) : newKey = null;

  /// The library key of the new copy, "ownerId_audioId" (the owner is the
  /// account that added it). The next sync lists the copy under this key.
  final String? newKey;

  /// VK's code for a refused add, e.g. [vkNoAccessCode]; null if VK named none.
  final int? errorCode;

  /// VK's text for a refused add; it names no ids or keys.
  final String? errorText;

  bool get added => newKey != null;

  /// Whether VK refused because the song is not open to this account.
  bool get noAccess => errorCode == vkNoAccessCode;
}

/// Reads the batch `audio.add` answers with ([VkAddResult]).
///
/// Throws a [VkException] when the answer has neither a new song nor an
/// error: something VK never sent in A1 and A2, and the add may or may not
/// have happened, so the caller must not assume either.
VkAddResult readVkAddReply(Object? reply) {
  if (reply is Map<String, dynamic>) {
    final items = reply['items'];
    if (items is List && items.isNotEmpty) {
      final first = items.first;
      if (first is Map &&
          first['new_owner_id'] is int &&
          first['new_audio_id'] is int) {
        return VkAddResult.added(
          '${first['new_owner_id']}_${first['new_audio_id']}',
        );
      }
    }
    final errors = reply['errors'];
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      final error = errors.first as Map;
      // Real VK: error_code "15;Access denied", error_msg "no access to
      // audio". A plain number is read too.
      final code = error['error_code'];
      final codeMatch = RegExp(r'^\s*(\d+)\s*;?\s*(.*)$').firstMatch('$code');
      final codeWords = codeMatch?.group(2)?.trim() ?? '';
      final message = error['error_msg'] is String
          ? (error['error_msg'] as String).trim()
          : '';
      final text = [
        if (codeWords.isNotEmpty) codeWords,
        if (message.isNotEmpty) message,
      ].join(': ');
      return VkAddResult.refused(
        code is int ? code : int.tryParse(codeMatch?.group(1) ?? ''),
        text.isEmpty ? null : text,
      );
    }
  }
  throw VkException(
    'audio.add answered with neither a song nor an error '
    '(a ${reply.runtimeType})',
  );
}

/// Adds the song [sourceKey] ("ownerId_audioId" of a found song) to the VK
/// library of the account behind [call]. VK puts the copy first in that
/// library and makes a new copy on every call, even for a song the library
/// already has (A2): the caller must not offer Add for such a song.
///
/// [accessKey] is the found song's own key; VK added without it too (A2),
/// but it is sent whenever known, as vk.ru does.
Future<VkAddResult> addVkSong(
  VkApiCall call,
  String sourceKey, {
  String? accessKey,
}) async {
  final (owner, id) = splitVkKey(sourceKey);
  final reply = await call('audio.add', {
    'audio_id': '$id',
    'owner_id': '$owner',
    if (accessKey != null && accessKey.isNotEmpty) 'access_key': accessKey,
  });
  return readVkAddReply(reply);
}

/// Removes the song [sourceKey] from the VK library of the account behind
/// [call]; [sourceKey]'s owner must be that account. Returns whether VK says
/// it removed that song. [restoreVkSong] can bring it back for a while (at
/// least 8 s, A2).
Future<bool> deleteVkSong(VkApiCall call, String sourceKey) async {
  final (owner, id) = splitVkKey(sourceKey);
  final reply = await call('audio.delete', {
    'audio_id': '$id',
    'owner_id': '$owner',
  });
  return readVkDeleteReply(reply, sourceKey);
}

/// Whether the answer of `audio.delete` names the song [sourceKey] as
/// removed. Real VK lists whole keys ("ownerId_audioId", 2026-11-08); a bare
/// audio id and the bare 1 of VK's old docs are taken as yes too.
bool readVkDeleteReply(Object? reply, String sourceKey) {
  final bareId = sourceKey.substring(sourceKey.lastIndexOf('_') + 1);
  return switch (reply) {
    {'audio_ids': final List ids} => ids.any(
      (id) => '$id' == sourceKey || (id is int && '$id' == bareId),
    ),
    1 => true,
    _ => false,
  };
}

/// Puts the song [sourceKey], removed by [deleteVkSong] a moment ago, back
/// into the VK library of the account behind [call]: under the same key and
/// at its old place (A2), so its plays and favorite stay with it. Returns the
/// song as VK gives it back, read like a sync reads it.
Future<NewTrack> restoreVkSong(
  VkApiCall call,
  String sourceKey, {
  Map<String, String> albumTitles = const {},
}) async {
  final (owner, id) = splitVkKey(sourceKey);
  final reply = await call('audio.restore', {
    'audio_id': '$id',
    'owner_id': '$owner',
  });
  if (reply is! Map<String, dynamic> ||
      reply['id'] is! int ||
      reply['owner_id'] is! int) {
    throw VkException(
      'audio.restore answered without the song (a ${reply.runtimeType})',
    );
  }
  return vkItemToTrack(reply, albumTitles: albumTitles);
}

/// Splits a library key "ownerId_audioId" into its two numbers. Group
/// owners are negative ("-123_456"). Throws a [FormatException] for any
/// other text.
(int owner, int id) splitVkKey(String sourceKey) {
  final match = RegExp(r'^(-?\d+)_(\d+)$').firstMatch(sourceKey);
  if (match == null) {
    throw const FormatException('not a VK song key');
  }
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}
