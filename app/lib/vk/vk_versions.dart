/// Finds the uploads of a song on VK and measures their files (Stage K).
///
/// Read-only: one `audio.search`, a link for each upload (search results
/// carry one) and two small range reads of each file. Nothing is added to or
/// changed on any account, and no link is kept or logged.
library;

import 'dart:async';
import 'dart:io';

import '../library/song_version.dart';
import '../playback/mp3_length.dart';
import 'vk_client.dart';

/// How many results the search asks for: the uploads of one song are near
/// the top, and each one costs a range read.
const versionSearchCount = 60;

/// How many files are measured at once. Each measure is two small range
/// reads from VK's file servers (not the API, so not counted toward the
/// search captcha) and takes about 1.5 s, so a list waits about 1.5 s per
/// wave: 24 lets the usual long list (16-25 uploads) finish in one or two.
const _measuredAtOnce = 24;

/// [value] as an int, from an int or a numeric string.
int? _intOf(Object? value) =>
    value is int ? value : (value is String ? int.tryParse(value) : null);

/// The upload described by one item of `audio.search` (or `audio.getById`),
/// with its file measured as [file].
SongVersion versionFromItem(
  Map<String, dynamic> item, {
  FileFacts? file,
  bool isCurrentFile = false,
}) {
  final album = item['album'];
  final official = item['is_official'];
  final thumb = switch ((item['thumb'], album)) {
    (final Map<String, dynamic> own, _) => own,
    (_, {'thumb': final Map<String, dynamic> albumThumb}) => albumThumb,
    _ => null,
  };
  return SongVersion(
    key: '${item['owner_id']}_${item['id']}',
    accessKey: (item['access_key'] as String?)?.isEmpty ?? true
        ? null
        : item['access_key'] as String,
    artist: item['artist'] as String? ?? '',
    title: item['title'] as String? ?? '',
    // VK names albums without a title "unnamed": that says nothing.
    album: switch (album) {
      {'title': final String title} when title != 'unnamed' => title,
      _ => null,
    },
    albumKey: switch (album) {
      {'owner_id': final int owner, 'id': final int id} => '${owner}_$id',
      _ => null,
    },
    albumAccessKey: switch (album) {
      {'access_key': final String key} when key.isNotEmpty => key,
      _ => null,
    },
    coverUrl: thumb?['photo_135'] as String?,
    coverLargeUrl: thumb?['photo_600'] as String?,
    listedSec: _intOf(item['duration']) ?? 0,
    file: file,
    official: official == true || official == 1,
    vkTrackId: _intOf(item['track_id']),
    isCurrentFile: isCurrentFile,
  );
}

/// What a library row tells the search.
class VersionQuery {
  const VersionQuery({
    required this.artist,
    required this.title,
    required this.vkTrackId,
    required this.ownKeys,
  });

  final String artist;
  final String title;

  /// VK's `track_id` of the row; null when VK gives none.
  final int? vkTrackId;

  /// The row's own keys in every account: these are VK's current file,
  /// listed apart, not as other uploads.
  final Set<String> ownKeys;
}

/// What a search found so far: every upload, in the order found, and the
/// keys of those whose file is still being measured.
typedef VersionProgress = void Function(
  List<SongVersion> versions,
  Set<String> measuring,
);

/// How one search went, for perf.log: times and counts only.
class VersionSearchStats {
  /// Time until VK's search answered (or the search gave up).
  int searchMs = 0;

  /// Search requests sent (a stalled one is sent again, see
  /// [hedgedVkRequest]).
  int searchTries = 0;

  /// Time spent measuring the uploads' files.
  int measureMs = 0;

  /// Uploads found, and how many of them gave a file length.
  int found = 0;
  int measured = 0;

  @override
  String toString() =>
      'search $searchMs ms in $searchTries requests, $found uploads, '
      '$measured measured in $measureMs ms';
}

/// Searches VK through [client] for uploads of the song [query] names and
/// measures each file. Uploads VK gives no link for are listed without a
/// file. Throws as VK does when the search itself fails. [progress] hears
/// the uploads as soon as the search answers, then after each measured file;
/// [stats] (when given) is filled in as it goes. A stalled search request
/// is sent again after a few seconds ([hedgedVkRequest]).
Future<List<SongVersion>> findVkVersions(
  VkClient client,
  VersionQuery query, {
  HttpClient? http,
  VersionProgress? progress,
  VersionSearchStats? stats,
}) async {
  final searchClock = Stopwatch()..start();
  final items = await hedgedVkRequest(
    onDone: (tries) {
      stats
        ?..searchMs = searchClock.elapsedMilliseconds
        ..searchTries = tries;
    },
    () async {
      final reply = await client.call('audio.search', {
        'q': '${query.artist} ${query.title}',
        'count': '$versionSearchCount',
      });
      final items = reply is Map<String, dynamic> && reply['items'] is List
          ? (reply['items'] as List).whereType<Map<String, dynamic>>().toList()
          : const <Map<String, dynamic>>[];
      // A search for a library song finds at least that song. No songs at
      // all is VK not answering (seen 2026-11-06 while the first file check
      // read thousands of files), not "no other uploads": asked again, and
      // if it stays empty the choice lasts this run only.
      if (items.isEmpty) {
        throw VkException(
          'audio.search answered with no songs',
          transient: true,
        );
      }
      return items;
    },
  );
  final seen = <String>{};
  final uploads = <Map<String, dynamic>>[];
  for (final item in items) {
    final key = '${item['owner_id']}_${item['id']}';
    if (query.ownKeys.contains(key) || !seen.add(key)) continue;
    final sameSong = isUploadOfSong(
      rowArtist: query.artist,
      rowTitle: query.title,
      rowTrackId: query.vkTrackId,
      artist: item['artist'] as String? ?? '',
      title: item['title'] as String? ?? '',
      trackId: _intOf(item['track_id']),
    );
    if (sameSong) uploads.add(item);
  }
  final own = http == null;
  final reader =
      http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));
  try {
    final versions = [for (final item in uploads) versionFromItem(item)];
    final measuring = {for (final version in versions) version.key};
    progress?.call(List.of(versions), Set.of(measuring));
    var next = 0;
    Future<void> worker() async {
      while (next < uploads.length) {
        final index = next++;
        final item = uploads[index];
        versions[index] = versionFromItem(
          item,
          file: await _measureItem(client, reader, item),
        );
        measuring.remove(versions[index].key);
        progress?.call(List.of(versions), Set.of(measuring));
      }
    }

    final measureClock = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < _measuredAtOnce; i++) worker()]);
    stats
      ?..measureMs = measureClock.elapsedMilliseconds
      ..found = versions.length
      ..measured = versions.where((version) => version.file != null).length;
    return versions;
  } finally {
    if (own) reader.close(force: true);
  }
}

/// Measures the file of one search item: from its own link, or from a fresh
/// one when the search gave none or gave an HLS playlist. Null when VK gives
/// no audio or the line fails: the upload is still listed.
Future<FileFacts?> _measureItem(
  VkClient client,
  HttpClient http,
  Map<String, dynamic> item,
) async {
  try {
    final url = item['url'] as String? ?? '';
    var link = url.isEmpty ? null : Uri.tryParse(url);
    if (link == null || link.path.toLowerCase().endsWith('.m3u8')) {
      link = (await client.resolveStream(
        '${item['owner_id']}_${item['id']}',
        item['access_key'] as String?,
      )).link;
    }
    if (link == null) return null;
    return await measureRemote(http, link);
  } on Object {
    return null;
  }
}

/// Measures the file VK gives now for the song [sourceKey] of the account
/// behind [client]; null when VK gives no audio.
Future<FileFacts?> measureVkFile(
  VkClient client,
  String sourceKey,
  String? accessKey, {
  HttpClient? http,
}) async {
  final link = (await client.resolveStream(sourceKey, accessKey)).link;
  if (link == null) return null;
  final own = http == null;
  final reader =
      http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));
  try {
    return await measureRemote(reader, link);
  } finally {
    if (own) reader.close(force: true);
  }
}
