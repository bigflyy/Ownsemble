// Read-only probe for plan 10, A4: what outside lyrics sources (LRCLIB,
// NetEase, QQ Music) give for the TEST account's songs, against what VK
// gives for the same songs.
//
//   dart run tool/probe_lyrics_outside.dart --vk-session FILE [--count 60]
//       [--sources lrclib,netease,qq] [--no-vk-lyrics] [--tries 3]
//       [--only 3,11,13]
//
// Steps: audio.get (the account's songs: artist, title, album, length);
// audio.getLyrics for the songs VK flags (timed or plain); then, for each
// song and source, a search by artist and title and, for the best match,
// its lyrics. A match is judged by the names (case, yo/e, bracket tags and
// "feat." ignored; artist and title also tried swapped) and the length
// (2 / 5 / 10 s).
//
// Printed: per song only its index, VK's kind and each source's verdict
// (length difference, timed or plain, ms); then the totals and the gaps
// (songs no source has timed lyrics for). No song name, lyric line, link,
// key or token is printed. Outside services get a generic User-Agent.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

/// One song of the account, as the sources are asked about it.
class Song {
  Song(this.index, this.artist, this.title, this.album, this.seconds);
  final int index;
  final String artist;
  final String title;
  final String album;
  final int seconds;
}

/// A source's answer for one song: the best candidate's facts.
class Verdict {
  Verdict({
    this.candidates = 0,
    this.namesMatch = false,
    this.lengthDiff,
    this.timed = false,
    this.plain = false,
    this.wordTimed = false,
    this.lines = 0,
    this.ms = 0,
    this.error,
  });
  int candidates;
  bool namesMatch;
  int? lengthDiff;
  bool timed;
  bool plain;
  bool wordTimed;
  int lines;
  int ms;
  String? error;

  /// A candidate the app would take on its own: names agree and the
  /// length is within 5 s.
  bool get good =>
      namesMatch && lengthDiff != null && lengthDiff! <= 5 && (timed || plain);

  @override
  String toString() {
    if (error != null) return 'error $error';
    if (candidates == 0) return 'none (${ms}ms)';
    final kind = timed
        ? (wordTimed ? 'word-timed' : 'timed')
        : plain
        ? 'plain'
        : 'no text';
    return '${namesMatch ? 'names ok' : 'names differ'}, '
        'length ${lengthDiff == null ? '?' : '+-${lengthDiff}s'}, '
        '$kind, $lines lines, $candidates cands (${ms}ms)';
  }
}

final _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) lyrics-probe/0.1';

/// GET [url] (or POST [form]) and decode JSON; throws on a non-200 answer.
Future<Object?> getJson(
  Uri url, {
  Map<String, String> headers = const {},
  Map<String, String>? form,
}) async {
  final request = form == null
      ? await _http.getUrl(url)
      : await _http.postUrl(url);
  headers.forEach(request.headers.set);
  if (form != null) {
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(Uri(queryParameters: form).query);
  }
  final response = await request.close().timeout(const Duration(seconds: 15));
  final body = await response
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 15));
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw HttpException('status ${response.statusCode}');
  }
  return jsonDecode(body);
}

/// Lower case, yo -> e, bracket tags and "feat." parts dropped, only
/// letters and digits kept (spaces collapsed).
String norm(String text) {
  var s = text.toLowerCase().replaceAll('ё', 'е');
  s = s.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
  s = s.replaceAll(RegExp(r'\b(feat|ft)\.?\s.*$'), ' ');
  s = s.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return s.trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Whether a candidate's artist and title name the song (either way round,
/// as crowd rows sometimes swap them).
bool namesMatch(Song song, String artist, String title) {
  bool same(String a, String b) {
    final x = norm(a), y = norm(b);
    if (x.isEmpty || y.isEmpty) return false;
    return x == y || x.contains(y) || y.contains(x);
  }

  bool artistOk(String candidate) =>
      same(song.artist, candidate) ||
      norm(song.artist)
          .split(' ')
          .where((w) => w.length > 2)
          .any((w) => norm(candidate).split(' ').contains(w));
  return (same(song.title, title) && artistOk(artist)) ||
      (same(song.title, artist) && artistOk(title));
}

/// Counts LRC time tags and lines with words; word timing shows as inline
/// tags like <00:12.34> or several tags on one line.
({int timedLines, int lines, bool wordTimed}) lrcFacts(String? lrc) {
  if (lrc == null || lrc.trim().isEmpty) {
    return (timedLines: 0, lines: 0, wordTimed: false);
  }
  final tag = RegExp(r'\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]');
  var timed = 0, lines = 0;
  var word = false;
  for (final line in const LineSplitter().convert(lrc)) {
    final text = line.replaceAll(tag, '').trim();
    if (tag.hasMatch(line)) timed++;
    if (text.isNotEmpty && !text.startsWith(RegExp(r'[a-z]+:'))) lines++;
    if (RegExp(r'<\d{1,2}:\d{2}[.:]\d{2,3}>').hasMatch(line)) word = true;
  }
  return (timedLines: timed, lines: lines, wordTimed: word);
}

/// How many of NetEase's and QQ's candidates get their lyrics asked, best
/// first, until one is timed (--tries).
var tries = 1;

/// Only these song indexes are asked outside (--only 3,11,...); all when
/// empty.
var only = <int>{};

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// LRCLIB: /api/get by artist, title, album and length; else /api/search.
Future<Verdict> askLrclib(Song song) async {
  final clock = Stopwatch()..start();
  final verdict = Verdict();
  try {
    final exact = await getJson(
      Uri.https('lrclib.net', '/api/get', {
        'artist_name': song.artist,
        'track_name': song.title,
        if (song.album.isNotEmpty) 'album_name': song.album,
        'duration': '${song.seconds}',
      }),
    );
    var rows = <Map<String, dynamic>>[if (exact is Map<String, dynamic>) exact];
    if (rows.isEmpty) {
      await pause(1400);
      final found = await getJson(
        Uri.https('lrclib.net', '/api/search', {
          'track_name': song.title,
          'artist_name': song.artist,
        }),
      );
      rows = (found as List? ?? const []).cast<Map<String, dynamic>>();
    }
    verdict.candidates = rows.length;
    pickBest(
      verdict,
      song,
      rows.map(
        (row) => (
          artist: '${row['artistName'] ?? ''}',
          title: '${row['trackName'] ?? ''}',
          seconds: (row['duration'] as num?)?.round(),
          lrc: row['syncedLyrics'] as String?,
          plain: row['plainLyrics'] as String?,
        ),
      ),
    );
  } catch (error) {
    verdict.error = error.runtimeType.toString();
    if (error is HttpException) verdict.error = error.message;
  }
  verdict.ms = clock.elapsedMilliseconds;
  return verdict;
}

/// Picks the best candidate (names, then length, then timed) into
/// [verdict]; candidates already carry their lyrics.
void pickBest(
  Verdict verdict,
  Song song,
  Iterable<
    ({String artist, String title, int? seconds, String? lrc, String? plain})
  >
  rows,
) {
  int score(
    ({String artist, String title, int? seconds, String? lrc, String? plain})
    row,
  ) {
    final names = namesMatch(song, row.artist, row.title) ? 1000 : 0;
    final diff = row.seconds == null ? 50 : (row.seconds! - song.seconds).abs();
    final timed = lrcFacts(row.lrc).timedLines > 0 ? 5 : 0;
    return names - diff.clamp(0, 100) * 3 + timed;
  }

  final sorted = rows.toList()..sort((a, b) => score(b) - score(a));
  if (sorted.isEmpty) return;
  final best = sorted.first;
  final facts = lrcFacts(best.lrc);
  verdict
    ..namesMatch = namesMatch(song, best.artist, best.title)
    ..lengthDiff = best.seconds == null
        ? null
        : (best.seconds! - song.seconds).abs()
    ..timed = facts.timedLines > 0
    ..wordTimed = facts.wordTimed
    ..plain = facts.timedLines == 0 && (best.plain?.trim().isNotEmpty ?? false)
    ..lines = facts.timedLines > 0
        ? facts.lines
        : const LineSplitter()
              .convert(best.plain ?? '')
              .where((l) => l.trim().isNotEmpty)
              .length;
}

/// NetEase: web search, then the best match's LRC.
Future<Verdict> askNetease(Song song) async {
  final clock = Stopwatch()..start();
  final verdict = Verdict();
  const headers = {'Referer': 'https://music.163.com/'};
  try {
    // The POST /api/search/get/web form now answers an encoded string.
    final found = await getJson(
      Uri.https('music.163.com', '/api/search/get', {
        's': '${song.artist} ${song.title}',
        'type': '1',
        'limit': '10',
        'offset': '0',
      }),
      headers: headers,
    );
    final result = (found as Map?)?['result'] as Map?;
    final songs = (result?['songs'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    verdict.candidates = songs.length;
    if (songs.isNotEmpty) {
      // Names and length first; only the best one's lyrics are asked.
      final rows = songs
          .map(
            (s) => (
              id: s['id'],
              artist: ((s['artists'] as List?) ?? const [])
                  .map((a) => '${(a as Map)['name']}')
                  .join(' '),
              title: '${s['name'] ?? ''}',
              seconds: ((s['duration'] as num?) ?? 0) ~/ 1000,
            ),
          )
          .toList();
      rows.sort((a, b) {
        int score(dynamic r) =>
            (namesMatch(song, r.artist as String, r.title as String)
                ? 1000
                : 0) -
            ((r.seconds as int) - song.seconds).abs().clamp(0, 100) * 3;
        return score(b) - score(a);
      });
      final asked =
          <
            ({
              String artist,
              String title,
              int? seconds,
              String? lrc,
              String? plain,
            })
          >[];
      for (final row in rows.take(tries)) {
        await pause(600);
        final lyric = await getJson(
          Uri.https('music.163.com', '/api/song/lyric', {
            'id': '${row.id}',
            'lv': '1',
            'kv': '1',
            'tv': '-1',
          }),
          headers: headers,
        );
        final lrc = ((lyric as Map?)?['lrc'] as Map?)?['lyric'] as String?;
        asked.add((
          artist: row.artist,
          title: row.title,
          seconds: row.seconds,
          lrc: lrc,
          plain: null,
        ));
        if (lrcFacts(lrc).timedLines > 0) break;
      }
      pickBest(verdict, song, asked);
    }
  } catch (error) {
    verdict.error = error is HttpException
        ? error.message
        : error.runtimeType.toString();
  }
  verdict.ms = clock.elapsedMilliseconds;
  return verdict;
}

/// QQ Music: the desktop search service, then the best match's LRC.
Future<Verdict> askQq(Song song) async {
  final clock = Stopwatch()..start();
  final verdict = Verdict();
  const headers = {'Referer': 'https://y.qq.com/'};
  try {
    final found = await getJson(
      Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
        'w': '${song.artist} ${song.title}',
        'format': 'json',
        'p': '1',
        'n': '10',
        'cr': '1',
      }),
      headers: headers,
    );
    final list =
        ((((found as Map?)?['data'] as Map?)?['song'] as Map?)?['list']
                    as List? ??
                const [])
            .cast<Map<String, dynamic>>();
    verdict.candidates = list.length;
    if (list.isNotEmpty) {
      final rows = list
          .map(
            (s) => (
              mid: '${s['songmid']}',
              artist: ((s['singer'] as List?) ?? const [])
                  .map((a) => '${(a as Map)['name']}')
                  .join(' '),
              title: '${s['songname'] ?? ''}',
              seconds: (s['interval'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList();
      rows.sort((a, b) {
        int score(dynamic r) =>
            (namesMatch(song, r.artist as String, r.title as String)
                ? 1000
                : 0) -
            ((r.seconds as int) - song.seconds).abs().clamp(0, 100) * 3;
        return score(b) - score(a);
      });
      final asked =
          <
            ({
              String artist,
              String title,
              int? seconds,
              String? lrc,
              String? plain,
            })
          >[];
      for (final row in rows.take(tries)) {
        await pause(600);
        final lyric = await getJson(
          Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
            'songmid': row.mid,
            'format': 'json',
            'nobase64': '1',
            'g_tk': '5381',
          }),
          headers: headers,
        );
        final lrc = (lyric as Map?)?['lyric'] as String?;
        asked.add((
          artist: row.artist,
          title: row.title,
          seconds: row.seconds,
          lrc: lrc,
          plain: null,
        ));
        if (lrcFacts(lrc).timedLines > 0) break;
      }
      pickBest(verdict, song, asked);
    }
  } catch (error) {
    verdict.error = error is HttpException
        ? error.message
        : error.runtimeType.toString();
  }
  verdict.ms = clock.elapsedMilliseconds;
  return verdict;
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final count = int.parse(valueOf('--count') ?? '60');
  final sources = (valueOf('--sources') ?? 'lrclib,netease,qq').split(',');
  final askVk = !args.contains('--no-vk-lyrics');
  tries = int.parse(valueOf('--tries') ?? '1');
  only = {
    for (final i in (valueOf('--only') ?? '').split(','))
      if (i.trim().isNotEmpty) int.parse(i.trim()),
  };
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  try {
    final reply = await client.call('audio.get', {
      'count': '$count',
    }) as Map<String, dynamic>;
    final items = (reply['items'] as List).cast<Map<String, dynamic>>();
    print('${items.length} songs; sources: ${sources.join(', ')}');

    // VK's own answer: none, plain or timed.
    final vkKind = <int, String>{};
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final flagged = item['has_lyrics'] == true || item['has_lyrics'] == 1;
      if (!flagged || !askVk) {
        vkKind[i] = flagged ? 'flagged' : 'none';
        continue;
      }
      await pause(700);
      try {
        final answer = await client.call('audio.getLyrics', {
          'audio_id': '${item['owner_id']}_${item['id']}',
        }) as Map<String, dynamic>;
        final lyrics = answer['lyrics'] as Map?;
        vkKind[i] = lyrics?['timestamps'] is List ? 'timed' : 'plain';
      } on VkException catch (error) {
        vkKind[i] = 'error ${error.code}';
      }
    }

    final verdicts = <String, List<Verdict>>{for (final s in sources) s: []};
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final song = Song(
        i,
        '${item['artist'] ?? ''}',
        '${item['title'] ?? ''}',
        '${(item['album'] as Map?)?['title'] ?? ''}',
        (item['duration'] as num?)?.toInt() ?? 0,
      );
      final line = StringBuffer('#$i vk ${vkKind[i]}');
      if (only.isNotEmpty && !only.contains(i)) {
        for (final source in sources) {
          verdicts[source]!.add(Verdict(error: 'skipped'));
        }
        continue;
      }
      for (final source in sources) {
        final verdict = switch (source) {
          'lrclib' => await askLrclib(song),
          'netease' => await askNetease(song),
          'qq' => await askQq(song),
          _ => Verdict(error: 'unknown source'),
        };
        verdicts[source]!.add(verdict);
        line.write(' | $source: $verdict');
        // LRCLIB allows about 45 calls a minute without a named app.
        await pause(source == 'lrclib' ? 1400 : 700);
      }
      print(line);
    }

    print('');
    print('TOTALS of ${items.length} songs:');
    final vkTimed = vkKind.values.where((k) => k == 'timed').length;
    final vkPlain = vkKind.values.where((k) => k == 'plain').length;
    print(
      'vk: timed $vkTimed, plain $vkPlain, none or other '
      '${items.length - vkTimed - vkPlain}',
    );
    for (final source in sources) {
      final list = verdicts[source]!;
      final ms = list.map((v) => v.ms).toList()..sort();
      int where(bool Function(Verdict) test) => list.where(test).length;
      print(
        '$source: answered ${where((v) => v.error == null)}, '
        'errors ${where((v) => v.error != null)} '
        '(${list.where((v) => v.error != null).map((v) => v.error).toSet().join(', ')}), '
        'any candidate ${where((v) => v.candidates > 0)}, '
        'names ok ${where((v) => v.namesMatch)}, '
        'good (names + length <= 5 s + text) ${where((v) => v.good)}, '
        'good timed ${where((v) => v.good && v.timed)}, '
        'good word-timed ${where((v) => v.good && v.wordTimed)}, '
        'length <= 2 s ${where((v) => v.namesMatch && (v.lengthDiff ?? 99) <= 2)}, '
        '<= 10 s ${where((v) => v.namesMatch && (v.lengthDiff ?? 99) <= 10)}, '
        'median ${ms.isEmpty ? 0 : ms[ms.length ~/ 2]} ms',
      );
    }

    // What the outside sources add to VK: timed lyrics where VK has none or
    // only plain text, and the songs nothing covers.
    bool anyGoodTimed(int i) =>
        sources.any((s) => verdicts[s]![i].good && verdicts[s]![i].timed);
    bool anyGood(int i) => sources.any((s) => verdicts[s]![i].good);
    final indexes = List.generate(items.length, (i) => i);
    final noneVk = indexes.where((i) => vkKind[i] == 'none').toList();
    final plainVk = indexes.where((i) => vkKind[i] == 'plain').toList();
    print(
      'VK none ${noneVk.length}: outside good ${noneVk.where(anyGood).length}, '
      'outside good timed ${noneVk.where(anyGoodTimed).length}',
    );
    print(
      'VK plain ${plainVk.length}: outside good timed '
      '${plainVk.where(anyGoodTimed).length}',
    );
    for (final source in sources) {
      final others = sources.where((s) => s != source);
      final only = indexes
          .where(
            (i) =>
                verdicts[source]![i].good &&
                verdicts[source]![i].timed &&
                !others.any(
                  (s) => verdicts[s]![i].good && verdicts[s]![i].timed,
                ),
          )
          .length;
      print('$source alone gives good timed lyrics for $only songs');
    }
    final timedAnywhere = indexes
        .where((i) => vkKind[i] == 'timed' || anyGoodTimed(i))
        .length;
    final textAnywhere = indexes
        .where(
          (i) => vkKind[i] == 'timed' || vkKind[i] == 'plain' || anyGood(i),
        )
        .length;
    print(
      'with VK + these sources: timed $timedAnywhere, any text '
      '$textAnywhere of ${items.length}',
    );
    final gaps = indexes
        .where((i) => vkKind[i] != 'timed' && !anyGoodTimed(i))
        .toList();
    print('no timed lyrics anywhere (indexes): ${gaps.join(' ')}');
  } finally {
    _http.close(force: true);
  }
}
