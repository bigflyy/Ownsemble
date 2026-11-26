// Unit tests for plan 10 J4 and J5: the fit's word times (the aligner's
// word spans mapped onto the words shown, kept with the fit in the library,
// put on the shown lines in place of a source's own word times) and word
// times through the user's edits.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/fitted_lines.dart';
import 'package:ownsemble/lyrics/line_fit.dart';
import 'package:ownsemble/lyrics/lrc.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_edit.dart';
import 'package:ownsemble/lyrics/lyrics_editor.dart';
import 'package:ownsemble/lyrics/lyrics_match.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';

void main() {
  group('wordTimesOnText', () {
    test('one aligner word per word shown, punctuation kept on screen', () {
      expect(
        wordTimesOnText('Hello, world!', 'Hello, world!', const [
          (1.0, 1.4),
          (1.5, 2.25),
        ]),
        const [WordTime(1000, 1400), WordTime(1500, 2250)],
      );
    });

    test('Cyrillic words map through their romanized letters', () {
      expect(
        wordTimesOnText('Ночь, улица', 'Ночь, улица', const [
          (0.5, 0.9),
          (1.0, 1.6),
        ]),
        const [WordTime(500, 900), WordTime(1000, 1600)],
      );
    });

    test('a word the aligner splits runs from its first to its last part', () {
      // romanize("rock-n-roll") is three aligner words.
      expect(
        wordTimesOnText('rock-n-roll baby', 'rock-n-roll baby', const [
          (1.0, 1.2),
          (1.2, 1.3),
          (1.3, 1.7),
          (1.8, 2.0),
        ]),
        const [WordTime(1000, 1700), WordTime(1800, 2000)],
      );
    });

    test('digits and dashes get no time; the words around them do', () {
      expect(
        wordTimesOnText('go 99 - go', 'go 99 - go', const [
          (1.0, 1.2),
          (2.0, 2.2),
        ]),
        const [WordTime(1000, 1200), null, null, WordTime(2000, 2200)],
      );
    });

    test('a repeat mark the fit left out gets no time', () {
      expect(
        wordTimesOnText('Hello again x2', 'Hello again', const [
          (1.0, 1.2),
          (1.3, 1.6),
        ]),
        const [WordTime(1000, 1200), WordTime(1300, 1600), null],
      );
    });

    test('words that do not line up give none', () {
      expect(wordTimesOnText('one two', 'one two', const [(1.0, 1.2)]), isNull);
      expect(
        wordTimesOnText('one two', 'other words', const [
          (1.0, 1.2),
          (1.3, 1.5),
        ]),
        isNull,
      );
      expect(wordTimesOnText('99', '99', const []), isNull);
    });
  });

  group('kept fit words', () {
    const lyrics = Lyrics(
      source: 'lrclib',
      lines: [
        LyricLine('Ночь улица', startMs: 1000),
        LyricLine('', startMs: 3000),
        LyricLine('фонарь аптека', startMs: 5000),
      ],
    );
    final fit = StoredFit(
      lyricsHash: lyricsHashOf(lyrics),
      audioBytes: 4000000,
      starts: const [1500, 3500, 5600],
      sureShare: 0.66,
      fittedAtMs: 9,
      words: const [
        [WordTime(1500, 1900), WordTime(2000, 2600)],
        null,
        null,
      ],
    );

    test('words round trip through the library; old fits have none', () {
      final store = LibraryStore.open(':memory:');
      addTearDown(store.close);
      store.saveLyricsFit('1_1', 'lrclib', fit);
      final kept = store.lyricsFitOf('1_1', 'lrclib')!;
      expect(kept.hasWords, isTrue);
      expect(sameFitWords(kept.words, fit.words), isTrue);
      store.saveLyricsFit(
        '1_1',
        'vk',
        const StoredFit(
          lyricsHash: 'x',
          audioBytes: 1,
          starts: [1, 2, 3],
          sureShare: 1,
          fittedAtMs: 1,
        ),
      );
      final old = store.lyricsFitOf('1_1', 'vk')!;
      expect(old.words, isNull);
      expect(old.hasWords, isFalse);
    });

    test('a fit with only null lines has no words', () {
      const empty = StoredFit(
        lyricsHash: 'x',
        audioBytes: 1,
        starts: [1],
        sureShare: 1,
        fittedAtMs: 1,
        words: [null],
      );
      expect(empty.hasWords, isFalse);
      expect(empty.wordsToJson(), isNull);
    });

    test('the fit\'s words replace the line\'s own; others move along', () {
      const own = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine(
            'Ночь улица',
            startMs: 1000,
            words: [WordTime(1000, 1300), WordTime(1400, 1800)],
          ),
          LyricLine('', startMs: 3000),
          LyricLine(
            'фонарь аптека',
            startMs: 5000,
            words: [WordTime(5000, 5300), WordTime(5400, 5900)],
          ),
        ],
      );
      final shown = withStarts(own, fit.starts!, words: fit.words);
      expect(shown.lines[0].words, fit.words![0]);
      // The third line has no fit words: its own move with its start.
      expect(shown.lines[2].words, const [
        WordTime(5600, 5900),
        WordTime(6000, 6500),
      ]);
      expect(shown.lines[2].startMs, 5600);
    });

    test('the fit\'s hash does not change when lyrics gain word times', () {
      const stamped = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine(
            'Ночь улица',
            startMs: 1000,
            words: [WordTime(1000, 1300), WordTime(1400, 1800)],
          ),
          LyricLine('', startMs: 3000),
          LyricLine('фонарь аптека', startMs: 5000),
        ],
      );
      expect(fit.isFor(stamped), isTrue);
    });
  });

  group('edits keep word times (J5)', () {
    const start = [
      LyricLine(
        'Ночь улица',
        startMs: 1000,
        words: [WordTime(1000, 1400), WordTime(1500, 2000)],
      ),
      LyricLine(
        'фонарь аптека',
        startMs: 3000,
        words: [WordTime(3000, 3400), WordTime(3500, 4000)],
      ),
      LyricLine('', startMs: 5000),
    ];

    test('untouched lines keep them; a changed text drops them', () {
      final editor = LyricsEditor(start)..setText(1, 'фонарь, аптека');
      expect(editor.result[0].words, start[0].words);
      expect(editor.result[1].words, isNull);
    });

    test('a moved start moves the words; a cleared one drops them', () {
      final editor = LyricsEditor(start)..nudge(0, 500);
      expect(editor.result[0].startMs, 1500);
      expect(editor.result[0].words, const [
        WordTime(1500, 1900),
        WordTime(2000, 2500),
      ]);
      editor.setStart(0, null);
      expect(editor.result[0].words, isNull);
    });

    test('pasted text keeps the words of lines left as they were', () {
      final editor = LyricsEditor(start)
        ..applyText('Ночь улица\nфонарь аптека!\n');
      expect(editor.result[0].words, start[0].words);
      expect(editor.result[1].words, isNull, reason: 'corrected line');
    });

    test('stored and shown edits keep words of lines lit on their own', () {
      final stored = storableEditLines(start);
      expect(stored[0].words, start[0].words);
      final shown = editForShow([
        ...stored,
        const LyricLine(
          'late line',
          startMs: 500,
          words: [WordTime(500, 600), WordTime(600, 700)],
        ),
      ]);
      expect(shown.lines[0].words, start[0].words);
      expect(shown.lines[3].passed, isTrue);
      expect(shown.lines[3].words, isNull, reason: 'lit with the line above');
    });
  });

  group('Codex review fixes', () {
    test('an offset past the song start moves words by all of it', () {
      // The line clamps at 0; its words still move the full 1000 ms.
      final lyrics = lyricsFromLrc(
        'lrclib',
        '[offset:+1000]\n[00:00.50]<00:01.20>a <00:01.40>b<00:01.60>\n'
            '[00:05.00]c\n[00:06.00]d',
      )!;
      expect(lyrics.lines[0].startMs, 0);
      expect(lyrics.lines[0].words, const [
        WordTime(200, 400),
        WordTime(400, 600),
      ]);
      const line = LyricLine(
        'a b',
        startMs: 500,
        words: [WordTime(1200, 1400), WordTime(1400, 1600)],
      );
      final shifted = line.shiftedBy(-1000);
      expect(shifted.startMs, 0);
      expect(shifted.words, const [WordTime(200, 400), WordTime(400, 600)]);
    });

    test('another version keeps only the fit\'s own word times', () {
      const own = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine(
            'a b',
            startMs: 1000,
            words: [WordTime(1000, 1300), WordTime(1400, 1800)],
          ),
          LyricLine(
            'c d',
            startMs: 3000,
            words: [WordTime(3000, 3300), WordTime(3400, 3800)],
          ),
        ],
      );
      final shown = withStarts(
        own,
        const [1500, 3600],
        words: const [
          [WordTime(1500, 1700), WordTime(1800, 2100)],
          null,
        ],
        ownWords: false,
      );
      expect(shown.lines[0].words, const [
        WordTime(1500, 1700),
        WordTime(1800, 2100),
      ]);
      expect(shown.lines[1].words, isNull);
      expect(shown.lines[1].startMs, 3600);
    });

    group('found outside lyrics kept before word times', () {
      late LibraryStore store;
      late Track track;
      setUp(() {
        store = LibraryStore.open(':memory:');
        final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'A');
        store.upsertAll(vk, [
          const NewTrack(
            sourceKey: '1_1',
            artist: 'Артист',
            title: 'Песня',
            durationSec: 200,
            addedAt: 1,
          ),
        ]);
        track = store.loadAll().single;
        // As schema 26 leaves them: found, fetch time 0.
        store.saveLyrics('lrclib', '1_1', bare, atMs: lyricsWordsDueAtMs);
      });
      tearDown(() => store.close());

      LyricsController controllerWith(OutsideLyricsSource source) =>
          LyricsController(
            load: store.lyricsOf,
            save: store.saveLyrics,
            routeOf: lyricsRouteBySource((_) => null),
            sources: [source],
            now: () => 1000000,
          );

      Future<void> settled(LyricsController lyrics) async {
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final state = lyrics.state;
          if (state is LyricsShown && !state.refreshing) return;
        }
      }

      test('are asked again once and the word-timed answer shows', () async {
        final source = _AnswerSource(stamped);
        final lyrics = controllerWith(source)..show(track);
        await settled(lyrics);
        expect(source.asked, 1);
        final shown = (lyrics.state as LyricsShown).lyrics;
        expect(shown.hasWordTimes, isTrue);
        expect(
          store.lyricsOf('lrclib', '1_1')!.fetchedAtMs,
          isNot(lyricsWordsDueAtMs),
        );
        // Asked once: the next show takes the kept answer.
        controllerWith(source).show(track);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(source.asked, 1);
      });

      test('a "none" now keeps the lyrics found before', () async {
        final source = _AnswerSource(null);
        final lyrics = controllerWith(source)..show(track);
        await settled(lyrics);
        expect(source.asked, 1);
        expect((lyrics.state as LyricsShown).lyrics, bare);
        expect(store.lyricsOf('lrclib', '1_1')!.lyrics, bare);
        expect(
          store.lyricsOf('lrclib', '1_1')!.fetchedAtMs,
          isNot(lyricsWordsDueAtMs),
        );
      });
    });
  });
}

const bare = Lyrics(
  source: 'lrclib',
  lines: [
    LyricLine('one two', startMs: 1000),
    LyricLine('three four', startMs: 3000),
    LyricLine('five six', startMs: 5000),
  ],
);

const stamped = Lyrics(
  source: 'lrclib',
  lines: [
    LyricLine(
      'one two',
      startMs: 1000,
      words: [WordTime(1000, 1400), WordTime(1500, 2000)],
    ),
    LyricLine('three four', startMs: 3000),
    LyricLine('five six', startMs: 5000),
  ],
);

/// An outside source that answers [lyrics] (or none) for any song.
class _AnswerSource implements OutsideLyricsSource {
  _AnswerSource(this.lyrics);

  final Lyrics? lyrics;
  int asked = 0;

  @override
  String get id => 'lrclib';

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    asked++;
    final answer = lyrics;
    if (answer == null) return null;
    return LyricsCandidate(
      lyrics: answer,
      id: '1',
      artist: song.artist,
      title: song.title,
      seconds: song.seconds,
      names: NameMatch.exact,
      lengthDiff: 0,
    );
  }
}
