// Tests for plan 10 E1: reading LRC text, matching an outside source's song
// to the song played, and the LRCLIB, NetEase and QQ readers with fake
// replies. The words and names are made up; the reply shapes are those of
// tool/probe_lyrics_outside.dart (session 37).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/lrc.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_match.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';

/// LRC text with one timed line per entry: [ms, words].
String lrcOf(List<(int, String)> lines) => [
  for (final (ms, words) in lines)
    '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
        '${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.'
        '${(ms % 1000 ~/ 10).toString().padLeft(2, '0')}]$words',
].join('\n');

/// Fake HTTP: answers by URL path; records every URL asked.
class FakeWeb {
  FakeWeb(this.answers);

  /// Path (and, for /api/search, the track_name) -> reply or a thrower.
  final Object? Function(Uri url) answers;
  final asked = <Uri>[];

  /// The POSTed body of each ask, null for a GET.
  final bodies = <Object?>[];

  Future<Object?> call(
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) {
    asked.add(url);
    bodies.add(body);
    lastHeaders = headers;
    return Future.value(answers(url));
  }

  Map<String, String> lastHeaders = const {};
}

const song = SongNames(
  artist: 'Ночные Тени',
  title: 'Город спит (Remastered)',
  album: 'Альбом',
  seconds: 200,
);

void main() {
  group('lyricsFromLrc', () {
    test('reads times, several tags on a line, offset and metadata', () {
      final lyrics = lyricsFromLrc(
        'lrclib',
        '[ar:Someone]\n[offset:+500]\n'
            '[00:10.50]Первая строка\n'
            '[00:20.00][00:40.00]Припев\n'
            '[00:30.1]Third\n'
            'no tag here\n',
      )!;
      expect(lyrics.timed, isTrue);
      expect(lyrics.source, 'lrclib');
      expect(lyrics.lines, const [
        LyricLine('Первая строка', startMs: 10000),
        LyricLine('Припев', startMs: 19500),
        LyricLine('Third', startMs: 29600),
        LyricLine('Припев', startMs: 39500),
      ]);
    });

    test('drops word tags, credits, a line naming the song, entities', () {
      final lyrics = lyricsFromLrc(
        'qq',
        '[00:00.00]Город спит - Ночные Тени\n'
            '[00:00.50]作词：Someone\n'
            '[00:01.00]作曲 : Someone\n'
            '[00:05.00]<00:05.00>One <00:05.50>two\n'
            '[00:08.00]Don&apos;t &amp; &#1046;\n'
            '[00:12.00]\n'
            '[00:15.00]Last',
        title: 'Город спит',
        artist: 'Ночные Тени',
      )!;
      expect(lyrics.lines, const [
        LyricLine('One two', startMs: 5000),
        LyricLine("Don't & Ж", startMs: 8000),
        LyricLine('', startMs: 12000),
        LyricLine('Last', startMs: 15000),
      ]);
    });

    test('times that do not fit the song become words only', () {
      final late = lrcOf([(1000, 'a'), (2000, 'b'), (400000, 'c')]);
      final shown = lyricsFromLrc('netease', late, songSeconds: 200)!;
      expect(shown.timed, isFalse);
      expect(shown.lines.map((line) => line.text), ['a', 'b', 'c']);
      expect(lyricsFromLrc('netease', late, songSeconds: 400)!.timed, isTrue);
      final short = lyricsFromLrc('netease', lrcOf([(1000, 'a'), (2000, '')]))!;
      expect(short.timed, isFalse, reason: 'fewer than 3 lines with words');
    });

    test('text without time tags is plain; empty text is nothing', () {
      final plain = lyricsFromLrc('qq', 'Строка\n\n\nДругая\n')!;
      expect(plain.timed, isFalse);
      expect(plain.lines, const [
        LyricLine('Строка'),
        LyricLine(''),
        LyricLine('Другая'),
      ]);
      expect(lyricsFromLrc('qq', '  \n'), isNull);
      expect(lyricsFromLrc('qq', '[00:01.00]\n[00:02.00]'), isNull);
      expect(lyricsFromPlain('lrclib', null), isNull);
    });
  });

  group('matchNames', () {
    NameMatch match(String artist, String title) => matchNames(
      songArtist: 'Ночные Тени',
      songTitle: 'Город спит (Remastered)',
      artist: artist,
      title: title,
    );

    test('exact despite case, yo, tags and feat.', () {
      expect(match('ночные тени feat. Кто-то', 'ГОРОД СПИТ'), NameMatch.exact);
      expect(match('Тени', 'Город спит [Live]'), NameMatch.exact);
      expect(
        matchNames(
          songArtist: 'Ёлка',
          songTitle: 'Ещё',
          artist: 'Елка',
          title: 'Еще',
        ),
        NameMatch.exact,
      );
    });

    test('swapped artist and title still agree', () {
      expect(match('Город спит', 'Ночные Тени'), NameMatch.exact);
    });

    test('Latin spellings agree loosely', () {
      expect(match('Nochnye Teni', 'Gorod spit'), NameMatch.loose);
      expect(
        matchNames(
          songArtist: 'Аквариум',
          songTitle: 'Город',
          artist: 'Aquarium',
          title: 'Gorod',
        ),
        NameMatch.loose,
      );
    });

    test('other songs do not agree', () {
      expect(match('Ночные Тени', 'Другая песня'), NameMatch.none);
      expect(match('Кто-то ещё', 'Город спит'), NameMatch.none);
    });

    test('lengths: exact within 5 s, loose within 3 s, none without', () {
      expect(takeCandidate(NameMatch.exact, 5), isTrue);
      expect(takeCandidate(NameMatch.exact, 6), isFalse);
      expect(takeCandidate(NameMatch.loose, 3), isTrue);
      expect(takeCandidate(NameMatch.loose, 4), isFalse);
      expect(takeCandidate(NameMatch.exact, null), isFalse);
      expect(takeCandidate(NameMatch.none, 0), isFalse);
    });

    test('another version: the same names, another known length (G4a)', () {
      bool other(String artist, String title, int? diff) =>
          otherVersionCandidate(
            songArtist: 'Ночные Тени',
            songTitle: 'Город спит (Live)',
            artist: artist,
            title: title,
            lengthDiffSeconds: diff,
          );
      expect(other('Ночные тени', 'Город спит', 6), isTrue);
      expect(other('Ночные Тени', 'Город спит (Remastered)', 3626), isTrue);
      expect(other('Ночные Тени', 'Город спит - Live at Home', 30), isTrue);
      expect(
        other('Ночные Тени', 'Город спит', 5),
        isFalse,
        reason: "the song's own length is taken, not another version",
      );
      expect(
        other('Ночные Тени', 'Город спит', null),
        isFalse,
        reason: 'an unknown length says nothing',
      );
      expect(
        other('Nochnye Teni', 'Gorod spit', 40),
        isFalse,
        reason: 'loose names only with the own length',
      );
      expect(
        other('Ночные Тени', 'Город спит снова', 40),
        isFalse,
        reason: 'a title inside a longer one is another song',
      );
      expect(other('Тени', 'Город спит', 40), isFalse);
    });

    test('transliterate keeps capitals and other characters', () {
      expect(transliterate('Ночные Тени - 2'), 'Nochnye Teni - 2');
      expect(hasCyrillic('abc'), isFalse);
      expect(hasCyrillic('abв'), isTrue);
    });
  });

  group('LRCLIB', () {
    Map<String, Object?> row({
      int id = 1,
      String artist = 'Ночные Тени',
      String title = 'Город спит',
      num duration = 201,
      String? synced,
      String? plain,
      bool instrumental = false,
    }) => {
      'id': id,
      'artistName': artist,
      'trackName': title,
      'duration': duration,
      'instrumental': instrumental,
      'syncedLyrics': synced,
      'plainLyrics': plain,
    };

    final timed = lrcOf([(1000, 'Раз'), (2000, 'Два'), (3000, 'Три')]);

    test('/api/get hit: timed lyrics, the app named, no search', () async {
      final web = FakeWeb(
        (url) => url.path == '/api/get' ? row(synced: timed) : [],
      );
      final found = (await LrclibSource(web.call).find(song))!;
      expect(found.lyrics.timed, isTrue);
      expect(found.source, 'lrclib');
      expect(found.names, NameMatch.exact);
      expect(found.lengthDiff, 1);
      expect(web.asked.map((url) => url.path), ['/api/get']);
      expect(web.asked.single.queryParameters['duration'], '200');
      expect(web.lastHeaders['User-Agent'], 'Ownsemble v2');
    });

    test('a miss searches without tags, then in Latin letters', () async {
      final web = FakeWeb((url) {
        if (url.path == '/api/get') return null;
        final title = url.queryParameters['track_name'];
        return title == 'Gorod spit'
            ? [row(artist: 'Nochnye Teni', title: 'Gorod spit', synced: timed)]
            : [row(title: 'Другая', synced: timed)];
      });
      final found = (await LrclibSource(web.call).find(song))!;
      expect(found.names, NameMatch.loose);
      expect(
        web.asked.map((url) => url.queryParameters['track_name']).toList(),
        ['Город спит (Remastered)', 'Город спит', 'Gorod spit'],
      );
    });

    test('best row: timed first, then length; plain when no timed', () async {
      var rows = [
        row(id: 1, duration: 204, synced: timed),
        row(id: 2, duration: 200, plain: 'Слова\nещё'),
        row(id: 3, duration: 230, synced: timed),
        row(id: 4, duration: 200, instrumental: true),
      ];
      final web = FakeWeb((url) => url.path == '/api/get' ? null : rows);
      final source = LrclibSource(web.call);
      final timedFound = (await source.find(song))!;
      expect(timedFound.id, '1');
      expect(timedFound.lyrics.timed, isTrue);
      rows = [rows[1], rows[2], rows[3]];
      final plainFound = (await source.find(song))!;
      expect(plainFound.id, '2', reason: 'the timed row is 30 s off');
      expect(plainFound.lyrics.timed, isFalse);
    });

    test('/api/get words only: the search may still find timed', () async {
      final web = FakeWeb(
        (url) => url.path == '/api/get'
            ? row(id: 1, plain: 'Слова\nещё')
            : [row(id: 2, synced: timed)],
      );
      final found = (await LrclibSource(web.call).find(song))!;
      expect(found.id, '2');
      expect(found.lyrics.timed, isTrue);
    });

    test(
      'nothing of this length: none, unless the names agree exactly',
      () async {
        final web = FakeWeb(
          (url) => url.path == '/api/get'
              ? null
              : [
                  row(
                    artist: 'Nochnye Teni',
                    title: 'Gorod spit',
                    duration: 260,
                  ),
                ],
        );
        expect(await LrclibSource(web.call).find(song), isNull);
      },
    );

    test(
      'a live upload gets the studio row as another version (G4a)',
      () async {
        // The studio song is 225 s; the live upload 3851 s, or 218 s: the
        // studio's last lines lie past the shorter upload's end, so the row
        // is read against its own length, or its times would be dropped.
        final studio = lrcOf([
          (10000, 'Раз'),
          (100000, 'Два'),
          (220000, 'Три'),
        ]);
        for (final seconds in [3851, 218]) {
          final live = SongNames(
            artist: 'Ночные Тени',
            title: 'Город спит (Live)',
            seconds: seconds,
          );
          final web = FakeWeb(
            (url) => url.path == '/api/get'
                ? null
                : [row(duration: 225, synced: studio)],
          );
          final found = (await LrclibSource(web.call).find(live))!;
          expect(found.otherVersion, isTrue);
          expect(found.lyrics.timed, isTrue, reason: '$seconds s');
          expect(found.lengthDiff, (seconds - 225).abs());
          expect(jsonDecode(found.metaToJson())['other'], isTrue);
          expect(
            web.asked.map((url) => url.queryParameters['track_name']).toList(),
            ['Город спит (Live)', 'Город спит', 'Gorod spit'],
            reason: 'another version does not end the search',
          );
        }
      },
    );

    test("a row of the song's own length beats another version", () async {
      final web = FakeWeb((url) {
        if (url.path == '/api/get') return null;
        return url.queryParameters['track_name'] == 'Gorod spit'
            ? [row(id: 2, plain: 'Слова\nещё')]
            : [row(id: 1, duration: 300, synced: timed)];
      });
      final found = (await LrclibSource(web.call).find(song))!;
      expect(found.id, '2', reason: 'own length, though words only');
      expect(found.otherVersion, isFalse);
      expect(found.metaToJson(), isNot(contains('other')));
    });

    test('a failed later search keeps what came before', () async {
      final web = FakeWeb((url) {
        if (url.path == '/api/get') return null;
        if (url.queryParameters['track_name'] == 'Gorod spit') {
          throw const LyricsSourceException('timed out');
        }
        return [row(id: 3, duration: 260, synced: timed)];
      });
      final found = (await LrclibSource(web.call).find(song))!;
      expect(found.id, '3');
      expect(found.otherVersion, isTrue);
    });

    test('a refusal is thrown to the caller', () async {
      final source = LrclibSource(
        (url, {headers = const {}, body}) async =>
            throw const LyricsSourceException('status 429', slowDown: true),
      );
      expect(() => source.find(song), throwsA(isA<LyricsSourceException>()));
    });
  });

  group('NetEase and QQ', () {
    final timed = lrcOf([(1000, 'Раз'), (2000, 'Два'), (3000, 'Три')]);

    test('NetEase: search, then the best taken row until timed', () async {
      final web = FakeWeb((url) {
        if (url.path == '/api/search/get') {
          return {
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 7,
                  'name': 'Город спит',
                  'duration': 260000,
                  'artists': [
                    {'name': 'Ночные Тени'},
                  ],
                },
                {
                  'id': 8,
                  'name': 'Город спит',
                  'duration': 202000,
                  'artists': [
                    {'name': 'Ночные Тени'},
                  ],
                },
                {
                  'id': 9,
                  'name': 'Город спит',
                  'duration': 199000,
                  'artists': [
                    {'name': 'Ночные Тени'},
                  ],
                },
              ],
            },
          };
        }
        final id = url.queryParameters['id'];
        return {
          'lrc': {'lyric': id == '9' ? 'Только слова\nещё' : timed},
        };
      });
      final found = (await NeteaseSource(web.call).find(song))!;
      expect(found.id, '8');
      expect(found.lyrics.timed, isTrue);
      expect(
        web.asked.map((url) => url.queryParameters['id']).whereType<String>(),
        ['9', '8'],
        reason: 'closest length first, the far one never asked',
      );
    });

    test('NetEase: only other lengths: the closest as another version '
        '(G4a)', () async {
      final asked = <String>[];
      final web = FakeWeb((url) {
        if (url.path == '/api/search/get') {
          return {
            'code': 200,
            'result': {
              'songs': [
                for (final (id, ms) in [(7, 290000), (8, 230000)])
                  {
                    'id': id,
                    'name': 'Город спит',
                    'duration': ms,
                    'artists': [
                      {'name': 'Ночные Тени'},
                    ],
                  },
                {
                  'id': 9,
                  'name': 'Gorod spit',
                  'duration': 200000,
                  'artists': [
                    {'name': 'Nochnye Teni'},
                  ],
                },
              ],
            },
          };
        }
        asked.add(url.queryParameters['id']!);
        return {
          'lrc': {'lyric': url.queryParameters['id'] == '9' ? '' : timed},
        };
      });
      final found = (await NeteaseSource(web.call).find(song))!;
      expect(found.id, '8');
      expect(found.otherVersion, isTrue);
      expect(found.lyrics.timed, isTrue);
      expect(asked, ['9', '8'], reason: 'own length first, then the closest');
    });

    test('NetEase: an error code is a failure', () async {
      final web = FakeWeb((url) => {'code': -460, 'message': 'x'});
      expect(
        () => NeteaseSource(web.call).find(song),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    Map<String, Object?> qqSearch(List<Map<String, Object?>> songs) => {
      'code': 0,
      'req': {
        'code': 0,
        'data': {
          'body': {'item_song': songs},
        },
      },
    };
    const qqBusy = {
      'code': 0,
      'req': {'code': 2001},
    };
    const qqSong = {
      'mid': 'm1',
      'title': 'Gorod spit',
      'interval': 201,
      'singer': [
        {'name': 'Nochnye Teni'},
      ],
    };

    test('QQ: mobile search (POST), then lyrics by songmid', () async {
      final web = FakeWeb((url) {
        if (url.path.endsWith('musicu.fcg')) return qqSearch([qqSong]);
        return {'lyric': '[00:00.00]Gorod spit - Nochnye Teni\n$timed'};
      });
      final found = (await QqSource(web.call).find(song))!;
      expect(found.id, 'm1');
      expect(found.names, NameMatch.loose);
      expect(found.lyrics.lines.first.text, 'Раз');
      expect(web.asked.first.host, 'u.y.qq.com');
      final ask = web.bodies.first! as Map;
      expect(
        ((ask['req'] as Map)['param'] as Map)['query'],
        'Ночные Тени Город спит',
        reason: 'tags such as (Remastered) left out of the search',
      );
      expect(web.asked.last.queryParameters['songmid'], 'm1');
      expect(web.bodies.last, isNull, reason: 'the lyrics are a GET');
    });

    test('QQ: a 2001 answer is asked again', () async {
      var searches = 0;
      final web = FakeWeb((url) {
        if (url.path.endsWith('musicu.fcg')) {
          return ++searches < 3 ? qqBusy : qqSearch([qqSong]);
        }
        return {'lyric': timed};
      });
      final found = await QqSource(
        web.call,
        retryPause: Duration.zero,
      ).find(song);
      expect(found?.id, 'm1');
      expect(searches, 3);
    });

    test('QQ: 2001 four times, or another code, is a failure', () async {
      var searches = 0;
      final busy = FakeWeb((url) {
        searches++;
        return qqBusy;
      });
      await expectLater(
        QqSource(busy.call, retryPause: Duration.zero).find(song),
        throwsA(isA<LyricsSourceException>()),
      );
      expect(searches, 4);
      final other = FakeWeb(
        (url) => {
          'code': 0,
          'req': {'code': 500},
        },
      );
      await expectLater(
        QqSource(other.call, retryPause: Duration.zero).find(song),
        throwsA(isA<LyricsSourceException>()),
      );
    });
  });

  test('candidate facts round trip as stored meta', () {
    const candidate = LyricsCandidate(
      lyrics: Lyrics(source: 'lrclib', lines: [LyricLine('x')]),
      id: '5',
      artist: 'A',
      title: 'Т',
      seconds: 100,
      names: NameMatch.loose,
      lengthDiff: 2,
    );
    expect(
      candidate.metaToJson(),
      '{"id":"5","artist":"A","title":"Т","seconds":100,"exact":false,"diff":2}',
    );
  });
}
