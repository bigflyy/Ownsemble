// Tests for plan 10 G2: "Fit to this recording". Fitted starts for every
// line, kept per upload and source and only for the lyrics and the file
// they were made for, a fit's own hand offset beside the source's, the
// fitter's steps and outcomes, the model's download (resume, hash, stop,
// space), the emission cache, and the heading's button with its question.
// The words are made up.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/ctc_align.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/fitted_lines.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/lyrics/onnx_runtime.dart' show OnnxError;
import 'package:ownsemble/lyrics/recording_fit.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';

class StoredOnlySource implements OutsideLyricsSource {
  StoredOnlySource(this.id);

  @override
  final String id;

  @override
  Future<LyricsCandidate?> find(SongNames song) async => null;
}

const lrclib = Lyrics(
  source: 'lrclib',
  lines: [
    LyricLine('Первая строка', startMs: 10000, endMs: 12000),
    LyricLine('', startMs: 12000),
    LyricLine('Вторая строка', startMs: 20000, endMs: 23000),
    LyricLine('Third line', startMs: 30000, endMs: 33000),
  ],
);

/// A fit that moved the sung lines 12 s, 3 s and 4 s later.
const movedLater = {
  0: FitLine(22000, sure: true),
  2: FitLine(23000, sure: true),
  3: FitLine(34000, sure: false),
};

void main() {
  group('fittedLineStarts', () {
    test('a gap stays between the fitted lines around it (Codex review: '
        'it was clamped onto the next line and never lit)', () {
      final starts = fittedLineStarts(lrclib.lines, movedLater);
      expect(starts, [22000, 22200, 23000, 34000]);
    });

    test('lines before the first and after the last fitted line move as '
        'far as it; starts never go back and stay in the recording', () {
      const lines = [
        LyricLine('a', startMs: 1000),
        LyricLine('b', startMs: 5000),
        LyricLine('c', startMs: 9000),
        LyricLine('d', startMs: 12000),
      ];
      final starts = fittedLineStarts(lines, {
        1: const FitLine(3000, sure: true),
        2: const FitLine(2500, sure: false),
      }, lengthMs: 4000);
      // a: 1000 - 2000 -> 0; c fitted earlier than b -> kept after b;
      // d: 12000 - 6500 = 5500 -> the recording's end.
      expect(starts, [0, 3000, 3000, 4000]);
    });

    test('nothing fitted keeps the source times', () {
      expect(fittedLineStarts(lrclib.lines, const {}), [
        10000,
        12000,
        20000,
        30000,
      ]);
    });

    test('ends move with their starts', () {
      final fitted = withStarts(
        lrclib,
        fittedLineStarts(lrclib.lines, movedLater),
      );
      expect(fitted.lines[0].endMs, 24000);
      expect(fitted.lines[1].endMs, isNull);
      expect(fitted.lines.map((line) => line.text), [
        for (final line in lrclib.lines) line.text,
      ]);
    });
  });

  group('store', () {
    test('a fit is kept per upload and source, and forgotten', () {
      final store = LibraryStore.open(':memory:');
      addTearDown(store.close);
      expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
      store
        ..saveLyricsFit(
          '1_1',
          'lrclib',
          StoredFit(
            lyricsHash: lyricsHashOf(lrclib),
            audioBytes: 4000000,
            starts: const [1, 2, 3, 4],
            sureShare: 0.75,
            fittedAtMs: 99,
          ),
        )
        ..saveLyricsFit(
          '1_1',
          'netease',
          const StoredFit(
            lyricsHash: 'x',
            audioBytes: 4000000,
            starts: null,
            sureShare: 0.2,
            fittedAtMs: 100,
          ),
        );
      final kept = store.lyricsFitOf('1_1', 'lrclib')!;
      expect(kept.starts, [1, 2, 3, 4]);
      expect(kept.audioBytes, 4000000);
      expect(kept.sureShare, 0.75);
      expect(kept.isFor(lrclib), isTrue);
      expect(kept.isFor(lrclib, audioBytes: 4000001), isFalse);
      expect(store.lyricsFitOf('1_1', 'netease')!.fits, isFalse);
      store.saveLyricsFit('1_1', 'lrclib', null);
      expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
      expect(store.lyricsFitOf('1_1', 'netease'), isNotNull);
    });
  });

  group('controller', () {
    late LibraryStore store;
    late Track playing;
    int? audioBytes = 4000000;
    // The upload the song's lyrics come from: another version changes it.
    var routeKey = '1_1';

    setUp(() {
      audioBytes = 4000000;
      routeKey = '1_1';
      store = LibraryStore.open(':memory:');
      final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      store.upsertAll(vk, [
        NewTrack(
          sourceKey: '1_1',
          artist: 'Артист',
          title: 'Песня (live)',
          durationSec: 200,
          addedAt: 1,
        ),
      ]);
      playing = LibraryController(store.loadAll()).all.single;
      store.saveLyrics('lrclib', '1_1', lrclib, meta: '{"exact":true}');
    });
    tearDown(() => store.close());

    LyricsController controllerOf() => LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadOffset: store.lyricsOffsetOf,
      saveOffset: store.saveLyricsOffset,
      loadFit: store.lyricsFitOf,
      saveFit: store.saveLyricsFit,
      audioBytesOf: (_) => audioBytes,
      routeOf: (track) => (key: routeKey, accessKey: null, call: null),
      sources: [StoredOnlySource('lrclib')],
      now: () => 1000,
    );

    StoredFit fitOf(Lyrics lyrics) => StoredFit(
      lyricsHash: lyricsHashOf(lyrics),
      audioBytes: 4000000,
      starts: fittedLineStarts(lyrics.lines, movedLater),
      sureShare: 0.8,
      fittedAtMs: 1,
    );

    test('fitted lines show only for the lyrics and the file they were '
        'made for', () {
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      expect(lyrics.timedOf(shown), same(shown));
      lyrics.keepFit('1_1', 'lrclib', fitOf(shown));
      expect(lyrics.isFitted(shown), isTrue);
      expect(lyrics.timedOf(shown).lines.first.startMs, 22000);
      expect(
        lyrics.timedOf(shown),
        same(lyrics.timedOf(shown)),
        reason: 'not made again on every build',
      );
      audioBytes = 3999999; // VK swapped the upload's file
      expect(lyrics.isFitted(shown), isFalse);
      expect(lyrics.timedOf(shown).lines.first.startMs, 10000);
      audioBytes = null; // not stored any more: the fit still shows
      expect(lyrics.isFitted(shown), isTrue);
      // The source's lyrics changed: the fit is for the old ones.
      final changed = Lyrics(
        source: 'lrclib',
        lines: [...shown.lines, const LyricLine('Новая', startMs: 40000)],
      );
      expect(lyrics.isFitted(changed), isFalse);
      expect(lyrics.timedOf(changed), same(changed));
    });

    test("a fit has its own hand offset; the source's own comes back when "
        'the fit is undone (Codex review)', () {
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      lyrics.setOffset('lrclib', 1500);
      lyrics.keepFit('1_1', 'lrclib', fitOf(shown));
      expect(lyrics.offsetOf('lrclib'), 0, reason: 'a new fit starts at 0');
      lyrics.shiftShown(500);
      expect(lyrics.offsetOf('lrclib'), 500);
      expect(store.lyricsOffsetOf('1_1', 'lrclib@fit'), 500);
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 1500);
      lyrics.forgetFit('lrclib');
      expect(lyrics.isFitted(shown), isFalse);
      expect(lyrics.offsetOf('lrclib'), 1500);
      expect(store.lyricsOffsetOf('1_1', 'lrclib@fit'), 0);
      expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
    });

    test("the chooser's preview of another source uses the fit's own offset "
        'only while its fit is for its lyrics as stored (Codex review)', () {
      store.saveLyrics('netease', '1_1', lrclib, meta: '{}');
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      final netease = store.lyricsOf('netease', '1_1')!.lyrics!;
      lyrics.keepFit('1_1', 'netease', fitOf(netease));
      store
        ..saveLyricsOffset('1_1', 'netease@fit', 1000)
        ..saveLyricsOffset('1_1', 'netease', 2000);
      expect(shown.source, 'lrclib');
      expect(lyrics.offsetOf('netease'), 1000);
      // NetEase's lyrics changed since: the fit is not used, nor its offset.
      store.saveLyrics(
        'netease',
        '1_1',
        Lyrics(
          source: 'netease',
          lines: [...lrclib.lines, const LyricLine('x', startMs: 50000)],
        ),
        meta: '{}',
      );
      expect(lyrics.offsetOf('netease'), 2000);
    });

    test('undo from a menu opened for one upload forgets that one', () {
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      lyrics.keepFit('1_1', 'lrclib', fitOf(shown));
      lyrics.keepFit('9_9', 'lrclib', fitOf(shown));
      lyrics.forgetFit('lrclib', key: '9_9');
      expect(store.lyricsFitOf('9_9', 'lrclib'), isNull);
      expect(store.lyricsFitOf('1_1', 'lrclib'), isNotNull);
    });

    test('a fit that does not match moves nothing', () {
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      lyrics.keepFit(
        '1_1',
        'lrclib',
        StoredFit(
          lyricsHash: lyricsHashOf(shown),
          audioBytes: 4000000,
          starts: null,
          sureShare: 0.3,
          fittedAtMs: 1,
        ),
      );
      expect(lyrics.fitFor(shown)?.fits, isFalse);
      expect(lyrics.isFitted(shown), isFalse);
      expect(lyrics.timedOf(shown), same(shown));
      lyrics.setOffset('lrclib', 1000);
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 1000);
    });

    test('another version shows its words until fitted (G4c)', () {
      // The studio song is 25 s longer than this live upload.
      store.saveLyrics(
        'lrclib',
        '1_1',
        lrclib,
        meta: '{"exact":true,"seconds":225,"diff":25,"other":true}',
      );
      final lyrics = controllerOf()..show(playing);
      final shown = (lyrics.state as LyricsShown).lyrics;
      expect(shown.timed, isTrue, reason: 'stored and fitted as they came');
      expect(lyrics.otherVersionOf(shown), 25);
      final words = lyrics.timedOf(shown);
      expect(words.timed, isFalse);
      expect(words.lines.map((line) => line.text), [
        for (final line in shown.lines) line.text,
      ]);
      expect(lyrics.timedOf(shown), same(words), reason: 'made once');
      lyrics.shiftShown(500);
      expect(lyrics.offsetOf('lrclib'), 0, reason: 'no timing to move');

      lyrics.keepFit('1_1', 'lrclib', fitOf(shown));
      expect(lyrics.timedOf(shown).timed, isTrue);
      expect(lyrics.timedOf(shown).lines.first.startMs, 22000);
      lyrics.shiftShown(500);
      expect(lyrics.offsetOf('lrclib'), 500, reason: 'the fit can be moved');

      lyrics.keepFit(
        '1_1',
        'lrclib',
        StoredFit(
          lyricsHash: lyricsHashOf(shown),
          audioBytes: 4000000,
          starts: null,
          sureShare: 0.3,
          fittedAtMs: 1,
        ),
      );
      expect(lyrics.timedOf(shown).timed, isFalse, reason: 'does not fit');
      lyrics.forgetFit('lrclib');
      expect(lyrics.timedOf(shown).timed, isFalse, reason: 'undone: words');

      // A refresh stores the song's own lyrics while the old ones still
      // show, and a chooser preview looks at others: the lyrics shown keep
      // what they are (Codex review).
      const refreshed = Lyrics(
        source: 'lrclib',
        lines: [LyricLine('Новая', startMs: 1000)],
      );
      store.saveLyrics('lrclib', '1_1', refreshed, meta: '{"exact":true}');
      expect(lyrics.otherVersionOf(refreshed), isNull);
      expect(lyrics.otherVersionOf(shown), 25);
      expect(lyrics.timedOf(shown).timed, isFalse);

      // Lyrics of the song's own length, and VK's, are not another version.
      store.saveLyrics('lrclib', '1_1', lrclib, meta: '{"exact":true}');
      expect(lyrics.otherVersionOf(lrclib), isNull);
      expect(lyrics.timedOf(lrclib), same(lrclib));
      expect(
        lyrics.otherVersionOf(const Lyrics(source: 'vk', lines: [])),
        isNull,
      );
    });

    group('fitter', () {
      late Directory dir;
      setUp(() {
        dir = Directory.systemTemp.createTempSync('fit-test');
        File('${dir.path}/song.mp3').writeAsBytesSync(List.filled(4000000, 1));
      });
      tearDown(() => dir.deleteSync(recursive: true));

      LyricsFitter fitterOf(
        LyricsController lyrics, {
        required RecordingFit Function(List<LyricLine> lines) result,
        List<String>? steps,
        Completer<void>? audioGate,
        bool modelThere = false,
        bool stored = false,
        bool cached = false,
      }) {
        final model = File('${dir.path}/models/m.onnx');
        if (modelThere) {
          model
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3]);
        }
        return LyricsFitter(
          lyrics: lyrics,
          modelFile: model,
          model: ModelFile(
            url: Uri.parse('http://localhost/m'),
            bytes: 3,
            sha256: '',
            fileName: 'm.onnx',
          ),
          downloadModelTo: (onProgress, stop) async {
            steps?.add('download');
            onProgress(1, 3);
            model
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync([1, 2, 3]);
          },
          audioOf: (track, onProgress) async {
            steps?.add('audio');
            onProgress(0.5);
            await audioGate?.future;
            return '${dir.path}/song.mp3';
          },
          fit: (key, path, lines, onProgress) async {
            steps?.add('fit $key');
            onProgress(1, 2);
            return result(lines);
          },
          storedAudioOf: (track) => stored ? '${dir.path}/song.mp3' : null,
          hasCachedOutput: (key) => cached,
          now: () => 7,
        );
      }

      RecordingFit fitted(List<LyricLine> lines) => const RecordingFit(
        lines: movedLater,
        sureShare: 0.67,
        audioSeconds: 200,
        elapsedMs: 10,
      );

      test(
        'downloads the model once, saves the song, fits and keeps it',
        () async {
          final lyrics = controllerOf()..show(playing);
          final steps = <String>[];
          final fitter = fitterOf(lyrics, result: fitted, steps: steps);
          expect(fitter.modelReady, isFalse);
          final stages = <String>[];
          fitter.addListener(() {
            final stage = fitter.stageOf('1_1', 'lrclib');
            if (stage != null) stages.add(fitStageText(stage));
          });
          final outcome = await fitter.fitShown();
          expect(outcome, isA<FitDone>());
          expect(steps, ['download', 'audio', 'fit 1_1']);
          expect(stages, contains('saving the song, 50%'));
          expect(stages, contains('fitting to this recording, 50%'));
          final kept = store.lyricsFitOf('1_1', 'lrclib')!;
          expect(kept.starts, [22000, 22200, 23000, 34000]);
          expect(kept.audioBytes, 4000000);
          expect(kept.fittedAtMs, 7);
          expect(fitter.job, isNull);
          steps.clear();
          lyrics.forgetFit('lrclib');
          await fitter.fitShown();
          expect(steps, ['audio', 'fit 1_1'], reason: 'the model is there');
        },
      );

      test('lyrics that do not fit are kept as such, nothing moves', () async {
        final lyrics = controllerOf()..show(playing);
        final fitter = fitterOf(
          lyrics,
          modelThere: true,
          result: (lines) => const RecordingFit(
            lines: movedLater,
            sureShare: 0.33,
            audioSeconds: 200,
            elapsedMs: 10,
          ),
        );
        expect(await fitter.fitShown(), isA<FitNoMatch>());
        final kept = store.lyricsFitOf('1_1', 'lrclib')!;
        expect(kept.fits, isFalse);
        expect(kept.sureShare, 0.33);
      });

      test('one fit at a time; what the click saw is what is kept, also '
          'when another song shows meanwhile', () async {
        final lyrics = controllerOf()..show(playing);
        final gate = Completer<void>();
        final fitter = fitterOf(
          lyrics,
          modelThere: true,
          result: fitted,
          audioGate: gate,
        );
        final first = fitter.fitShown();
        await Future<void>.delayed(Duration.zero);
        expect(fitter.stageOf('1_1', 'lrclib'), isA<FitSaving>());
        expect(
          await fitter.fitShown(),
          isA<FitFailed>().having(
            (f) => f.message,
            'message',
            contains('Another'),
          ),
        );
        lyrics.show(null);
        gate.complete();
        expect(await first, isA<FitDone>());
        expect(store.lyricsFitOf('1_1', 'lrclib')!.fits, isTrue);
      });

      test('another version chosen while the song is saved: nothing is '
          'kept under the old upload (Codex review)', () async {
        final lyrics = controllerOf()..show(playing);
        final gate = Completer<void>();
        final fitter = fitterOf(
          lyrics,
          modelThere: true,
          result: fitted,
          audioGate: gate,
        );
        final outcome = fitter.fitShown();
        await Future<void>.delayed(Duration.zero);
        routeKey = '2_2';
        gate.complete();
        expect(
          await outcome,
          isA<FitFailed>().having(
            (f) => f.message,
            'message',
            contains('version'),
          ),
        );
        expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
        expect(store.lyricsFitOf('2_2', 'lrclib'), isNull);
      });

      test('an answer for another song, or a song outside the library, '
          'starts nothing', () async {
        final lyrics = controllerOf()..show(playing);
        final steps = <String>[];
        final fitter = fitterOf(lyrics, result: fitted, steps: steps);
        expect(await fitter.fitShown(forKey: '7_7'), isA<FitFailed>());
        expect(steps, isEmpty);
        final outside = Track(
          id: -5, // outside the library
          source: TrackSource.vk,
          sourceId: playing.sourceId,
          sourceKey: '5_5',
          artist: 'A',
          title: 'B',
          durationSec: 200,
          addedAt: 1,
        );
        store.saveLyrics('lrclib', '1_1', lrclib, meta: '{"exact":true}');
        lyrics.show(outside);
        await Future<void>.delayed(Duration.zero);
        if (lyrics.state is LyricsShown) {
          expect(
            await fitter.fitShown(),
            isA<FitFailed>().having(
              (f) => f.message,
              'message',
              contains('library'),
            ),
          );
        }
        expect(steps, isEmpty);
      });

      test(
        'a model that fails to load and has the wrong bytes is deleted',
        () async {
          final lyrics = controllerOf()..show(playing);
          final fitter = fitterOf(
            lyrics,
            modelThere: true,
            result: (_) => throw const OnnxError('bad model'),
          );
          final outcome = await fitter.fitShown();
          expect(
            outcome,
            isA<FitFailed>().having(
              (f) => f.message,
              'message',
              contains('damaged'),
            ),
          );
          expect(File('${dir.path}/models/m.onnx').existsSync(), isFalse);
          expect(fitter.modelReady, isFalse);
        },
      );

      test(
        'the chooser ranking scores every timed source once the model '
        "output is cached; a first check runs only when asked (G3)",
        () async {
          final other = Lyrics(
            source: 'netease',
            lines: [
              for (final line in lrclib.lines)
                LyricLine(line.text, startMs: (line.startMs ?? 0) + 100),
            ],
          );
          store.saveLyrics('netease', '1_1', other, meta: '{}');
          final lyrics = LyricsController(
            load: store.lyricsOf,
            save: store.saveLyrics,
            loadFit: store.lyricsFitOf,
            saveFit: store.saveLyricsFit,
            routeOf: (track) => (key: '1_1', accessKey: null, call: null),
            sources: [StoredOnlySource('lrclib'), StoredOnlySource('netease')],
            now: () => 1000,
          )..show(playing);
          final steps = <String>[];
          var cached = false;
          LyricsFitter fitterNow() => fitterOf(
            lyrics,
            modelThere: true,
            stored: true,
            cached: cached,
            steps: steps,
            result: (lines) => RecordingFit(
              lines: movedLater,
              // NetEase's copy fits worse.
              sureShare: lines.first.startMs == 10100 ? 0.3 : 0.9,
              audioSeconds: 200,
              elapsedMs: 1,
            ),
          );
          var fitter = fitterNow();
          expect(fitter.canRank, isTrue);
          expect(fitter.rankIsQuick, isFalse);
          await fitter.rankChoices();
          expect(steps, isEmpty, reason: 'no model run unless asked');
          await fitter.rankChoices(runModel: true);
          expect(steps, ['fit 1_1', 'fit 1_1']);
          expect(fitter.scoreOf(lrclib), 0.9);
          expect(fitter.scoreOf(other), 0.3);
          expect(fitter.canRank, isFalse, reason: 'all scored');
          expect(
            store.lyricsFitOf('1_1', 'lrclib'),
            isNull,
            reason: 'no line moved',
          );
          // A new run with the output cached ranks by itself.
          cached = true;
          steps.clear();
          fitter = fitterNow();
          expect(fitter.rankIsQuick, isTrue);
          await fitter.rankChoices();
          expect(steps, hasLength(2));
          // Changed lyrics lose their score.
          final changed = Lyrics(
            source: 'netease',
            lines: [...other.lines, const LyricLine('x', startMs: 60000)],
          );
          expect(fitter.scoreOf(changed), isNull);
        },
      );

      test('no ranking for a song that is not stored', () async {
        final lyrics = controllerOf()..show(playing);
        final steps = <String>[];
        final fitter = fitterOf(
          lyrics,
          modelThere: true,
          cached: true,
          steps: steps,
          result: fitted,
        );
        expect(fitter.canRank, isFalse);
        await fitter.rankChoices(runModel: true);
        expect(steps, isEmpty);
      });

      test('failures say why', () async {
        final lyrics = controllerOf()..show(playing);
        final fitter = fitterOf(
          lyrics,
          modelThere: true,
          result: (_) =>
              throw const FitError('these lyrics have too few lines'),
        );
        final outcome = await fitter.fitShown();
        expect(
          outcome,
          isA<FitFailed>()
              .having((f) => f.retry, 'retry', isFalse)
              .having((f) => f.message, 'message', contains('too few lines')),
        );
        expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
        expect(
          failureOf(const FitAudioError('VK refused')).message,
          'Could not save the song: VK refused',
        );
      });
    });
  });

  group('model download', () {
    late Directory dir;
    late HttpServer server;
    late List<int> body;
    final ranges = <String?>[];
    var ignoreRange = false;
    var cutAt = -1;
    var refuseRange = false;
    var stallError = false;

    setUp(() async {
      // The test binding answers every HttpClient with 400; these talk to
      // a real server on this PC.
      final faked = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = faked);
      dir = Directory.systemTemp.createTempSync('model-test');
      body = [for (var i = 0; i < 300000; i++) i * 7 % 251];
      ranges.clear();
      ignoreRange = false;
      cutAt = -1;
      refuseRange = false;
      stallError = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (stallError) {
          // A 503 whose body never ends.
          request.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..contentLength = 1000
            ..add([1, 2, 3]);
          await request.response.flush();
          return;
        }
        if (refuseRange && range != null) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        final from = !ignoreRange && range != null
            ? int.parse(range.substring(6, range.length - 1))
            : 0;
        final response = request.response;
        if (from > 0) {
          response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $from-${body.length - 1}/${body.length}',
            );
        }
        final part = body.sublist(from);
        response.contentLength = part.length;
        if (cutAt >= 0) {
          // Sends the headers and a part, then breaks the connection.
          final socket = await response.detachSocket();
          socket.add(part.sublist(0, cutAt));
          await socket.flush();
          await socket.close();
          return;
        }
        response.add(part);
        await response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    ModelFile modelOf({String? hash}) => ModelFile(
      url: Uri.parse('http://127.0.0.1:${server.port}/model.onnx'),
      bytes: body.length,
      sha256: hash ?? sha256.convert(body).toString(),
      fileName: 'model.onnx',
    );

    File target() => File('${dir.path}/models/model.onnx');

    test('downloads, checks the hash and names the file', () async {
      final seen = <int>[];
      await downloadModel(
        modelOf(),
        target(),
        onProgress: (bytes, total) => seen.add(bytes),
      );
      expect(target().readAsBytesSync(), body);
      expect(File('${target().path}.part').existsSync(), isFalse);
      expect(seen.last, body.length);
      expect(hasModel(target(), modelOf()), isTrue);
      expect(ranges, [null]);
    });

    test('a retry goes on where a broken download stopped', () async {
      cutAt = 100000;
      await expectLater(
        downloadModel(modelOf(), target()),
        throwsA(isA<ModelDownloadError>()),
      );
      final part = File('${target().path}.part');
      expect(part.lengthSync(), 100000);
      cutAt = -1;
      await downloadModel(modelOf(), target());
      expect(ranges.last, 'bytes=100000-');
      expect(target().readAsBytesSync(), body);
    });

    test('a server that ignores the range sends it all again', () async {
      File('${target().path}.part')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(5000, 0));
      ignoreRange = true;
      await downloadModel(modelOf(), target());
      expect(target().readAsBytesSync(), body);
    });

    test('a short part the server will not continue starts over next time '
        '(Codex review: every retry failed the same way)', () async {
      final part = File('${target().path}.part')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(body.sublist(0, 1000));
      refuseRange = true;
      await expectLater(
        downloadModel(modelOf(), target()),
        throwsA(isA<ModelDownloadError>()),
      );
      expect(part.existsSync(), isFalse);
      refuseRange = false;
      await downloadModel(modelOf(), target());
      expect(target().readAsBytesSync(), body);
      expect(ranges.last, isNull, reason: 'from the start');
    });

    test(
      'an error answer whose body stalls gives up after the stall time',
      () async {
        stallError = true;
        final clock = Stopwatch()..start();
        await expectLater(
          downloadModel(
            modelOf(),
            target(),
            stallTimeout: const Duration(milliseconds: 300),
          ),
          throwsA(isA<ModelDownloadError>()),
        );
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );

    test('wrong bytes are deleted and the model is not named', () async {
      await expectLater(
        downloadModel(modelOf(hash: 'ab' * 32), target()),
        throwsA(
          isA<ModelDownloadError>().having(
            (e) => e.message,
            'message',
            contains('damaged'),
          ),
        ),
      );
      expect(target().existsSync(), isFalse);
      expect(File('${target().path}.part').existsSync(), isFalse);
    });

    test('a full drive is told before anything is written', () async {
      await expectLater(
        downloadModel(modelOf(), target(), freeBytes: () => 900000000),
        throwsA(
          isA<ModelDownloadError>()
              .having((e) => e.retry, 'retry', isFalse)
              .having((e) => e.message, 'message', contains('free space')),
        ),
      );
      expect(ranges, isEmpty);
    });

    test('a stop keeps what came for the next try', () async {
      cutAt = -1;
      final stop = DownloadStop();
      final done = downloadModel(
        modelOf(),
        target(),
        stop: stop,
        onProgress: (bytes, total) {
          if (bytes > 0) stop.stop();
        },
      );
      await expectLater(done, throwsA(isA<DownloadStopped>()));
      expect(target().existsSync(), isFalse);
      await downloadModel(modelOf(), target());
      expect(target().readAsBytesSync(), body);
    });
  });

  test('a progress callback that holds things an isolate cannot take still '
      "works: the background fit gets only the fit's own data (real check "
      'fit-45a: ArgumentError from the app)', () async {
    final holder = _Unsendable();
    addTearDown(holder.port.close);
    final heard = <int>[];
    await expectLater(
      fitToRecording(
        'C:/no/such/song.mp3',
        lrclib.lines,
        const FitTools(
          onnxRuntimePath: 'none.dll',
          modelPath: 'none.onnx',
          mpvPath: 'none.dll',
          tempDir: '.',
        ),
        onProgress: (done, total) {
          heard.add(done);
          holder.port.sendPort.send(done);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('the emission cache is read back only for the same audio size', () {
    final dir = Directory.systemTemp.createTempSync('emission-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/cache/x.emission';
    final values = Float32List.fromList([for (var i = 0; i < 56; i++) i / 3]);
    writeEmissionCache(path, 1234, (
      emission: Emission(values, 28),
      seconds: 0.04,
    ));
    final back = readEmissionCache(path, 1234)!;
    expect(back.emission.columns, 28);
    expect(back.emission.frames, 2);
    expect(back.emission.values, values);
    expect(back.seconds, 0.04);
    expect(readEmissionCache(path, 1235), isNull);
    expect(readEmissionCache('${dir.path}/none', 1234), isNull);
    expect(fitCacheName('1_1'), isNot(contains('1_1')));
    expect(fitCacheName('1_1'), fitCacheName('1_1'));
  });

  group('button', () {
    late LibraryStore store;
    late LibraryController library;
    late Directory dir;

    setUp(() {
      store = LibraryStore.open(':memory:');
      dir = Directory.systemTemp.createTempSync('fit-ui');
      final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      store.upsertAll(vk, [
        NewTrack(
          sourceKey: '1_1',
          artist: 'Артист',
          title: 'Песня (live)',
          durationSec: 200,
          addedAt: 1,
        ),
      ]);
      library = LibraryController(store.loadAll());
      store.saveLyrics('lrclib', '1_1', lrclib, meta: '{"exact":true}');
    });
    tearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });

    testWidgets('the chooser lists the lyrics that fit this recording first, '
        'tagged (G3)', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // NetEase ranks below LRCLIB by names, but fits the recording better.
      final netease = Lyrics(
        source: 'netease',
        lines: [
          for (final line in lrclib.lines)
            LyricLine(line.text, startMs: (line.startMs ?? 0) + 100),
        ],
      );
      store.saveLyrics('netease', '1_1', netease, meta: '{"diff":3}');
      final lyrics = LyricsController(
        load: store.lyricsOf,
        save: store.saveLyrics,
        loadFit: store.lyricsFitOf,
        saveFit: store.saveLyricsFit,
        routeOf: lyricsRouteBySource((sourceId) => null),
        sources: [StoredOnlySource('lrclib'), StoredOnlySource('netease')],
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
        fit: (key, path, lines, onProgress) async => RecordingFit(
          lines: const {},
          sureShare: lines.first.startMs == 10100 ? 0.9 : 0.2,
          audioSeconds: 200,
          elapsedMs: 1,
        ),
        storedAudioOf: (track) => song.path,
        hasCachedOutput: (key) => true,
      );
      final player = PlayerService(muted: true, dataDir: '.')
        ..restore(library.all.single, const Duration(seconds: 21));
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
      library.openLyricsChoices();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final neteaseRow = tester.getTopLeft(
        find.byKey(const ValueKey('lyrics-choice-netease')),
      );
      final lrclibRow = tester.getTopLeft(
        find.byKey(const ValueKey('lyrics-choice-lrclib')),
      );
      expect(neteaseRow.dy, lessThan(lrclibRow.dy), reason: 'fits better');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-choice-netease')),
          matching: find.byKey(
            const ValueKey('lyrics-tag-fits this recording'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-choice-lrclib')),
          matching: find.byKey(const ValueKey('lyrics-tag-may not match')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lyrics-rank-row')), findsNothing);
      expect(
        store.lyricsFitOf('1_1', 'netease'),
        isNull,
        reason: 'no line moved',
      );
      expect(tester.takeException(), isNull);
    });

    for (final size in const [Size(1400, 900), Size(480, 700)]) {
      testWidgets('asks before the download, fits, shows it in the heading '
          'and undoes it ($size)', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
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
        final model = File('${dir.path}/m.onnx');
        final song = File('${dir.path}/song.mp3')..writeAsBytesSync([1, 2]);
        var downloads = 0;
        final fitter = LyricsFitter(
          lyrics: lyrics,
          modelFile: model,
          model: ModelFile(
            url: Uri.parse('http://localhost/m'),
            bytes: 3,
            sha256: '',
            fileName: 'm.onnx',
          ),
          downloadModelTo: (onProgress, stop) async {
            downloads++;
            model.writeAsBytesSync([1, 2, 3]);
          },
          audioOf: (track, onProgress) async => song.path,
          fit: (key, path, lines, onProgress) async => const RecordingFit(
            lines: movedLater,
            sureShare: 0.67,
            audioSeconds: 200,
            elapsedMs: 10,
          ),
        );
        final player = PlayerService(muted: true, dataDir: '.')
          ..restore(library.all.single, const Duration(seconds: 21));
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
        final button = find.byKey(const ValueKey('lyrics-fit'));
        expect(button, findsOneWidget);

        // Cancel: nothing downloads.
        await tester.runAsync(() async {
          await tester.tap(button);
          await tester.pump();
        });
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('lyrics-fit-ask')), findsOneWidget);
        expect(find.text('Download 0 MB'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('lyrics-fit-ask-cancel')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(downloads, 0);

        await tester.runAsync(() async {
          await tester.tap(button);
          await tester.pump();
        });
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('lyrics-fit-ask-download')),
          );
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 400));
        expect(downloads, 1);
        expect(find.byKey(const ValueKey('lyrics-fitted')), findsOneWidget);
        expect(
          find.textContaining('from LRCLIB, fitted to this recording'),
          findsOneWidget,
        );
        // 21 s: before the first fitted line (22 s), so nothing is lit.
        expect(lyrics.timedOf(lrclib).lineAt(21000), -1);

        // Undo: the source's timing again.
        await tester.tap(find.byKey(const ValueKey('lyrics-fitted')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('lyrics-unfit')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const ValueKey('lyrics-fit')), findsOneWidget);
        expect(find.textContaining('fitted'), findsNothing);
        expect(store.lyricsFitOf('1_1', 'lrclib'), isNull);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

// Kept apart from main() so nothing of the test's own state is captured.
class _Unsendable {
  final port = ReceivePort();
}
