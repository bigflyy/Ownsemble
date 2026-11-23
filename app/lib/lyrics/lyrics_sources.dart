/// Outside lyrics sources behind one interface (plan 10, E1).
///
/// From the A4 probe (session 37, all 126 test-account songs): LRCLIB gave
/// good timed lyrics for 82% of the songs in about 300 ms, NetEase and QQ
/// Music added 3 songs more but are slow (~1.5 s) and drop calls. Each
/// source is searched by the song's artist and title and answers its best
/// candidate that [takeCandidate] accepts, or none. Nothing here logs names,
/// words or links.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lrc.dart';
import 'lyrics.dart';
import 'lyrics_match.dart';

/// What a source is searched with: the song as the library knows it.
class SongNames {
  const SongNames({
    required this.artist,
    required this.title,
    this.album,
    required this.seconds,
  });

  final String artist;
  final String title;
  final String? album;

  /// The song's length; 0 when unknown (then nothing is taken).
  final int seconds;
}

/// One source's song with its lyrics, matched to the song played.
class LyricsCandidate {
  const LyricsCandidate({
    required this.lyrics,
    required this.id,
    required this.artist,
    required this.title,
    required this.seconds,
    required this.names,
    required this.lengthDiff,
    this.otherVersion = false,
  });

  final Lyrics lyrics;

  /// The source's own id of the song (LRCLIB row, NetEase song, QQ mid).
  final String id;
  final String artist;
  final String title;
  final int? seconds;
  final NameMatch names;

  /// Seconds between this song's length and the played song's.
  final int? lengthDiff;

  /// The lyrics of another version of the song: the names agree but the
  /// length does not ([otherVersionCandidate]); their timing is not the
  /// played recording's until fitted to it.
  final bool otherVersion;

  String get source => lyrics.source;

  /// The candidate's facts as stored with its lyrics (`lyrics.meta`).
  String metaToJson() => jsonEncode({
    'id': id,
    'artist': artist,
    'title': title,
    'seconds': ?seconds,
    'exact': names == NameMatch.exact,
    'diff': ?lengthDiff,
    if (otherVersion) 'other': true,
  });
}

/// A source refused or could not be reached. [slowDown] when it asked to
/// wait (HTTP 429).
class LyricsSourceException implements Exception {
  const LyricsSourceException(this.message, {this.slowDown = false});
  final String message;
  final bool slowDown;

  @override
  String toString() => 'LyricsSourceException($message)';
}

/// Reads JSON from [url] with [headers]: the decoded reply, or null when
/// the server says it has no such thing (404). With [body] the request is a
/// POST of that value as JSON. Throws [LyricsSourceException] for other
/// answers and on network failures.
typedef GetJson = Future<Object?> Function(
  Uri url, {
  Map<String, String> headers,
  Object? body,
});

/// An outside lyrics source.
abstract class OutsideLyricsSource {
  /// Stored as the lyrics' source: 'lrclib', 'netease', 'qq'.
  String get id;

  /// The best candidate for [song] that [takeCandidate] accepts, or null
  /// when the source has none.
  Future<LyricsCandidate?> find(SongNames song);
}

/// The sources in the order the pick walks them (design point 5).
List<OutsideLyricsSource> outsideLyricsSources(GetJson getJson) => [
  LrclibSource(getJson),
  NeteaseSource(getJson),
  QqSource(getJson),
];

/// The name a source is shown with.
String lyricsSourceLabel(String source) => switch (source) {
  'vk' => 'VK',
  'lrclib' => 'LRCLIB',
  'netease' => 'NetEase',
  'qq' => 'QQ Music',
  _ => source,
};

/// Orders candidates best first: the song's own length before another
/// version (G4a), then timed before words only (the user's "timed first",
/// 2026-11-22), then exact names, then the closer length.
int compareCandidates(LyricsCandidate a, LyricsCandidate b) {
  final byOwn = (a.otherVersion ? 1 : 0).compareTo(b.otherVersion ? 1 : 0);
  if (byOwn != 0) return byOwn;
  final byTimed = (b.lyrics.timed ? 1 : 0).compareTo(a.lyrics.timed ? 1 : 0);
  if (byTimed != 0) return byTimed;
  final byNames = b.names.index.compareTo(a.names.index);
  if (byNames != 0) return byNames;
  return (a.lengthDiff ?? 999).compareTo(b.lengthDiff ?? 999);
}

/// The song's title without bracket tags, for a search ("(Remastered
/// 2011)" finds nothing at LRCLIB).
String searchTitle(String title) {
  final clean = title.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '').trim();
  return clean.isEmpty ? title : clean;
}

/// A source's song before its lyrics are read: names, length and how
/// they agree with the song played.
class SourceRow {
  SourceRow(this.song, this.id, this.artist, this.title, this.seconds)
    : names = matchNames(
        songArtist: song.artist,
        songTitle: song.title,
        artist: artist,
        title: title,
      ),
      lengthDiff = seconds == null || song.seconds <= 0
          ? null
          : (seconds - song.seconds).abs();

  final SongNames song;
  final String id;
  final String artist;
  final String title;
  final int? seconds;
  final NameMatch names;
  final int? lengthDiff;

  bool get taken => takeCandidate(names, lengthDiff);

  /// Not taken, but its lyrics may be offered as another version's (G4a).
  late final bool otherVersion = otherVersionCandidate(
    songArtist: song.artist,
    songTitle: song.title,
    artist: artist,
    title: title,
    lengthDiffSeconds: lengthDiff,
  );

  /// The length the row's LRC times are checked against: the song's for a
  /// taken row; the row's own for another version, whose times belong to
  /// that version (a shorter live upload would drop the studio's last
  /// lines otherwise).
  int? lrcSeconds() => otherVersion ? seconds : song.seconds;

  LyricsCandidate? withLyrics(Lyrics? lyrics) => lyrics == null
      ? null
      : LyricsCandidate(
          lyrics: lyrics,
          id: id,
          artist: artist,
          title: title,
          seconds: seconds,
          names: names,
          lengthDiff: lengthDiff,
          otherVersion: otherVersion,
        );
}

/// Whether [best] ends a source's search: timed lyrics of the song's own
/// length.
bool _settles(LyricsCandidate? best) =>
    best != null && best.lyrics.timed && !best.otherVersion;

/// The best of [candidates], or null.
LyricsCandidate? _best(Iterable<LyricsCandidate> candidates) {
  final list = candidates.toList()..sort(compareCandidates);
  return list.isEmpty ? null : list.first;
}

/// LRCLIB (lrclib.net/docs.md): an open lyrics database. /api/get finds a
/// song by artist, title, album and length; when it has none, /api/search
/// by artist and title, and for Cyrillic names once more in Latin letters.
class LrclibSource implements OutsideLyricsSource {
  LrclibSource(this._getJson);

  final GetJson _getJson;

  /// LRCLIB asks apps to name themselves (the user agreed to "Ownsemble
  /// v2", 2026-11-22).
  static const headers = {'User-Agent': 'Ownsemble v2'};

  @override
  String get id => 'lrclib';

  /// The lengths /api/get takes: it answers 400 ("duration: must be
  /// between 1 and 3600") for any other, such as an hour-long concert
  /// upload (real reply, 2026-11-23); those songs go to the search.
  static bool _getTakes(int seconds) => seconds >= 1 && seconds <= 3600;

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    final exact = !_getTakes(song.seconds)
        ? null
        : await _getJson(
            Uri.https('lrclib.net', '/api/get', {
              'artist_name': song.artist,
              'track_name': song.title,
              if (song.album != null && song.album!.isNotEmpty)
                'album_name': song.album!,
              'duration': '${song.seconds}',
            }),
            headers: headers,
          );
    // Each step only while nothing timed is taken: /api/get can answer a
    // words-only row while a search finds a timed one (check 40a, song 0).
    // A later search that fails does not lose what an earlier step found
    // (Codex review of G4: another version no longer ends the search).
    final rows = <Object?>[if (exact is Map) exact];
    var best = _bestOf(song, rows);
    if (_settles(best)) return best;
    try {
      final title = searchTitle(song.title);
      rows.addAll(await _search(title, song.artist));
      best = _bestOf(song, rows);
      if (_settles(best)) return best;
      if (hasCyrillic(song.artist) || hasCyrillic(title)) {
        rows.addAll(
          await _search(transliterate(title), transliterate(song.artist)),
        );
        best = _bestOf(song, rows);
      }
    } on LyricsSourceException {
      if (best == null) rethrow;
    }
    return best;
  }

  Future<List<Object?>> _search(String title, String artist) async {
    final found = await _getJson(
      Uri.https('lrclib.net', '/api/search', {
        'track_name': title,
        'artist_name': artist,
      }),
      headers: headers,
    );
    return found is List ? found : const [];
  }

  /// The best row of [rows] with words, taken or another version's; an
  /// instrumental row has none.
  LyricsCandidate? _bestOf(SongNames song, List<Object?> rows) {
    final found = <LyricsCandidate>[];
    for (final row in rows) {
      if (row is! Map || row['instrumental'] == true) continue;
      final candidate = SourceRow(
        song,
        '${row['id'] ?? ''}',
        '${row['artistName'] ?? ''}',
        '${row['trackName'] ?? ''}',
        (row['duration'] as num?)?.round(),
      );
      if (!candidate.taken && !candidate.otherVersion) continue;
      final lyrics =
          lyricsFromLrc(
            id,
            row['syncedLyrics'] as String?,
            songSeconds: candidate.lrcSeconds(),
          ) ??
          lyricsFromPlain(id, row['plainLyrics'] as String?);
      final withLyrics = candidate.withLyrics(lyrics);
      if (withLyrics != null) found.add(withLyrics);
    }
    return _best(found);
  }
}

/// Shared by NetEase and QQ: their search gives names and lengths only, so
/// the lyrics of the best taken rows are read one by one (at most
/// [_lyricsTries]) until one is timed.
abstract class _SearchThenLyrics implements OutsideLyricsSource {
  _SearchThenLyrics(this.getJson);

  final GetJson getJson;

  static const _lyricsTries = 2;

  Future<List<SourceRow>> search(SongNames song);

  Future<String?> lrcOf(SourceRow row);

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    final rows = await search(song);
    final taken = rows.where((row) => row.taken).toList()
      ..sort((a, b) {
        final byNames = b.names.index.compareTo(a.names.index);
        if (byNames != 0) return byNames;
        return a.lengthDiff!.compareTo(b.lengthDiff!);
      });
    final found = await _read(taken);
    if (found.isNotEmpty) return _best(found);
    // Nothing of the song's own length: another version's lyrics, the
    // closest length first (G4a).
    final other = rows.where((row) => row.otherVersion).toList()
      ..sort(
        (a, b) => (a.lengthDiff ?? 1 << 30).compareTo(b.lengthDiff ?? 1 << 30),
      );
    return _best(await _read(other));
  }

  /// Reads the lyrics of up to [_lyricsTries] of [rows] in order, until
  /// timed ones come.
  Future<List<LyricsCandidate>> _read(List<SourceRow> rows) async {
    final found = <LyricsCandidate>[];
    for (final row in rows.take(_lyricsTries)) {
      final String? lrc;
      try {
        lrc = await lrcOf(row);
      } on LyricsSourceException {
        // Lyrics read before stay; with none the failure is the answer.
        if (found.isEmpty) rethrow;
        break;
      }
      final candidate = row.withLyrics(
        lyricsFromLrc(
          id,
          lrc,
          songSeconds: row.lrcSeconds(),
          title: row.title,
          artist: row.artist,
        ),
      );
      if (candidate == null) continue;
      found.add(candidate);
      if (candidate.lyrics.timed) break;
    }
    return found;
  }
}

/// NetEase Cloud Music's web API (no key): /api/search/get, then
/// /api/song/lyric. The POST web form answers an encoded string since 2026.
class NeteaseSource extends _SearchThenLyrics {
  NeteaseSource(super.getJson);

  static const headers = {'Referer': 'https://music.163.com/'};

  @override
  String get id => 'netease';

  @override
  Future<List<SourceRow>> search(SongNames song) async {
    final found = await getJson(
      Uri.https('music.163.com', '/api/search/get', {
        's': '${song.artist} ${searchTitle(song.title)}',
        'type': '1',
        'limit': '10',
        'offset': '0',
      }),
      headers: headers,
    );
    if (found is Map && found['code'] is num && found['code'] != 200) {
      throw LyricsSourceException('NetEase code ${found['code']}');
    }
    final result = found is Map ? found['result'] : null;
    final songs = result is Map ? result['songs'] : null;
    return [
      for (final item in songs is List ? songs : const [])
        if (item is Map)
          SourceRow(
            song,
            '${item['id']}',
            [
              for (final artist in item['artists'] as List? ?? const [])
                if (artist is Map) '${artist['name'] ?? ''}',
            ].join(' '),
            '${item['name'] ?? ''}',
            (item['duration'] as num?) == null
                ? null
                : (item['duration'] as num) ~/ 1000,
          ),
    ];
  }

  @override
  Future<String?> lrcOf(SourceRow row) async {
    final lyric = await getJson(
      Uri.https('music.163.com', '/api/song/lyric', {
        'id': row.id,
        'lv': '1',
        'kv': '1',
        'tv': '-1',
      }),
      headers: headers,
    );
    final lrc = lyric is Map ? lyric['lrc'] : null;
    return lrc is Map ? lrc['lyric'] as String? : null;
  }
}

/// QQ Music (no key): the mobile search of musicu.fcg, then
/// fcg_query_lyric_new with the lyrics unencoded.
///
/// The older desktop search (client_search_cp) answers HTTP 500 after 5-7 s
/// since 2026-11-22 (open check B27). The mobile search answers at once,
/// but often (11 of 26 asks by hand, also twice in a row for the same
/// words) with code 2001 and no songs; asking again brings them, so a
/// 2001 is asked again up to [_searchTries] times. Asked back to back for
/// 126 songs (sources-43a-qq), 33 still got 2001 after 4 tries, in runs of
/// 2-3 songs: a throttle of a few seconds, which the app's slower pace
/// (QQ only while nothing is timed, and in the chooser) rarely meets.
class QqSource extends _SearchThenLyrics {
  QqSource(
    super.getJson, {
    this.retryPause = const Duration(milliseconds: 700),
  });

  static const headers = {'Referer': 'https://y.qq.com/'};

  static const _searchTries = 4;

  /// The wait before asking again after a 2001.
  final Duration retryPause;

  @override
  String get id => 'qq';

  @override
  Future<List<SourceRow>> search(SongNames song) async {
    final ask = {
      'comm': {'ct': '11', 'cv': '1003006', 'uin': '0'},
      'req': {
        'module': 'music.search.SearchCgiService',
        'method': 'DoSearchForQQMusicMobile',
        'param': {
          'query': '${song.artist} ${searchTitle(song.title)}',
          'search_type': 0,
          'grp': 1,
          'num_per_page': 10,
          'page_num': 1,
        },
      },
    };
    Object? req;
    for (var tries = 1; ; tries++) {
      final found = await getJson(
        Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
        headers: headers,
        body: ask,
      );
      req = found is Map ? found['req'] : null;
      final code = req is Map ? req['code'] : null;
      if (code == 0) break;
      if (code == 2001 && tries < _searchTries) {
        await Future<void>.delayed(retryPause);
        continue;
      }
      throw LyricsSourceException('QQ code $code');
    }
    final data = req is Map ? req['data'] : null;
    final body = data is Map ? data['body'] : null;
    final list = body is Map ? body['item_song'] : null;
    return [
      for (final item in list is List ? list : const [])
        if (item is Map && item['mid'] != null)
          SourceRow(
            song,
            '${item['mid']}',
            [
              for (final singer in item['singer'] as List? ?? const [])
                if (singer is Map) '${singer['name'] ?? ''}',
            ].join(' '),
            // The title keeps tags such as "(Live)"; the name drops them.
            '${item['title'] ?? item['name'] ?? ''}',
            (item['interval'] as num?)?.toInt(),
          ),
    ];
  }

  @override
  Future<String?> lrcOf(SourceRow row) async {
    final lyric = await getJson(
      Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
        'songmid': row.id,
        'format': 'json',
        'nobase64': '1',
        'g_tk': '5381',
      }),
      headers: headers,
    );
    return lyric is Map ? lyric['lyric'] as String? : null;
  }
}

/// [GetJson] over dart:io: 10 s to connect, 15 s for the answer.
///
/// NetEase closes idle connections quickly, and a request on such a closed
/// one fails within milliseconds (check 40a: "HttpException" in 1-2 ms, the
/// probe's "connection closed"): idle connections are dropped after 1 s and
/// a request that fails before any answer is sent once more.
GetJson httpGetJson() {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 1)
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';
  Future<Object?> once(
    Uri url,
    Map<String, String> headers,
    Object? body,
  ) async {
    final request = body == null
        ? await http.getUrl(url)
        : await http.postUrl(url);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response;
    try {
      response = await request.close().timeout(const Duration(seconds: 15));
    } on IOException {
      throw const _NoAnswer();
    }
    final text = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return null;
    if (response.statusCode == 429) {
      throw const LyricsSourceException('status 429', slowDown: true);
    }
    if (response.statusCode != 200) {
      throw LyricsSourceException('status ${response.statusCode}');
    }
    return jsonDecode(text);
  }

  return (url, {headers = const {}, body}) async {
    try {
      try {
        return await once(url, headers, body);
      } on _NoAnswer {
        return await once(url, headers, body);
      }
    } on _NoAnswer {
      throw const LyricsSourceException('connection closed');
    } on LyricsSourceException {
      rethrow;
    } on FormatException {
      throw const LyricsSourceException('not JSON');
    } on TimeoutException {
      throw const LyricsSourceException('timeout');
    } on IOException catch (error) {
      throw LyricsSourceException(error.runtimeType.toString());
    }
  };
}

/// A request that failed before any answer came: safe to send again.
class _NoAnswer implements Exception {
  const _NoAnswer();
}
