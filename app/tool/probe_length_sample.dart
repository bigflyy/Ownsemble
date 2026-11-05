// Samples songs of one VK source and compares the length VK lists with the
// length of the file VK sends, estimated from the file's size and its first
// MP3 frame (or the Xing/Info frame count). Reads 16 KB of each file, never
// saves or plays it, prints no link. Titles go to the console only.
//
// Run from app/:
//   dart run tool/probe_length_sample.dart --data-dir DIR --vk-session FILE
//     --source-id N [--sample N] [--off SECONDS]

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

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

/// Reads [count] bytes of [link] from [start]; returns them and the file size.
Future<(Uint8List, int?)> fetchRange(
  HttpClient http,
  Uri link,
  int start,
  int count,
) async {
  final request = await http.getUrl(link);
  request.headers.set(
    HttpHeaders.rangeHeader,
    'bytes=$start-${start + count - 1}',
  );
  final response = await request.close();
  final range = response.headers.value(HttpHeaders.contentRangeHeader);
  final total = range == null ? null : int.tryParse(range.split('/').last);
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return (builder.takeBytes(), total);
}

/// Estimated seconds of an MP3 of [total] bytes whose audio starts at
/// [audioStart], from the first frame in [head] (bytes from audioStart).
double? estimate(Uint8List head, int audioStart, int total) {
  for (var i = 0; i + 4 <= head.length; i++) {
    final b1 = head[i + 1];
    final b2 = head[i + 2];
    if (head[i] != 0xFF || (b1 & 0xE0) != 0xE0) continue;
    final version = (b1 >> 3) & 3;
    final layer = (b1 >> 1) & 3;
    final bitrateIndex = b2 >> 4;
    final rateIndex = (b2 >> 2) & 3;
    if (version == 1 ||
        layer != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        rateIndex == 3) {
      continue;
    }
    final mpeg1 = version == 3;
    final bitrate = (mpeg1 ? _bitratesV1 : _bitratesV2)[bitrateIndex] * 1000;
    final baseRate = const [44100, 48000, 32000][rateIndex];
    final sampleRate = mpeg1
        ? baseRate
        : (version == 2 ? baseRate ~/ 2 : baseRate ~/ 4);
    final samples = mpeg1 ? 1152 : 576;
    // A Xing or Info frame names the frame count of a VBR file.
    final channelMode = head[i + 3] >> 6;
    final sideInfo = mpeg1
        ? (channelMode == 3 ? 17 : 32)
        : (channelMode == 3 ? 9 : 17);
    final tagAt = i + 4 + sideInfo;
    if (tagAt + 12 <= head.length) {
      final tag = String.fromCharCodes(head.sublist(tagAt, tagAt + 4));
      if ((tag == 'Xing' || tag == 'Info') && (head[tagAt + 7] & 1) == 1) {
        final frames =
            (head[tagAt + 8] << 24) |
            (head[tagAt + 9] << 16) |
            (head[tagAt + 10] << 8) |
            head[tagAt + 11];
        return frames * samples / sampleRate;
      }
    }
    return (total - audioStart - i) * 8 / bitrate;
  }
  return null;
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir')!;
  final sessionPath = valueOf('--vk-session')!;
  final sourceId = int.parse(valueOf('--source-id')!);
  final sample = int.tryParse(valueOf('--sample') ?? '') ?? 100;
  final off = double.tryParse(valueOf('--off') ?? '') ?? 3;
  final db = sqlite3.open(
    p.join(dataDir, 'library.db'),
    mode: OpenMode.readOnly,
  );
  final rows = db.select(
    'SELECT id, artist, title, duration_sec, source_key, access_key FROM tracks '
    'WHERE source_id = ? AND gone_at_ms IS NULL',
    [sourceId],
  ).toList()..shuffle(Random(7));
  db.close();
  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final http = HttpClient();
  var checked = 0, noLink = 0, failed = 0;
  final differences = <double>[];
  final mismatches = <String>[];
  for (final row in rows.take(sample)) {
    try {
      final link = (await vk.resolveStream(
        row['source_key'] as String,
        row['access_key'] as String?,
      )).link;
      if (link == null) {
        noLink++;
        continue;
      }
      var (head, total) = await fetchRange(http, link, 0, 16384);
      if (total == null) {
        failed++;
        continue;
      }
      var audioStart = 0;
      if (head.length > 10 &&
          head[0] == 0x49 &&
          head[1] == 0x44 &&
          head[2] == 0x33) {
        audioStart =
            10 + ((head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9]);
        (head, _) = await fetchRange(http, link, audioStart, 16384);
      }
      final seconds = estimate(head, audioStart, total);
      if (seconds == null) {
        failed++;
        continue;
      }
      checked++;
      final listed = row['duration_sec'] as int;
      final difference = seconds - listed;
      differences.add(difference);
      if (difference.abs() > off) {
        mismatches.add(
          '  #${row['id']} ${row['artist']} - ${row['title']}: listed $listed s, file ${seconds.toStringAsFixed(1)} s',
        );
      }
    } on Object catch (error) {
      failed++;
      print('  error on #${row['id']}: ${error.runtimeType}');
    }
  }
  http.close(force: true);
  differences.sort();
  print('checked $checked, no link $noLink, failed $failed');
  if (differences.isNotEmpty) {
    print(
      'file minus listed, s: min ${differences.first.toStringAsFixed(1)}, '
      'median ${differences[differences.length ~/ 2].toStringAsFixed(1)}, '
      'max ${differences.last.toStringAsFixed(1)}',
    );
  }
  print('${mismatches.length} off by more than $off s:');
  mismatches.forEach(print);
}
