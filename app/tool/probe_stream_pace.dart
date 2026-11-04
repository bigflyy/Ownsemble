// Measures how fast VK's audio server sends a song, the way the proxy fetches
// it for the cache: one whole-file request ("bytes=0-") read to the end.
//
// Stage I question: a streamed song is saved to the cache only when its
// whole file arrives before the user seeks or starts another song. So the
// time to the whole file, next to the song's length, says how often a save
// is lost. When a song comes slowly, the probe also asks whether the
// slowness belongs to the connection (a second request to the same link),
// to the position (a request from the middle) or to the link (a new link).
//
// The library is opened read-only and nothing on VK is changed: only
// audio.getById and GETs of the audio. Never prints a link, a token or a
// host name: audio servers are shown as letters (A, B, ...) in the order
// they first appear.
//
// Run from app/:
//   dart run tool/probe_stream_pace.dart --data-dir DIR --vk-session FILE
//     [--songs N] [--seed N] [--cap-seconds N]
//
// --songs N        how many random songs (default 20)
// --seed N         random seed, so a run can be repeated (default 1)
// --cap-seconds N  stop reading one song after N seconds (default 200)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// A song is called slow when its first seconds come below this pace.
const slowBytesPerSecond = 500 * 1024;

/// How long each side request of a slow song is read.
const sideReadTime = Duration(seconds: 6);

/// Letters for audio server hosts, so no host name is printed.
final _hostLetters = <String, String>{};

/// The letter for [link]'s host; a new host gets the next letter.
String hostLetter(Uri link) => _hostLetters.putIfAbsent(
  link.host,
  () => String.fromCharCode(65 + _hostLetters.length),
);

/// What one read of a link gave.
class ReadResult {
  ReadResult(this.status, this.total, this.bytes, this.firstByteMs, this.ms);

  /// HTTP status of the reply.
  final int status;

  /// The whole file's size from Content-Range or Content-Length; -1 unknown.
  final int total;

  /// Bytes read before the read ended.
  final int bytes;

  /// Milliseconds from the request to the first byte; -1 when none came.
  final int firstByteMs;

  /// Milliseconds the read took in all.
  final int ms;

  /// True when every byte of the file arrived.
  bool get whole => total > 0 && bytes == total;

  /// Pace after the first byte, in KB/s.
  int get kbPerSecond {
    final reading = ms - max(firstByteMs, 0);
    return reading <= 0 ? 0 : (bytes / 1024 * 1000 / reading).round();
  }
}

/// Reads [link] with [range] until the reply ends or [limit] passes.
/// [onProgress] is told the bytes read so far and the elapsed time.
Future<ReadResult> readLink(
  HttpClient http,
  Uri link,
  String range,
  Duration limit, {
  void Function(int bytes, int ms)? onProgress,
}) async {
  final clock = Stopwatch()..start();
  final request = await http.getUrl(link);
  request.headers.set(HttpHeaders.rangeHeader, range);
  final response = await request.close();
  final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
  final total = contentRange == null
      ? response.contentLength
      : int.tryParse(contentRange.split('/').last) ?? -1;
  var bytes = 0;
  var firstByteMs = -1;
  final done = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      if (firstByteMs < 0) firstByteMs = clock.elapsedMilliseconds;
      bytes += chunk.length;
      onProgress?.call(bytes, clock.elapsedMilliseconds);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  final timer = Timer(limit - clock.elapsed, () {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  timer.cancel();
  await subscription.cancel();
  // For a ranged side request the "whole" means the rest from its start.
  final rangeStart =
      int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(range)?.group(1) ?? '') ??
      0;
  return ReadResult(
    response.statusCode,
    total < 0 ? -1 : total - rangeStart,
    bytes,
    firstByteMs,
    clock.elapsedMilliseconds,
  );
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessionPath = valueOf('--vk-session');
  if (dataDir == null || sessionPath == null) {
    stderr.writeln('--data-dir and --vk-session are required');
    exit(64);
  }
  final count = int.parse(valueOf('--songs') ?? '20');
  final seed = int.parse(valueOf('--seed') ?? '1');
  final cap = Duration(seconds: int.parse(valueOf('--cap-seconds') ?? '200'));

  final db = sqlite3.open(
    p.join(dataDir, 'library.db'),
    mode: OpenMode.readOnly,
  );
  final all = db.select(
    'SELECT artist, title, source_key, access_key, duration_sec FROM tracks '
    'WHERE gone_at_ms IS NULL ORDER BY id',
  );
  db.close();
  final songs = all.toList()..shuffle(Random(seed));
  final picked = songs.take(count).toList();
  print('${all.length} songs in the library, $count picked (seed $seed)');

  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  await vk.ensureToken();

  // One line per song; the summary at the end.
  final ratios = <double>[];
  var slowCount = 0;
  var noLink = 0;
  for (var index = 0; index < picked.length; index++) {
    final song = picked[index];
    final name = '${song['artist']} - ${song['title']}';
    final seconds = song['duration_sec'] as int;
    final stream = await vk.resolveStream(
      song['source_key'] as String,
      song['access_key'] as String?,
    );
    final link = stream.link;
    if (link == null) {
      noLink++;
      print('${index + 1}. no link: $name');
      continue;
    }
    final host = hostLetter(link);
    // The side requests start once the first seconds show a slow pace.
    final sides = <String, Future<ReadResult>>{};
    var startPace = -1;
    // The host letter of the new link, once a slow song asked for one.
    String? freshHost;
    final main = readLink(
      http,
      link,
      'bytes=0-',
      cap,
      onProgress: (bytes, ms) {
        if (startPace >= 0 || ms < 6000) return;
        startPace = (bytes * 1000 / ms).round();
        if (startPace >= slowBytesPerSecond) return;
        sides['same link, 2nd connection'] = readLink(
          http,
          link,
          'bytes=0-',
          sideReadTime,
        );
        sides['same link, from the middle'] = readLink(
          http,
          link,
          'bytes=${bytes * 4}-',
          sideReadTime,
        );
        sides['new link'] = vk
            .resolveStream(
              song['source_key'] as String,
              song['access_key'] as String?,
            )
            .then((fresh) {
              final freshLink = fresh.link;
              if (freshLink == null) {
                return ReadResult(0, -1, 0, -1, 0);
              }
              freshHost = hostLetter(freshLink);
              return readLink(http, freshLink, 'bytes=0-', sideReadTime);
            });
      },
    );
    final result = await main;
    final wholeSeconds = result.ms / 1000;
    final ratio = seconds <= 0 ? 0.0 : wholeSeconds / seconds;
    if (result.whole) ratios.add(ratio);
    final slow = startPace >= 0 && startPace < slowBytesPerSecond;
    if (slow) slowCount++;
    print(
      '${index + 1}. host $host, ${seconds}s song, '
      '${(result.total / 1e6).toStringAsFixed(1)} MB, status ${result.status}, '
      'first byte ${result.firstByteMs} ms, '
      '${result.whole ? 'whole in ${wholeSeconds.toStringAsFixed(1)} s '
                '(${(ratio * 100).round()}% of the song)' : 'NOT whole after ${wholeSeconds.toStringAsFixed(1)} s, ${(result.bytes / 1e6).toStringAsFixed(1)} MB'}, '
      '${result.kbPerSecond} KB/s'
      '${startPace >= 0 ? ', first 6 s ${(startPace / 1024).round()} KB/s' : ''}'
      '${slow ? ' SLOW' : ''}: $name',
    );
    for (final side in sides.entries) {
      final read = await side.value;
      if (read.status == 0) {
        print('     ${side.key}: no link');
        continue;
      }
      final label = side.key == 'new link'
          ? 'new link (host $freshHost)'
          : side.key;
      print(
        '     $label: status ${read.status}, '
        'first byte ${read.firstByteMs} ms, ${read.kbPerSecond} KB/s',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  ratios.sort();
  String at(double q) => ratios.isEmpty
      ? '-'
      : '${(ratios[(q * (ratios.length - 1)).round()] * 100).round()}%';
  print(
    'SUMMARY: ${picked.length} songs, $noLink without link, '
    '${ratios.length} whole, $slowCount slow (< ${slowBytesPerSecond ~/ 1024} '
    'KB/s in the first 6 s). Time to the whole file as a share of the song: '
    'p50 ${at(0.5)}, p75 ${at(0.75)}, p90 ${at(0.9)}, max ${at(1)}. '
    'Hosts seen: ${_hostLetters.length}',
  );
  http.close(force: true);
  vk.close();
}
