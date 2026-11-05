/// Reads the prints of VK's files for library rows (Stage L).
///
/// Read-only: `audio.getById` for a batch of songs, then a few small range
/// reads of each file (see [printOffsets]). Nothing on VK changes, and no
/// link is kept or logged.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../library/file_print.dart';
import '../playback/mp3_length.dart';
import 'vk_client.dart';

/// How many songs one `audio.getById` asks for.
const _songsPerCall = 50;

/// How many files are read at once.
const _readAtOnce = 8;

/// One song of one account: its "ownerId_audioId" and VK's access key.
typedef VkSongRef = ({String key, String? accessKey});

/// Reads the prints of [songs] through [client], the account that lists
/// them. A song VK gives no file for gets [FilePrint.noFile]; a song left out
/// of the result could not be read now (the line or VK failed) and is tried
/// again by the next sync.
Future<Map<String, FilePrint>> printVkFiles(
  VkClient client,
  List<VkSongRef> songs, {
  HttpClient? http,
}) async {
  final links = <String, Uri>{};
  final prints = <String, FilePrint>{};
  for (var start = 0; start < songs.length; start += _songsPerCall) {
    final batch = songs.skip(start).take(_songsPerCall).toList();
    final List<Object?> reply;
    try {
      final answer = await retryTransient(
        () => client.call('audio.getById', {
          'audios': [
            for (final song in batch)
              song.accessKey == null
                  ? song.key
                  : '${song.key}_${song.accessKey}',
          ].join(','),
        }),
      );
      reply = answer is List ? answer : const [];
    } on Object {
      continue;
    }
    final items = {
      for (final item in reply.whereType<Map<String, dynamic>>())
        '${item['owner_id']}_${item['id']}': item,
    };
    for (final song in batch) {
      final url = items[song.key]?['url'] as String? ?? '';
      final link = url.isEmpty ? null : Uri.tryParse(url);
      if (link == null) {
        prints[song.key] = const FilePrint.noFile();
      } else if (link.path.toLowerCase().endsWith('.m3u8')) {
        // VK now and then gives an HLS playlist; a new link brings the MP3.
        try {
          final again = await client.resolveStream(song.key, song.accessKey);
          final mp3 = again.link;
          if (mp3 == null) {
            prints[song.key] = const FilePrint.noFile();
          } else if (!mp3.path.toLowerCase().endsWith('.m3u8')) {
            links[song.key] = mp3;
          }
        } on Object {
          continue;
        }
      } else {
        links[song.key] = link;
      }
    }
  }

  final own = http == null;
  final reader =
      http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));
  try {
    final keys = links.keys.toList();
    var next = 0;
    Future<void> worker() async {
      while (next < keys.length) {
        final key = keys[next++];
        try {
          final filePrint = await printRemote(reader, links[key]!);
          if (filePrint != null) prints[key] = filePrint;
        } on Object {
          continue;
        }
      }
    }

    await Future.wait([for (var i = 0; i < _readAtOnce; i++) worker()]);
  } finally {
    if (own) reader.close(force: true);
  }
  return prints;
}

/// Reads the print of the file at [link]: its start (with the size and the
/// length) and its quarters. Null when the server gives no audio or no
/// size. Throws as the network does.
Future<FilePrint?> printRemote(
  HttpClient http,
  Uri link, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final (head, total) = await readRemoteRange(
    http,
    link,
    0,
    framesWindow,
    timeout,
  );
  if (head == null || total == null || total <= 0) return null;
  var seconds = readHead(head, total).facts?.seconds;
  if (seconds == null) {
    final measured = await measureRemote(http, link, timeout: timeout);
    seconds = measured?.seconds;
  }
  final samples = <List<int>>[];
  for (final offset in printOffsets(total)) {
    final count = printSampleBytes < total - offset
        ? printSampleBytes
        : total - offset;
    if (offset + count <= head.length) {
      samples.add(Uint8List.sublistView(head, offset, offset + count));
      continue;
    }
    final (bytes, size) = await readRemoteRange(
      http,
      link,
      offset,
      count,
      timeout,
    );
    if (bytes == null || size != total || bytes.length != count) return null;
    samples.add(bytes);
  }
  return FilePrint(bytes: total, sample: fnv1a64(samples), seconds: seconds);
}
