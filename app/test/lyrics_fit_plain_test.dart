// Tests for plan 10 H2b: fitting plain words (no times) to a recording.
// Which lines are sung, every line's start after a fit (blank lines,
// section headers), and the fit itself on a made-up recording read from
// the emission cache. The words are made up.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/fitted_lines.dart';
import 'package:ownsemble/lyrics/line_fit.dart' show isUnsungLine, sungText;
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart';
import 'package:ownsemble/lyrics/recording_fit.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/lyrics_page.dart' show LyricsTimingControl;

import 'line_fit_test.dart' show fakeEmission;
import 'lyrics_fit_test.dart' show StoredOnlySource;

/// Plain words as LRCLIB gives them: a header, a blank line between verses.
const words = Lyrics(
  source: 'lrclib',
  lines: [
    LyricLine('[Verse 1]'),
    LyricLine('Первая строка'),
    LyricLine('Вторая строка'),
    LyricLine(''),
    LyricLine('Third line'),
    LyricLine('Fourth line'),
  ],
);

/// A fit of [words]: the sung lines placed at 22, 25, 34 and 37 s.
const wordsFit = {
  1: FitLine(22000, endMs: 24000, sure: true),
  2: FitLine(25000, endMs: 27000, sure: true),
  4: FitLine(34000, endMs: 36000, sure: true),
  5: FitLine(37000, endMs: 39000, sure: false),
};

/// Six lines "ab", "cd", ... said at frames 10 + 20k and 11 + 20k.
const _letters = 'abcdefghijkl';
final _even = fakeEmission(140, {
  for (var k = 0; k < 6; k++) ...{
    10 + 20 * k: _letters[2 * k],
    11 + 20 * k: _letters[2 * k + 1],
  },
});

List<LyricLine> plain(List<String> texts) => [
  for (final text in texts) LyricLine(text),
];

void main() {
  group('unsung lines', () {
    test('section headers and repeat marks are not sung', () {
      for (final text in [
        '[Chorus]',
        '[Куплет 2: Артист]',
        'Chorus:',
        'Verse 2',
        'Pre-chorus',
        'Припев:',
        'Куплет 1',
        '(Instrumental)',
        'x2',
        '(x2)',
        'х2',
        '2x',
      ]) {
        expect(isUnsungLine(text), isTrue, reason: text);
      }
    });

    test(
      'words, backing vocals and lines that only start like a header are sung',
      () {
        for (final text in [
          '(oh oh oh)',
          'Chorus of the night',
          'Припев мой',
          'Hello world',
          '',
          "[Oh] I won't go [oh]",
        ]) {
          expect(isUnsungLine(text), isFalse, reason: text);
        }
      },
    );

    test('a trailing repeat mark is dropped before aligning', () {
      expect(sungText('Hello world x2'), 'Hello world');
      expect(sungText('Привет (х3)'), 'Привет');
      expect(sungText('Max2'), 'Max2');
      expect(sungText('Hello (x2)'), 'Hello');
      // Unbracketed, only a lowercase mark: "X2" may be sung (Codex review).
      expect(sungText('I bought an X2'), 'I bought an X2');
    });

    test('words the fit cannot mostly read, or too few different lines, '
        'cannot be fitted', () {
      List<LyricLine> of(List<String> texts) => plain(texts);
      expect(canFitLines(of(['ab cd', 'ef gh', 'ij kl'])), isTrue);
      // Three readable lines and twenty the aligner cannot read.
      expect(
        canFitLines(
          of(['ab cd', 'ef gh', 'ij kl', for (var i = 0; i < 20; i++) '第一行歌词']),
        ),
        isFalse,
      );
      expect(canFitLines(of(['ab', 'cd', 'ab', 'cd', 'ab', 'cd'])), isFalse);
    });
  });

  group('plainLineStarts', () {
    test('headers take the next sung start, blank lines the end before', () {
      final lines = plain(['[Intro]', 'ab', 'cd', '', 'Chorus:', 'ef', 'gh']);
      final fit = {
        1: const FitLine(1000, endMs: 1500, sure: true),
        2: const FitLine(2000, endMs: 2600, sure: true),
        5: const FitLine(5000, endMs: 5400, sure: false),
        6: const FitLine(6000, endMs: 6500, sure: true),
      };
      expect(plainLineStarts(lines, fit, lengthMs: 9000), [
        1000,
        1000,
        2000,
        2600,
        5000,
        5000,
        6000,
      ]);
    });

    test('a header just before a blank line keeps the pause', () {
      final lines = plain(['ab', 'Chorus:', '', 'cd']);
      final fit = {
        0: const FitLine(1000, endMs: 2000, sure: true),
        3: const FitLine(8000, endMs: 9000, sure: true),
      };
      expect(plainLineStarts(lines, fit, lengthMs: 9000), [
        1000,
        2000,
        2000,
        8000,
      ]);
    });

    test(
      'a blank line first starts at 0; starts never go back or past the end',
      () {
        final lines = plain(['', 'ab', 'cd', '[Outro]']);
        final fit = {
          1: const FitLine(900, endMs: 1200, sure: true),
          2: const FitLine(800, endMs: 9500, sure: true),
        };
        expect(plainLineStarts(lines, fit, lengthMs: 9000), [
          0,
          900,
          900,
          9000,
        ]);
      },
    );
  });

  group('label rows (H5)', () {
    test('fitted plain words mark headers and repeat marks as labels', () {
      final lines = plain([
        '[Verse 1]',
        'Первая строка',
        'x2',
        '',
        'Припев:',
        'Chorus of the night',
      ]);
      final fitted = withStarts(Lyrics(source: 'lrclib', lines: lines), [
        1000,
        1000,
        4000,
        4000,
        6000,
        6000,
      ], labelUnsung: true);
      expect(
        [for (final line in fitted.lines) line.label],
        [true, false, true, false, true, false],
      );
      expect(fitted.lines[0].text, '[Verse 1]');
    });

    test('lyrics timed by their source keep every row a line', () {
      const timed = Lyrics(
        source: 'lrclib',
        lines: [
          LyricLine('Chorus:', startMs: 1000),
          LyricLine('a', startMs: 2000),
        ],
      );
      final fitted = withStarts(timed, [1500, 2500]);
      expect([for (final line in fitted.lines) line.label], [false, false]);
    });
  });

  test('a fit of plain words is not used for the same words timed later', () {
    final fit = StoredFit(
      lyricsHash: lyricsHashOf(words),
      audioBytes: 10,
      starts: plainLineStarts(words.lines, wordsFit),
      sureShare: 0.75,
      fittedAtMs: 1,
    );
    expect(fit.isFor(words, audioBytes: 10), isTrue);
    final timedLater = Lyrics(
      source: 'lrclib',
      lines: [
        for (var i = 0; i < words.lines.length; i++)
          LyricLine(words.lines[i].text, startMs: 1000 * i),
      ],
    );
    expect(fit.isFor(timedLater, audioBytes: 10), isFalse);
  });

  group('fitNow on plain words', () {
    late Directory dir;
    late String audio;
    late String cache;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('plain-fit');
      audio = '${dir.path}/song.mp3';
      File(audio).writeAsBytesSync(List.filled(777, 0));
      cache = '${dir.path}/song.emission';
      writeEmissionCache(cache, 777, (emission: _even, seconds: 140 * 0.02));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    RecordingFit fitOf(List<String> texts) => fitNow(
      audio,
      [for (final t in texts) (startMs: null, endMs: null, text: t)],
      const FitTools(
        onnxRuntimePath: 'none.dll',
        modelPath: 'none.onnx',
        mpvPath: 'none.dll',
        tempDir: '.',
      ),
      emissionCachePath: cache,
    );

    test('the words get starts from the recording and fit', () {
      final result = fitOf(['[Verse]', 'ab', 'cd', 'ef', '', 'gh', 'ij', 'kl']);
      expect(result.plain, isTrue);
      expect(result.lines.keys, [1, 2, 3, 5, 6, 7]);
      expect(result.lines[1]!.startMs, 200);
      expect(result.lines[1]!.endMs, 240);
      expect(result.lines[7]!.startMs, (10 + 20 * 5) * 20);
      expect(result.shuffleGain, greaterThan(0.03));
      expect(result.fits, isTrue);
    });

    test('words of another song do not fit', () {
      final result = fitOf(['mn', 'op', 'rs', 'tu', 'vw', 'yz']);
      expect(result.fits, isFalse);
      expect(result.undecided, isFalse);
    });

    test('lines that read the same in any order cannot be checked, so they do not fit', () {
      // Two different lines over and over are refused before any fit
      // (canFitLines); these three differ, yet any order reads the same.
      final result = fitOf(['ha', 'haha', 'hahaha']);
      expect(result.shuffleGain, isNull);
      expect(result.undecided, isTrue);
      expect(result.fits, isFalse);
    });
  });

  group('the Lyrics place with plain words', () {
    late LibraryStore store;
    late LibraryController library;
    late Directory dir;

    setUp(() {
      store = LibraryStore.open(':memory:');
      dir = Directory.systemTemp.createTempSync('plain-ui');
      final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      store.upsertAll(vk, [
        NewTrack(
          sourceKey: '1_1',
          artist: 'Артист',
          title: 'Песня',
          durationSec: 200,
          addedAt: 1,
        ),
      ]);
      library = LibraryController(store.loadAll());
    });
    tearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });

    Future<LyricsController> open(
      WidgetTester tester,
      Lyrics shown,
      RecordingFit Function() result, {
      String meta = '{"exact":true}',
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      store.saveLyrics('lrclib', '1_1', shown, meta: meta);
      final lyrics = LyricsController(
        load: store.lyricsOf,
        save: store.saveLyrics,
        loadOffset: store.lyricsOffsetOf,
        saveOffset: store.saveLyricsOffset,
        loadFit: store.lyricsFitOf,
        saveFit: store.saveLyricsFit,
        routeOf: lyricsRouteBySource((sourceId) => null),
        sources: [StoredOnlySource('lrclib')],
        now: () => 1000,
      );
      final model = File('${dir.path}/m.onnx')..writeAsBytesSync([1, 2, 3]);
      final song = File('${dir.path}/song.mp3')..writeAsBytesSync([1, 2]);
      final fitter = LyricsFitter(
        lyrics: lyrics,
        modelFile: model,
        model: ModelFile(
          url: Uri.parse('http://localhost/m'),
          bytes: 3,
          sha256: '',
          fileName: 'm.onnx',
        ),
        downloadModelTo: (onProgress, stop) async {},
        audioOf: (track, onProgress) async => song.path,
        fit: (key, path, lines, onProgress) async => result(),
      );
      final player = PlayerService(muted: true, dataDir: '.')
        ..restore(library.all.single, const Duration(seconds: 23));
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: PlaybackController(player: player),
            lyrics: lyrics,
            lyricsFitter: fitter,
          ),
        ),
      );
      await tester.pump();
      library.toggleLyrics();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return lyrics;
    }

    Future<void> fit(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('lyrics-fit')));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('plain words get the button; a fit times them; undo shows '
        'words again', (tester) async {
      final lyrics = await open(
        tester,
        words,
        () => const RecordingFit(
          lines: wordsFit,
          sureShare: 0.75,
          audioSeconds: 200,
          elapsedMs: 10,
          plain: true,
          shuffleGain: 0.12,
        ),
      );
      expect(find.byKey(const ValueKey('lyrics-fit')), findsOneWidget);
      expect(find.byType(LyricsTimingControl), findsNothing);
      await fit(tester);
      expect(find.byKey(const ValueKey('lyrics-fitted')), findsOneWidget);
      expect(
        find.textContaining(
          'Words from LRCLIB, timed by fitting to this recording',
        ),
        findsOneWidget,
      );
      final shown = lyrics.timedOf(words);
      expect(shown.timed, isTrue);
      expect(
        [for (final line in shown.lines) line.startMs],
        [22000, 22000, 25000, 27000, 34000, 37000],
      );
      // 23 s: the first verse's first line is lit.
      expect(shown.lineAt(23000), 1);
      // The header is a label (H5): shown, never lit, no jump.
      expect(shown.lines[0].label, isTrue);
      expect(find.byKey(const ValueKey('lyrics-label-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics-line-0')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-line-1')), findsOneWidget);
      expect(find.text('[Verse 1]'), findsOneWidget);
      expect(find.byType(LyricsTimingControl), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lyrics-fitted')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Show words only'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-unfit')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('lyrics-fit')), findsOneWidget);
      expect(lyrics.timedOf(words).timed, isFalse);
      expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('words that do not match keep their words and offer the fit '
        'again', (tester) async {
      await open(
        tester,
        words,
        () => const RecordingFit(
          lines: wordsFit,
          sureShare: 0.75,
          audioSeconds: 200,
          elapsedMs: 10,
          plain: true,
          shuffleGain: 0.01,
        ),
      );
      await fit(tester);
      expect(
        find.text('These words could not be matched to this recording.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lyrics-fit-no-match')), findsOneWidget);
      expect(
        find.textContaining('they could not be matched to this recording'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('lyrics-fit-no-match')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('lyrics-fit-again')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics-fit-choose')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('plain words of another version say when they are timed', (
      tester,
    ) async {
      await open(
        tester,
        words,
        () => const RecordingFit(
          lines: wordsFit,
          sureShare: 0.75,
          audioSeconds: 200,
          elapsedMs: 10,
          plain: true,
          shuffleGain: 0.12,
        ),
        meta: '{"exact":true,"seconds":230,"other":true}',
      );
      expect(
        find.textContaining('another version (30 s longer)'),
        findsOneWidget,
      );
      await fit(tester);
      final credit = tester
          .widget<Text>(find.byKey(const ValueKey('lyrics-credit')))
          .data!;
      expect(credit, contains('another version (30 s longer)'));
      expect(credit, contains('timed by fitting to this recording'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('words the fit cannot read get no button', (tester) async {
      await open(
        tester,
        const Lyrics(
          source: 'lrclib',
          lines: [LyricLine('第一行歌词'), LyricLine('第二行歌词'), LyricLine('第三行歌词')],
        ),
        () => throw StateError('no fit expected'),
      );
      expect(find.byKey(const ValueKey('lyrics-fit')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
