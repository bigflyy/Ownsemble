// Asks VK for one song's own file and its official release, reads both whole
// into memory (never saved, never played) and prints only their sizes and the
// length the MP3 frames add up to, next to the length VK lists for the song.
//
// Prints no link, token or key: only the allowlisted fields named below.
//
// Run from app/:
//   dart run tool/probe_own_file.dart --data-dir DIR --vk-session FILE
//     --track-id N

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Bitrates in kbit/s of MPEG-1 Layer III, by the header's 4-bit index.
const _bitratesV1 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  0,
];

/// Bitrates in kbit/s of MPEG-2 and 2.5 Layer III.
const _bitratesV2 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  0,
];

/// Sums the samples of every MP3 frame and returns the length in seconds,
/// or null when no frame is found.
double? mp3Seconds(Uint8List bytes) {
  var offset = 0;
  // Skips an ID3v2 tag: "ID3", version, flags, then a 28-bit size.
  if (bytes.length > 10 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    final size =
        (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    offset = 10 + size;
  }
  var seconds = 0.0;
  var frames = 0;
  while (offset + 4 <= bytes.length) {
    final b1 = bytes[offset + 1];
    final b2 = bytes[offset + 2];
    final isSync = bytes[offset] == 0xFF && (b1 & 0xE0) == 0xE0;
    final version = (b1 >> 3) & 3; // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5.
    final layer = (b1 >> 1) & 3; // 1 = Layer III.
    final bitrateIndex = b2 >> 4;
    final rateIndex = (b2 >> 2) & 3;
    if (!isSync ||
        version == 1 ||
        layer != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        rateIndex == 3) {
      offset++;
      continue;
    }
    final mpeg1 = version == 3;
    final bitrate = (mpeg1 ? _bitratesV1 : _bitratesV2)[bitrateIndex] * 1000;
    final baseRate = const [44100, 48000, 32000][rateIndex];
    final sampleRate = mpeg1
        ? baseRate
        : (version == 2 ? baseRate ~/ 2 : baseRate ~/ 4);
    final padding = (b2 >> 1) & 1;
    final samples = mpeg1 ? 1152 : 576;
    final frameLength = (samples ~/ 8) * bitrate ~/ sampleRate + padding;
    if (frameLength < 4) {
      offset++;
      continue;
    }
    seconds += samples / sampleRate;
    frames++;
    offset += frameLength;
  }
  return frames == 0 ? null : seconds;
}

/// The text frames of an ID3v2.3/2.4 tag that name the recording
/// (title, artist, album, year, comment-free), as "ID=value" pairs.
String id3Text(Uint8List bytes) {
  if (bytes.length < 10 ||
      bytes[0] != 0x49 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x33) {
    return 'none';
  }
  final major = bytes[3];
  final end =
      10 + ((bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9]);
  const wanted = {
    'TIT2',
    'TPE1',
    'TALB',
    'TYER',
    'TDRC',
    'TLEN',
    'TIT3',
    'TCON',
  };
  final found = <String>[];
  var offset = 10;
  while (offset + 10 <= end && offset + 10 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (id.codeUnits.first == 0) break;
    final size = major == 4
        ? (bytes[offset + 4] << 21) |
              (bytes[offset + 5] << 14) |
              (bytes[offset + 6] << 7) |
              bytes[offset + 7]
        : (bytes[offset + 4] << 24) |
              (bytes[offset + 5] << 16) |
              (bytes[offset + 6] << 8) |
              bytes[offset + 7];
    final body = bytes.sublist(
      offset + 10,
      (offset + 10 + size).clamp(0, bytes.length),
    );
    if (wanted.contains(id) && body.isNotEmpty) {
      final encoding = body[0];
      final raw = body.sublist(1);
      String text;
      if (encoding == 1 || encoding == 2) {
        final units = <int>[];
        var start = 0;
        var bigEndian = encoding == 2;
        if (raw.length >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) {
          start = 2;
          bigEndian = false;
        }
        if (raw.length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
          start = 2;
          bigEndian = true;
        }
        for (var i = start; i + 1 < raw.length; i += 2) {
          units.add(
            bigEndian ? (raw[i] << 8) | raw[i + 1] : raw[i] | (raw[i + 1] << 8),
          );
        }
        text = String.fromCharCodes(units);
      } else if (encoding == 3) {
        text = utf8.decode(raw, allowMalformed: true);
      } else {
        text = latin1.decode(raw);
      }
      found.add('$id=${text.replaceAll(String.fromCharCode(0), '').trim()}');
    }
    offset += 10 + size;
  }
  return found.isEmpty ? 'no text frames' : found.join('; ');
}

/// Reads the whole file at [link] into memory.
Future<Uint8List> fetchAll(HttpClient http, Uri link) async {
  final request = await http.getUrl(link);
  final response = await request.close();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

String describe(String name, Uint8List? bytes) {
  if (bytes == null) return '$name: no link';
  final seconds = mp3Seconds(bytes);
  final length = seconds == null
      ? 'no MP3 frames'
      : '${seconds.toStringAsFixed(1)} s (${seconds ~/ 60}:${(seconds % 60).floor().toString().padLeft(2, '0')})';
  return '$name: ${bytes.length} bytes, $length, tags ${id3Text(bytes)}';
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  final trackId = int.tryParse(valueOf('--track-id') ?? '');
  if (dataDir == null || sessionPath == null || trackId == null) {
    stderr.writeln('--data-dir, --vk-session and --track-id are required');
    exitCode = 2;
    return;
  }
  final db = sqlite3.open(
    p.join(dataDir, 'library.db'),
    mode: OpenMode.readOnly,
  );
  final row = db.select(
    'SELECT artist, title, duration_sec, source_key, access_key FROM tracks '
    'WHERE id = ?',
    [trackId],
  ).first;
  db.close();
  print(
    'song: ${row['artist']} - ${row['title']}, '
    'listed ${row['duration_sec']} s in the library',
  );

  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final sourceKey = row['source_key'] as String;
  final accessKey = row['access_key'] as String?;
  final id = accessKey == null ? sourceKey : '${sourceKey}_$accessKey';
  final reply = await vk.call('audio.getById', {'audios': id}) as List;
  if (reply.isEmpty) {
    print('audio.getById: empty reply');
    return;
  }
  final audio = reply.first as Map<String, dynamic>;
  // Allowlisted fields only; the reply also holds the private link.
  print(
    'VK: duration ${audio['duration']} s, '
    'has url ${(audio['url'] as String? ?? '').isNotEmpty}, '
    'content_restricted ${audio['content_restricted']}, '
    'has release_audio_id ${(audio['release_audio_id'] as String? ?? '').isNotEmpty}, '
    'release is the song itself ${audio['release_audio_id'] == sourceKey}',
  );

  final http = HttpClient();
  final own = (await vk.resolveStream(sourceKey, accessKey)).link;
  print(describe('own file', own == null ? null : await fetchAll(http, own)));
  final release = await vk.releaseLinkForCheck(sourceKey, accessKey);
  print(
    describe(
      'release file',
      release == null ? null : await fetchAll(http, release),
    ),
  );
  http.close(force: true);
}
