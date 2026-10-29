// VK experiment (step 1): sync the test account's library over plain HTTP and
// verify that 20 random tracks really decode, without any browser.
//
// Reads the test session saved by experiments/vk-web/discover.mjs from
// .local/v2-test/session.json. Prints only counts, formats and timings: no
// cookie values, tokens, audio URLs or track titles.
//
// Run from the repo root:
//   .local/toolchains/flutter/bin/dart run experiments/vk-probe/bin/probe.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// VK's own public web-client ID and API version, as observed on vk.ru.
const webClientId = '6287487';
const apiVersion = '5.289';
const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0';

final dataDir = Directory('.local/v2-test');
final http = HttpClient()..userAgent = userAgent;

/// One cookie from the saved browser session.
class SessionCookie {
  SessionCookie(this.name, this.value, this.domain);
  final String name;
  final String value;
  final String domain;

  /// Standard cookie domain matching: ".vk.ru" matches "login.vk.ru".
  bool appliesTo(String host) {
    final bare = domain.startsWith('.') ? domain.substring(1) : domain;
    return host == bare || host.endsWith('.$bare');
  }
}

List<SessionCookie> loadSession() {
  final file = File('${dataDir.path}/session.json');
  final entries = jsonDecode(file.readAsStringSync(encoding: utf8)) as List;
  return [
    for (final entry in entries.cast<Map<String, dynamic>>())
      SessionCookie(
        entry['name'] as String,
        entry['value'] as String,
        entry['domain'] as String,
      ),
  ];
}

String cookieHeaderFor(List<SessionCookie> cookies, String host) => cookies
    .where((c) => c.appliesTo(host))
    .map((c) => '${c.name}=${c.value}')
    .join('; ');

/// POSTs a form and decodes the JSON reply, with the session cookies attached.
Future<Map<String, dynamic>> postForm(
  Uri uri,
  Map<String, String> form,
  List<SessionCookie> cookies,
) async {
  final request = await http.postUrl(uri);
  request.headers
    ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
    ..set('Origin', 'https://vk.ru')
    ..set(HttpHeaders.refererHeader, 'https://vk.ru/')
    ..set(HttpHeaders.cookieHeader, cookieHeaderFor(cookies, uri.host));
  request.write(Uri(queryParameters: form).query);
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Exchanges the logged-in session for a short-lived web API token.
Future<({String token, int userId, int expiresAt})> fetchWebToken(
  List<SessionCookie> cookies,
) async {
  final reply = await postForm(
    Uri.parse('https://login.vk.ru/?act=web_token'),
    {'version': '1', 'app_id': webClientId},
    cookies,
  );
  if (reply['type'] != 'okay') {
    throw StateError('web_token refused: type=${reply['type']}');
  }
  final data = reply['data'] as Map<String, dynamic>;
  return (
    token: data['access_token'] as String,
    userId: data['user_id'] as int,
    expiresAt: data['expires'] as int,
  );
}

/// Calls one web API method; throws with VK's error code and message on failure.
Future<dynamic> callApi(
  String method,
  Map<String, String> params,
  String token,
  List<SessionCookie> cookies,
) async {
  final reply = await postForm(
    Uri.parse(
      'https://web.api.vk.ru/method/$method?v=$apiVersion&client_id=$webClientId',
    ),
    {...params, 'access_token': token},
    cookies,
  );
  if (reply.containsKey('error')) {
    final error = reply['error'] as Map<String, dynamic>;
    throw StateError(
      '$method error ${error['error_code']}: ${error['error_msg']}',
    );
  }
  return reply['response'];
}

/// Pages through audio.get until VK reports no more tracks.
Future<({List<Map<String, dynamic>> tracks, int declaredCount, int pages})>
syncLibrary(int ownerId, String token, List<SessionCookie> cookies) async {
  const pageSize = 200;
  final tracks = <Map<String, dynamic>>[];
  var declaredCount = -1;
  var pages = 0;
  while (true) {
    final page = await callApi(
      'audio.get',
      {
        'owner_id': '$ownerId',
        'count': '$pageSize',
        'offset': '${tracks.length}',
      },
      token,
      cookies,
    ) as Map<String, dynamic>;
    pages++;
    declaredCount = page['count'] as int;
    final items = (page['items'] as List).cast<Map<String, dynamic>>();
    tracks.addAll(items);
    if (items.isEmpty || tracks.length >= declaredCount) break;
  }
  return (tracks: tracks, declaredCount: declaredCount, pages: pages);
}

/// Reads the first bytes of a stream URL: network time and container format.
Future<({int firstBytesMs, String format})> probeStream(String url) async {
  final watch = Stopwatch()..start();
  final request = await http.getUrl(Uri.parse(url));
  final response = await request.close();
  final head = <int>[];
  await for (final chunk in response) {
    head.addAll(chunk);
    if (head.length >= 16) break;
  }
  final firstBytesMs = watch.elapsedMilliseconds;
  final text = ascii.decode(head.take(7).toList(), allowInvalid: true);
  final format = text.startsWith('#EXTM3U')
      ? 'hls'
      : (text.startsWith('ID3') ||
            (head.length > 1 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0))
      ? 'mp3'
      : 'unknown(http ${response.statusCode})';
  return (firstBytesMs: firstBytesMs, format: format);
}

/// Decodes the first seconds with ffmpeg (no audio output) and reports how long
/// it took until the first audio was actually decoded.
Future<({bool ok, int firstAudioMs, String detail})> decodeStart(
  String url,
) async {
  final watch = Stopwatch()..start();
  final process = await Process.start('ffmpeg', [
    '-hide_banner',
    '-nostdin',
    '-v',
    'error',
    '-t',
    '5',
    '-i',
    url,
    '-f',
    'null',
    '-',
    '-progress',
    'pipe:1',
  ]);
  var firstAudioMs = -1;
  final errors = StringBuffer();
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((line) {
        // ffmpeg reports out_time_us > 0 once it has decoded real audio samples.
        if (firstAudioMs < 0 && line.startsWith('out_time_us=')) {
          final micros =
              int.tryParse(line.substring('out_time_us='.length)) ?? 0;
          if (micros > 0) firstAudioMs = watch.elapsedMilliseconds;
        }
      });
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .forEach(errors.write);
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  await Future.wait([stdoutDone, stderrDone]);
  // Keep only the first error line, with any URL removed.
  final firstError = errors
      .toString()
      .split('\n')
      .first
      .replaceAll(RegExp(r'https?://\S+'), '<url>');
  return (
    ok: exitCode == 0 && firstAudioMs >= 0,
    firstAudioMs: firstAudioMs,
    detail: firstError,
  );
}

/// Extra checks: small-page sync (exercises paging), fresh URL for single
/// tracks via audio.getById, and catalog search.
Future<void> runExtraChecks(
  List<Map<String, dynamic>> tracks,
  int ownerId,
  String token,
  List<SessionCookie> cookies,
) async {
  // Paging: re-sync with a small page size and compare totals.
  final pagedTracks = <Map<String, dynamic>>[];
  var pages = 0;
  final pagingWatch = Stopwatch()..start();
  while (true) {
    final page = await callApi(
      'audio.get',
      {
        'owner_id': '$ownerId',
        'count': '50',
        'offset': '${pagedTracks.length}',
      },
      token,
      cookies,
    ) as Map<String, dynamic>;
    pages++;
    final items = (page['items'] as List).cast<Map<String, dynamic>>();
    pagedTracks.addAll(items);
    if (items.isEmpty || pagedTracks.length >= (page['count'] as int)) break;
  }
  final firstIds = tracks.map((t) => '${t['owner_id']}_${t['id']}').toList();
  final pagedIds = pagedTracks
      .map((t) => '${t['owner_id']}_${t['id']}')
      .toList();
  final sameOrder =
      firstIds.length == pagedIds.length &&
      Iterable.generate(firstIds.length)
          .every((i) => firstIds[i] == pagedIds[i]);
  print(
    'Paging (50/page): ${pagedTracks.length} tracks in $pages pages, '
    '${pagingWatch.elapsedMilliseconds} ms; same tracks and order as one-page sync: $sameOrder; '
    'duplicates: ${pagedIds.length - pagedIds.toSet().length}.',
  );

  // Single-track refresh: what Play would do for a song whose URL expired.
  final sample = (tracks.toList()..shuffle(Random())).take(5).toList();
  for (final track in sample) {
    final key = track['access_key'] as String?;
    final id =
        '${track['owner_id']}_${track['id']}${key == null ? '' : '_$key'}';
    final watch = Stopwatch()..start();
    try {
      final reply = await callApi(
        'audio.getById',
        {'audios': id},
        token,
        cookies,
      ) as List;
      final url = reply.isEmpty
          ? ''
          : (reply.first as Map<String, dynamic>)['url'] as String? ?? '';
      print(
        '  getById: ${watch.elapsedMilliseconds} ms, fresh url: ${url.isNotEmpty}',
      );
    } catch (error) {
      print('  getById: FAIL $error');
    }
  }

  // Catalog search for "search everywhere".
  for (final query in ['кино', 'kino', 'metallica']) {
    final watch = Stopwatch()..start();
    try {
      final reply = await callApi(
        'audio.search',
        {'q': query, 'count': '20'},
        token,
        cookies,
      ) as Map<String, dynamic>;
      final items = (reply['items'] as List).cast<Map<String, dynamic>>();
      final playable = items
          .where((t) => (t['url'] as String? ?? '').isNotEmpty)
          .length;
      print(
        '  search "$query": ${items.length} results ($playable playable) of ${reply['count']} in ${watch.elapsedMilliseconds} ms',
      );
    } catch (error) {
      print('  search "$query": FAIL $error');
    }
  }
}

Future<void> main(List<String> args) async {
  final cookies = loadSession();
  if (args.contains('--extra')) {
    final auth = await fetchWebToken(cookies);
    final library = await syncLibrary(auth.userId, auth.token, cookies);
    await runExtraChecks(library.tracks, auth.userId, auth.token, cookies);
    http.close(force: true);
    return;
  }

  final tokenWatch = Stopwatch()..start();
  final auth = await fetchWebToken(cookies);
  final validMinutes =
      (auth.expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ 60;
  print(
    'Token: ok in ${tokenWatch.elapsedMilliseconds} ms, valid ~$validMinutes min.',
  );

  final syncWatch = Stopwatch()..start();
  final library = await syncLibrary(auth.userId, auth.token, cookies);
  final withUrl = library.tracks
      .where((t) => (t['url'] as String? ?? '').isNotEmpty)
      .toList();
  print(
    'Sync: ${library.tracks.length}/${library.declaredCount} tracks in ${library.pages} page(s), '
    '${syncWatch.elapsedMilliseconds} ms; ${withUrl.length} have a stream URL.',
  );

  final sample = (withUrl..shuffle(Random())).take(20).toList();
  var passed = 0;
  final rows = <String>[];
  for (var i = 0; i < sample.length; i++) {
    final url = sample[i]['url'] as String;
    try {
      final stream = await probeStream(url);
      final decode = await decodeStart(url);
      if (decode.ok) passed++;
      rows.add(
        '  #${i + 1}: ${decode.ok ? 'OK  ' : 'FAIL'} format=${stream.format} '
        'network-first-bytes=${stream.firstBytesMs} ms, first-audio-decoded=${decode.firstAudioMs} ms'
        '${decode.ok ? '' : ' (${decode.detail})'}',
      );
    } catch (error) {
      rows.add('  #${i + 1}: FAIL ${error.runtimeType}');
    }
  }
  print('Playback check (ffmpeg decode, no sound):');
  rows.forEach(print);
  print('Result: $passed/${sample.length} tracks decoded real audio.');
  http.close(force: true);
}
