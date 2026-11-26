// Tests for plan 10 C1/C2: reading VK's lyrics replies, finding the line
// sung at a moment, and keeping lyrics in the library. The words are made
// up; the reply shapes are those of tool/probe_lyrics.dart (2026-11-21).

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_lyrics.dart';

Map<String, Object?> timedReply(List<List<Object?>> stamps) => {
  'md5': 'abc123',
  'credits': '',
  'lyrics': {
    'language': 'en',
    'timestamps': [
      for (final stamp in stamps)
        {'begin': stamp[0], 'end': stamp[1], 'line': stamp[2]},
    ],
  },
};

Map<String, Object?> plainReply(List<String> lines) => {
  'md5': 'def456',
  'credits': '',
  'lyrics': {'language': 'ru', 'text': lines},
};

void main() {
  group('lyricsFromVk', () {
    test('timed lines keep their times in milliseconds', () {
      final lyrics = lyricsFromVk(
        timedReply([
          [1200, 4800, 'Первая строка'],
          [5000, 9100, 'Second line'],
        ]),
      )!;
      expect(lyrics.timed, isTrue);
      expect(lyrics.source, 'vk');
      expect(lyrics.lines, const [
        LyricLine('Первая строка', startMs: 1200, endMs: 4800),
        LyricLine('Second line', startMs: 5000, endMs: 9100),
      ]);
    });

    test('timed lines out of order are put in time order', () {
      final lyrics = lyricsFromVk(
        timedReply([
          [5000, 6000, 'b'],
          [1000, 2000, 'a'],
        ]),
      )!;
      expect([for (final line in lyrics.lines) line.text], ['a', 'b']);
    });

    test('plain text keeps verse breaks once, not at the ends', () {
      final lyrics = lyricsFromVk(
        plainReply(['', 'one', 'two', '', '', 'three\r', '  ', '']),
      )!;
      expect(lyrics.timed, isFalse);
      expect(
        [for (final line in lyrics.lines) line.text],
        ['one', 'two', '', 'three'],
      );
    });

    test('an instrumental gap inside timed lyrics stays', () {
      final lyrics = lyricsFromVk(
        timedReply([
          [0, 900, ''],
          [1000, 2000, 'a'],
          [2100, 9000, ''],
          [9100, 9900, 'b'],
        ]),
      )!;
      expect([for (final line in lyrics.lines) line.text], ['a', '', 'b']);
    });

    test('a timed outro gap stays, so the last sung line goes out', () {
      final lyrics = lyricsFromVk(
        timedReply([
          [1000, 2000, 'a'],
          [20000, 24000, 'b'],
          [25000, 40000, ''],
        ]),
      )!;
      expect([for (final line in lyrics.lines) line.text], ['a', 'b', '']);
      expect(lyrics.lineAt(22000), 1);
      expect(lyrics.lineAt(30000), 2);
    });

    test('a reply without words is no lyrics', () {
      expect(lyricsFromVk(plainReply(['', ' '])), isNull);
      expect(lyricsFromVk({'md5': 'x'}), isNull);
      expect(lyricsFromVk(null), isNull);
      expect(lyricsFromVk(timedReply([])), isNull);
    });
  });

  group('lineAt', () {
    final lyrics = Lyrics(
      source: 'vk',
      lines: const [
        LyricLine('a', startMs: 1000),
        LyricLine('', startMs: 4000),
        LyricLine('b', startMs: 6000),
      ],
    );

    test('is -1 before the first line', () {
      expect(lyrics.lineAt(0), -1);
      expect(lyrics.lineAt(999), -1);
    });

    test('is the last line started, gaps included', () {
      expect(lyrics.lineAt(1000), 0);
      expect(lyrics.lineAt(3999), 0);
      expect(lyrics.lineAt(4000), 1);
      expect(lyrics.lineAt(6000), 2);
      expect(lyrics.lineAt(999999), 2);
    });

    test('never lands on a label row, even one at the end (H5)', () {
      const labelled = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine('[Verse 1]', startMs: 1000, label: true),
          LyricLine('a', startMs: 1000),
          LyricLine('[Chorus]', startMs: 5000, label: true),
          LyricLine('b', startMs: 6000),
          LyricLine('[Outro]', startMs: 9000, label: true),
        ],
      );
      expect(labelled.lineAt(999), -1);
      expect(labelled.lineAt(1000), 1);
      expect(labelled.lineAt(5500), 1);
      expect(labelled.lineAt(6000), 3);
      expect(labelled.lineAt(9500), 3);
    });

    test('a label row alone before the first line lights nothing', () {
      const labelled = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine('[Intro]', startMs: 0, label: true),
          LyricLine('a', startMs: 3000),
        ],
      );
      expect(labelled.lineAt(1000), -1);
      expect(labelled.lineAt(3000), 1);
    });

    test('is -1 for plain lyrics', () {
      const plain = Lyrics(source: 'vk', lines: [LyricLine('a')]);
      expect(plain.lineAt(5000), -1);
    });
  });

  test('lines survive the JSON the library keeps, Cyrillic included', () {
    const lines = [
      LyricLine('Ночь, улица, фонарь', startMs: 10, endMs: 20),
      LyricLine(''),
      LyricLine('"quoted" \\ back'),
    ];
    const lyrics = Lyrics(source: 'vk', lines: lines);
    expect(Lyrics.linesFromJson(lyrics.linesToJson()), lines);
  });

  group('word times (plan 10 J2)', () {
    test('lineWords splits at spaces only, punctuation kept', () {
      expect(lineWords('  Ночь,  улица -  фонарь '), [
        'Ночь,',
        'улица',
        '-',
        'фонарь',
      ]);
      expect(lineWords(''), isEmpty);
    });

    test('word times survive the JSON, a word without a time kept', () {
      const lines = [
        LyricLine(
          'Ночь, улица - фонарь',
          startMs: 1000,
          endMs: 4000,
          words: [
            WordTime(1000, 1400),
            WordTime(1500, 2100),
            null,
            WordTime(2600, 3900),
          ],
        ),
        LyricLine('plain line', startMs: 5000),
      ];
      const lyrics = Lyrics(source: 'lrclib', lines: lines);
      final back = Lyrics.linesFromJson(lyrics.linesToJson());
      expect(back, lines);
      expect(back[0].words![2], isNull);
      expect(back[1].words, isNull);
      expect(lyrics.hasWordTimes, isTrue);
    });

    test('old rows without "w" read as line times only', () {
      final back = Lyrics.linesFromJson('[{"t":"a b","s":10,"e":20}]');
      expect(back.single.words, isNull);
      expect(back.single.hasWordTimes, isFalse);
    });

    test('word times that count other words than the text are not used', () {
      const line = LyricLine(
        'three words here',
        startMs: 0,
        words: [WordTime(0, 100), WordTime(100, 200)],
      );
      expect(line.words, isNull);
      const allNull = LyricLine('a b', startMs: 0, words: [null, null]);
      expect(allNull.words, isNull);
    });

    test('linesToJson(words: false) leaves word times out', () {
      const timed = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine('a b', startMs: 0, words: [WordTime(0, 1), WordTime(1, 2)]),
        ],
      );
      const bare = Lyrics(
        source: 'lrclib',
        lines: [LyricLine('a b', startMs: 0)],
      );
      expect(timed.linesToJson(words: false), bare.linesToJson());
      expect(timed.linesToJson(), isNot(bare.linesToJson()));
    });

    test('wordAt: the last word started, untimed words passed over', () {
      const lyrics = Lyrics(
        source: 'heard',
        lines: [
          LyricLine(
            'one two - four',
            startMs: 1000,
            words: [
              WordTime(1000, 1200),
              WordTime(1300, 1500),
              null,
              WordTime(1800, 2000),
            ],
          ),
          LyricLine('no words', startMs: 3000),
        ],
      );
      expect(lyrics.wordAt(0, 999), -1);
      expect(lyrics.wordAt(0, 1000), 0);
      expect(lyrics.wordAt(0, 1299), 0);
      expect(lyrics.wordAt(0, 1700), 1);
      expect(lyrics.wordAt(0, 1800), 3);
      expect(lyrics.wordAt(0, 9000), 3);
      expect(lyrics.wordAt(1, 3500), -1);
      expect(lyrics.wordAt(-1, 0), -1);
      expect(lyrics.wordAt(5, 0), -1);
    });

    test('movedTo moves the end and the words with the start', () {
      const line = LyricLine(
        'a b',
        startMs: 1000,
        endMs: 2000,
        words: [WordTime(1000, 1400), WordTime(1500, 1900)],
      );
      final moved = line.movedTo(1600);
      expect(moved.startMs, 1600);
      expect(moved.endMs, 2600);
      expect(moved.words, const [WordTime(1600, 2000), WordTime(2100, 2500)]);
      final earlier = line.movedTo(0);
      expect(earlier.words, const [WordTime(0, 400), WordTime(500, 900)]);
      // A line with no start of its own cannot move its words.
      const plain = LyricLine('a b', words: [WordTime(0, 1), WordTime(1, 2)]);
      expect(plain.movedTo(500).words, isNull);
    });
  });

  group('store', () {
    late LibraryStore store;
    setUp(() => store = LibraryStore.open(':memory:'));
    tearDown(() => store.close());

    test('keeps found lyrics, a none answer, and replaces on a new answer', () {
      expect(store.lyricsOf('vk', '1_2'), isNull);
      const lyrics = Lyrics(
        source: 'vk',
        lines: [LyricLine('Строка', startMs: 500, endMs: 900)],
      );
      store.saveLyrics('vk', '1_2', lyrics, md5: 'm1', atMs: 1000);
      final stored = store.lyricsOf('vk', '1_2')!;
      expect(stored.lyrics, lyrics);
      expect(stored.md5, 'm1');
      expect(stored.fetchedAtMs, 1000);

      store.saveLyrics('vk', '1_2', null, atMs: 2000);
      final none = store.lyricsOf('vk', '1_2')!;
      expect(none.lyrics, isNull);
      expect(none.fetchedAtMs, 2000);

      // Another source for the same song is its own entry.
      expect(store.lyricsOf('other', '1_2'), isNull);
    });
  });

  group('fetchVkLyrics', () {
    test('asks with the song key and its access key', () async {
      final asked = <Map<String, String>>[];
      final answer = await fetchVkLyrics(
        (method, params) async {
          expect(method, 'audio.getLyrics');
          asked.add(params);
          return plainReply(['one']);
        },
        sourceKey: '-5_7',
        accessKey: 'k9',
      );
      expect(asked.single, {'audio_id': '-5_7_k9'});
      expect(answer, isA<VkLyricsFound>());
      expect((answer as VkLyricsFound).md5, 'def456');
      expect(answer.lyrics.lines.single.text, 'one');
    });

    test('error 104 means VK has none', () async {
      final answer = await fetchVkLyrics(
        (method, params) async =>
            throw VkException('audio.getLyrics error 104', code: 104),
        sourceKey: '1_2',
      );
      expect(answer, isA<VkLyricsNone>());
    });

    test('flood control is thrown at once, not retried', () async {
      var calls = 0;
      await expectLater(
        fetchVkLyrics((method, params) async {
          calls++;
          throw VkException('audio.getLyrics error 9', code: 9);
        }, sourceKey: '1_2'),
        throwsA(isA<VkException>().having((e) => e.slowDown, 'slowDown', true)),
      );
      expect(calls, 1);
    });

    test('a transient failure is tried once more', () async {
      var calls = 0;
      final answer = await fetchVkLyrics((method, params) async {
        calls++;
        if (calls == 1) {
          throw VkException('error 10', transient: true, code: 10);
        }
        return plainReply(['one']);
      }, sourceKey: '1_2');
      expect(calls, 2);
      expect(answer, isA<VkLyricsFound>());
    });
  });
}
