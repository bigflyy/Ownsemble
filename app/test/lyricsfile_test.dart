// Tests for plan 10 J3b: LRCLIB's word-timed lyrics, the `lyricsfile` YAML
// field of rows with `hasWordSync: true` (format seen on a real reply,
// 2026-11-26), read into lines with word times. The words are made up.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/lyrics/lyricsfile.dart';

const file = '''
version: '1.0'
metadata:
  title: Made Up
  artist: Nobody
  duration_ms: 60000
  instrumental: false
  language: ru
lines:
- text: Ночь улица фонарь
  start_ms: 1000
  end_ms: 2600
  words:
  - text: 'Ночь '
    start_ms: 1000
  - text: 'улица '
    start_ms: 1400
  - text: фонарь
    start_ms: 2000
- text: Don't stop now
  start_ms: 3000
  end_ms: 4500
  words:
  - text: 'Don''t '
    start_ms: 3000
  - text: 'stop '
    start_ms: 3300
  - text: now
    start_ms: 4000
- text: Hello again
  start_ms: 15000
  end_ms: 16000
  words:
  - text: 'Hel'
    start_ms: 15000
  - text: 'lo '
    start_ms: 15200
  - text: again
    start_ms: 15600
''';

void main() {
  test('lines and their words, a word ending where the next starts', () {
    final lyrics = lyricsFromLyricsfile('lrclib', file, songSeconds: 60)!;
    final sung = [
      for (final line in lyrics.lines)
        if (!line.isGap) line,
    ];
    expect(sung.map((line) => line.text), [
      'Ночь улица фонарь',
      "Don't stop now",
      'Hello again',
    ]);
    expect(sung[0].startMs, 1000);
    expect(sung[0].endMs, 2600);
    expect(sung[0].words, const [
      WordTime(1000, 1400),
      WordTime(1400, 2000),
      WordTime(2000, 2600),
    ]);
    expect(sung[1].words![0], const WordTime(3000, 3300));
    // Pieces without a space between them are one word on screen.
    expect(sung[2].words, const [
      WordTime(15000, 15600),
      WordTime(15600, 16000),
    ]);
  });

  test('a long pause and the end of the song get gap lines', () {
    final lyrics = lyricsFromLyricsfile('lrclib', file, songSeconds: 60)!;
    expect(lyrics.lines[2].isGap, isTrue, reason: '4.5 s to 15 s');
    expect(lyrics.lines[2].startMs, 4500);
    expect(lyrics.lines.last.isGap, isTrue, reason: 'singing ends at 16 s');
    expect(lyrics.timed, isTrue);
  });

  test('lines that do not fit the song, or too few, give nothing', () {
    expect(lyricsFromLyricsfile('lrclib', file, songSeconds: 5), isNull);
    expect(lyricsFromLyricsfile('lrclib', 'lines: []'), isNull);
    expect(lyricsFromLyricsfile('lrclib', ': not yaml ['), isNull);
    expect(lyricsFromLyricsfile('lrclib', null), isNull);
  });

  test('LRCLIB takes the lyricsfile of a word-synced row', () async {
    Future<Object?> getJson(
      Uri url, {
      Map<String, String> headers = const {},
      Object? body,
    }) async => url.path == '/api/get'
        ? {
            'id': 7,
            'artistName': 'Nobody',
            'trackName': 'Made Up',
            'duration': 60.0,
            'instrumental': false,
            'hasWordSync': true,
            'syncedLyrics':
                '[00:01.00]Ночь улица фонарь\n[00:03.00]Dont stop now\n'
                '[00:15.00]Hello again',
            'plainLyrics': 'x',
            'lyricsfile': file,
          }
        : const [];
    final found = await LrclibSource(getJson)
        .find(const SongNames(artist: 'Nobody', title: 'Made Up', seconds: 60));
    expect(found, isNotNull);
    expect(found!.lyrics.hasWordTimes, isTrue);
    expect(found.lyrics.lines[1].text, "Don't stop now");
  });
}
