// Unit tests for plan 10 I2e: the "Hear the words" pipeline on a fake
// worker (which jobs run, with what, and what is saved under which key),
// and the heard version in the lyrics controller (shown when no source has
// lyrics, never one of the sources, a version switch during a run). The
// words are made up.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/gigaam.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/hear_words.dart';
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/lyrics/onnx_runtime.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:ownsemble/lyrics/whisper.dart';
import 'package:ownsemble/lyrics/whisper_job.dart';

import 'stt_fakes.dart';

void main() {
  late Directory temp;
  late String vocals;
  late Map<String, HeardLyrics> saved;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('hear_words_test');
    vocals = '${temp.path}/song.vocals16.f32';
    saved = {};
  });
  tearDown(() => temp.deleteSync(recursive: true));

  HearWords pipeline(FakeRunner runner) => HearWords(
    runner: runner,
    paths: const HearWordsPaths(
      separatorModel: 'kim.onnx',
      silero: 'silero.onnx',
      gigaamFolder: 'gigaam',
      mpv: 'mpv.dll',
      tempDir: 'temp',
      whisperBridge: 'bridge.dll',
      whisperLibraries: 'whisper.cpp',
      whisperModel: 'turbo.bin',
      threads: 8,
      bundles: 'hear-words-1 whisper-turbo-1',
    ),
    save: (ref, heard) => saved[ref] = heard,
    now: () => 99,
  );

  HearRun start(FakeRunner runner, {String ref = '1_1'}) => pipeline(
    runner,
  ).start(ref: ref, audioPath: 'song.mp3', vocalsPath: vocals, audioBytes: 7);

  const separated = VocalsResult(
    samples: 0,
    chunks: 1,
    decodeMs: 0,
    separateMs: 0,
    resampleMs: 0,
    scale: 1,
  );

  group('router', () {
    test('GigaAM sure (>= 0.80): its words, Whisper never runs', () async {
      final runner = FakeRunner(
        (job) => switch (job) {
          VocalsJob() => separated,
          GigaamJob() => gigaamHeard([
            (1, 20),
          ], said('Я иду ${words(24, 'домой')}', 1, 0.95)),
          _ => throw StateError('unexpected ${job.name}'),
        },
      );
      final heard = await start(runner).result;
      expect(runner.names, ['separate', 'gigaam']);
      final separate = runner.jobs.first.job as VocalsJob;
      expect(separate.audioPath, 'song.mp3');
      expect(separate.outPath, vocals);
      expect(heard.outcome, HeardOutcome.words);
      expect(heard.model, HeardModel.gigaam);
      expect(heard.language, 'ru');
      expect(heard.rough, isFalse);
      expect(heard.audioBytes, 7);
      expect(heard.bundles, 'hear-words-1 whisper-turbo-1');
      expect(heard.heardAtMs, 99);
      expect(heard.lines.first.text, startsWith('Я иду'));
      expect(saved.keys, ['1_1']);
      // The vocals go once the result is saved.
      expect(File(vocals).existsSync(), isFalse);
    });

    test('GigaAM unsure: Whisper over the same chunks, its words', () async {
      final runner = FakeRunner(
        (job) => switch (job) {
          VocalsJob() => separated,
          GigaamJob() => gigaamHeard([
            (1, 10),
            (12, 30),
          ], said(words(30, 'zz'), 1, 0.79)),
          WhisperJob(:final ranges) => whisperHeard(ranges!, [
            (
              language: 'en',
              words: said('Hello ${words(10, 'there')}', 1, 0.95),
            ),
            (language: 'en', words: said(words(15, 'again'), 12, 0.95)),
          ]),
          _ => throw StateError('unexpected ${job.name}'),
        },
      );
      final heard = await start(runner).result;
      expect(runner.names, ['separate', 'gigaam', 'whisper']);
      final whisper = runner.jobs.last.job as WhisperJob;
      expect(whisper.ranges, [(16000, 160000), (192000, 480000)]);
      expect(whisper.language, isNull);
      expect(whisper.vocalsPath, vocals);
      expect(whisper.modelPath, 'turbo.bin');
      expect(whisper.libraryFolder, 'whisper.cpp');
      expect(heard.model, HeardModel.whisper);
      expect(heard.language, 'en');
      expect(heard.russianConfidence, closeTo(0.79, 1e-9));
      expect(heard.wordCount, 26);
      expect(heard.lines.first.text, startsWith('Hello'));
    });

    test('just under 0.80 goes to Whisper, 0.80 stays with GigaAM', () async {
      Future<List<String>> route(double confidence) async {
        final runner = FakeRunner(
          (job) => switch (job) {
            VocalsJob() => separated,
            GigaamJob() => gigaamHeard([
              (1, 20),
            ], said(words(25, 'слово'), 1, confidence)),
            WhisperJob(:final ranges) => whisperHeard(ranges!, [
              (language: 'ru', words: said(words(25, 'слово'), 1, 0.9)),
            ]),
            _ => throw StateError('unexpected'),
          },
        );
        await start(runner).result;
        return runner.names;
      }

      expect(await route(0.7996), ['separate', 'gigaam', 'whisper']);
      expect(await route(0.80), ['separate', 'gigaam']);
    });
  });

  group('one language for Russian songs', () {
    // Chunks: ru 10 s, en 4 s, ru 8 s, de 2 s.
    const ranges = [
      (0, 160000),
      (200000, 264000),
      (300000, 428000),
      (500000, 532000),
    ];

    FakeRunner runner({required double forcedConfidence, String main = 'ru'}) =>
        FakeRunner(
          (job) => switch (job) {
            VocalsJob() => separated,
            GigaamJob() => gigaamHeard([
              for (final (start, end) in ranges) (start / sr, end / sr),
            ], said(words(30, 'x'), 0, 0.6)),
            WhisperJob(:final ranges, :final language) when language == null =>
              whisperHeard(ranges!, [
                (language: main, words: said(words(20, 'а'), 0, 0.95)),
                (language: 'en', words: said(words(5, 'wrong'), 12.5, 0.7)),
                (language: main, words: said(words(15, 'б'), 19, 0.95)),
                (language: 'de', words: said(words(2, 'falsch'), 31.5, 0.9)),
              ]),
            WhisperJob(:final ranges) => whisperHeard(ranges!, [
              for (final (start, _) in ranges)
                (
                  language: 'ru',
                  words: said('в г', start / sr, forcedConfidence),
                ),
            ]),
            _ => throw StateError('unexpected'),
          },
        );

    test('chunks in another language are heard again as Russian', () async {
      // Taken even when less sure: Whisper's English over Russian singing
      // is confident and wrong (#13, session 54).
      final fake = runner(forcedConfidence: 0.5);
      final heard = await start(fake).result;
      expect(fake.names, ['separate', 'gigaam', 'whisper', 'whisper']);
      final again = fake.jobs.last.job as WhisperJob;
      expect(again.language, 'ru');
      expect(again.ranges, [(200000, 264000), (500000, 532000)]);
      expect(again.speechSeconds, closeTo(24.0, 1e-9));
      final texts = [for (final word in heard.words) word.text];
      expect(texts, isNot(contains('wrong')));
      expect(texts, isNot(contains('falsch')));
      expect(texts.where((text) => text == 'в').length, 2);
      // Still in time order.
      final starts = [for (final word in heard.words) word.start];
      expect(starts, [...starts]..sort());
      expect(heard.language, 'ru');
    });

    test('a song mostly in another language keeps each chunk\'s', () async {
      final fake = runner(forcedConfidence: 1, main: 'en');
      final heard = await start(fake).result;
      expect(fake.names, ['separate', 'gigaam', 'whisper']);
      expect(heard.language, 'en');
    });

    test('songLanguage weighs chunks by length', () {
      final result = whisperHeard(
        [(0, 100), (100, 150), (150, 260)],
        [
          (language: 'en', words: const []),
          (language: 'ru', words: const []),
          (language: 'ru', words: const []),
        ],
      ).result;
      expect(songLanguage(result), 'ru');
      expect(chunksToHearAsRussian(result), [0]);
      // Russian the largest part but not half the singing: a mixed song,
      // each chunk keeps its own language.
      final mixed = whisperHeard(
        [(0, 100), (100, 190), (190, 270)],
        [
          (language: 'ru', words: const []),
          (language: 'en', words: const []),
          (language: 'de', words: const []),
        ],
      ).result;
      expect(songLanguage(mixed), 'ru');
      expect(chunksToHearAsRussian(mixed), isEmpty);
      expect(
        songLanguage(
          const WhisperResult(samples: 0, speechSeconds: 0, chunks: []),
        ),
        isNull,
      );
    });
  });

  group('quiet and short songs', () {
    FakeRunner song(
      List<(double, double)> ranges,
      List<HeardWord> words, {
      required double loud,
      double confidence = 0.9,
    }) => FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard(ranges, words, loud: loud),
        WhisperJob(:final ranges) => whisperHeard(ranges!, [
          for (final _ in ranges) (language: 'en', words: const <HeardWord>[]),
        ]),
        _ => throw StateError('unexpected'),
      },
    );

    test('no speech chunks and quiet vocals: no singing found', () async {
      final fake = song(const [], const [], loud: 0.4);
      final heard = await start(fake).result;
      expect(fake.names, ['separate', 'gigaam']);
      expect(heard.outcome, HeardOutcome.noSinging);
      expect(saved['1_1']!.outcome, HeardOutcome.noSinging);
    });

    test('a word or two over quiet vocals: no singing found', () async {
      final heard = await start(song([(1, 3)], said('ох', 1, 0.9), loud: 0.4))
          .result;
      expect(heard.outcome, HeardOutcome.noSinging);
      expect(heard.lyrics, isNull);
    });

    test('few words over loud vocals: shown, rough', () async {
      final heard = await start(
        song([(1, 5)], said('Я здесь и там', 1, 0.97), loud: 80),
      ).result;
      expect(heard.outcome, HeardOutcome.words);
      expect(heard.rough, isTrue);
      expect(heard.model, HeardModel.gigaam);
    });

    test('singing nobody made words of: none made out', () async {
      final fake = song([(1, 50)], const [], loud: 80);
      final heard = await start(fake).result;
      // GigaAM heard nothing (confidence 0): Whisper tried too.
      expect(fake.names, ['separate', 'gigaam', 'whisper']);
      expect(heard.outcome, HeardOutcome.noWords);
    });
  });

  group('runs that do not finish', () {
    FakeRunner normal() => FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard([(1, 20)], said(words(25, 'x'), 1, 0.5)),
        WhisperJob(:final ranges) => whisperHeard(ranges!, [
          (language: 'en', words: said(words(25, 'y'), 1, 0.95)),
        ]),
        _ => throw StateError('unexpected'),
      },
    );

    test('a whole vocals file from before skips separation', () async {
      File(vocals).writeAsBytesSync([0, 0, 0, 0]);
      File(vocalsMarkerOf(vocals)).writeAsStringSync(
        vocalsMarkerText(
          audioPath: 'song.mp3',
          audioBytes: 7,
          separatorModel: 'kim.onnx',
        ),
      );
      final fake = normal();
      await start(fake).result;
      expect(fake.names, ['gigaam', 'whisper']);
    });

    test('cancel during Whisper: nothing saved, vocals kept', () async {
      final fake = normal()..hold = (job) => job is WhisperJob;
      final run = start(fake);
      while (fake.jobs.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      run.cancel();
      expect(fake.jobs.last.cancelled, isTrue);
      await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
      expect(run.cancelled, isTrue);
      expect(saved, isEmpty);
      expect(File(vocals).existsSync(), isTrue);
      expect(fake.names, ['separate', 'gigaam', 'whisper']);
    });

    test('cancel during separation: no later stage starts', () async {
      final fake = normal()..hold = (job) => job is VocalsJob;
      final run = start(fake);
      await Future<void>.delayed(Duration.zero);
      // The separator's result comes after the cancel: not used.
      final separate = fake.jobs.single;
      File(vocals).writeAsBytesSync([0]);
      run.cancel();
      separate.finish(separated);
      await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
      expect(fake.names, ['separate']);
      expect(saved, isEmpty);
      // The whole vocals file it wrote is kept for the next run, marked.
      expect(File(vocalsMarkerOf(vocals)).existsSync(), isTrue);
      final again = normal();
      await start(again).result;
      expect(again.names, ['gigaam', 'whisper']);
    });

    test('old vocals of another file are gone before separation', () async {
      File(vocals).writeAsBytesSync([9, 9]);
      File(vocalsMarkerOf(vocals)).writeAsStringSync('{"audio":"other.mp3"}');
      final fake = normal()..hold = (job) => job is VocalsJob;
      final run = start(fake);
      await Future<void>.delayed(Duration.zero);
      expect(File(vocals).existsSync(), isFalse);
      expect(File(vocalsMarkerOf(vocals)).existsSync(), isFalse);
      // Stopped before the separator wrote anything: nothing is marked.
      run.cancel();
      await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
      expect(File(vocalsMarkerOf(vocals)).existsSync(), isFalse);
    });

    test(
      'once saved, the run succeeds: a cancel or a log failure is late',
      () async {
        late HearRun run;
        final hear = HearWords(
          runner: normal(),
          paths: const HearWordsPaths(
            separatorModel: '',
            silero: '',
            gigaamFolder: '',
            mpv: '',
            tempDir: '',
            whisperBridge: '',
            whisperLibraries: '',
            whisperModel: '',
          ),
          save: (ref, heard) {
            saved[ref] = heard;
            // Someone told of the save cancels at once.
            run.cancel();
          },
          log: (_) => throw const FileSystemException('disk full'),
        );
        run = hear.start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
        final heard = await run.result;
        expect(saved['1_1'], same(heard));
        expect(run.cancelled, isFalse);
      },
    );

    test('kept vocals of another file are separated again', () async {
      final first = normal();
      final run = pipeline(first).start(
        ref: '1_1',
        audioPath: 'song.mp3',
        vocalsPath: vocals,
        audioBytes: 7,
      );
      // Stopped after separation: the vocals stay for a restart.
      first.hold = (job) => job is GigaamJob;
      while (first.jobs.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      run.cancel();
      await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
      expect(File(vocals).existsSync(), isTrue);
      // The same file again: separation is skipped.
      final same = normal()..hold = (job) => job is GigaamJob;
      final again = pipeline(same).start(
        ref: '1_1',
        audioPath: 'song.mp3',
        vocalsPath: vocals,
        audioBytes: 7,
      );
      await Future<void>.delayed(Duration.zero);
      expect(same.names, ['gigaam']);
      again.cancel();
      await expectLater(again.result, throwsA(isA<WorkerCancelled>()));
      // Another file (VK swapped it, or another version): separated anew.
      final other = normal();
      await pipeline(other)
          .start(
            ref: '1_1',
            audioPath: 'other.mp3',
            vocalsPath: vocals,
            audioBytes: 8,
          )
          .result;
      expect(other.names, ['separate', 'gigaam', 'whisper']);
      expect(File('$vocals.from').existsSync(), isFalse);
    });

    test('a failed stage saves nothing and keeps the vocals', () async {
      final fake = FakeRunner(
        (job) => switch (job) {
          VocalsJob() => separated,
          _ => throw const WorkerJobError('model missing'),
        },
      );
      final run = start(fake);
      await expectLater(run.result, throwsA(isA<WorkerJobError>()));
      expect(saved, isEmpty);
      expect(File(vocals).existsSync(), isTrue);
    });

    test('progress names the step', () async {
      final fake = normal()..hold = (job) => job is GigaamJob;
      final run = start(fake);
      final seen = <HearProgress>[];
      run.progress.listen(seen.add);
      while (fake.jobs.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final gigaam = fake.jobs.last;
      gigaam.progressController.add((stage: 'hear', done: 1, total: 2));
      gigaam.finish(normal().answer(gigaam.job));
      await run.result;
      expect(seen, [
        (step: 'separate', stage: 'start', done: 0, total: 0, gpu: false),
        (step: 'gigaam', stage: 'start', done: 0, total: 0, gpu: false),
        (step: 'gigaam', stage: 'hear', done: 1, total: 2, gpu: false),
        (step: 'whisper', stage: 'start', done: 0, total: 0, gpu: false),
      ]);
    });

    test('vocals of another separator or a changed file are made again', () {
      final song = File('${temp.path}/song.mp3')..writeAsBytesSync([1, 2, 3]);
      String marker(String separator) => vocalsMarkerText(
        audioPath: song.path,
        audioBytes: 3,
        separatorModel: separator,
      );
      final first = marker('hear-words-1/kim.onnx');
      expect(marker('hear-words-1/kim.onnx'), first);
      expect(marker('hear-words-2/kim.onnx'), isNot(first));
      // The same size written anew (VK swapped the file for another).
      song.setLastModifiedSync(DateTime(2020));
      expect(marker('hear-words-1/kim.onnx'), isNot(first));
    });

    group('Whisper fetched when first needed', () {
      HearWords withHook(
        FakeRunner runner,
        Future<void> Function(HearRun run) hook,
      ) => HearWords(
        runner: runner,
        paths: const HearWordsPaths(
          separatorModel: 'kim.onnx',
          silero: '',
          gigaamFolder: '',
          mpv: '',
          tempDir: '',
          whisperBridge: '',
          whisperLibraries: '',
          whisperModel: '',
        ),
        save: (ref, heard) => saved[ref] = heard,
        beforeWhisper: hook,
      );

      test('a Russian song never asks for it', () async {
        var asked = 0;
        final fake = FakeRunner(
          (job) => switch (job) {
            VocalsJob() => separated,
            GigaamJob() => gigaamHeard([
              (1, 20),
            ], said(words(25, 'x'), 1, 0.95)),
            _ => throw StateError('unexpected'),
          },
        );
        await withHook(
          fake,
          (_) async => asked++,
        ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals).result;
        expect(asked, 0);
        expect(fake.names, ['separate', 'gigaam']);
      });

      test('a failed download keeps the vocals; the retry skips '
          'separation', () async {
        final fake = normal();
        final run = withHook(
          fake,
          (_) async => throw const FileSystemException('offline'),
        ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
        await expectLater(run.result, throwsA(isA<FileSystemException>()));
        expect(fake.names, ['separate', 'gigaam']);
        expect(saved, isEmpty);
        expect(File(vocals).existsSync(), isTrue);
        final again = normal();
        await withHook(
          again,
          (_) async {},
        ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals).result;
        expect(again.names, ['gigaam', 'whisper']);
      });

      test('a cancel during the download: Whisper never starts', () async {
        final fake = normal();
        final gate = Completer<void>();
        final run = withHook(
          fake,
          (_) => gate.future,
        ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
        while (fake.jobs.length < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        await fake.jobs.last.result;
        await Future<void>.delayed(Duration.zero);
        run.cancel();
        gate.completeError(const FileSystemException('stopped'));
        await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
        expect(fake.names, ['separate', 'gigaam']);
      });
    });
  });

  group('on the GPU (plan 10 I2i)', () {
    HearWords onGpu(
      FakeRunner runner, {
      void Function()? failed,
      List<String>? log,
      String tempDir = 'temp',
    }) => HearWords(
      runner: runner,
      paths: HearWordsPaths(
        separatorModel: 'kim.onnx',
        silero: 'silero.onnx',
        gigaamFolder: 'gigaam',
        mpv: 'mpv.dll',
        tempDir: tempDir,
        whisperBridge: 'bridge.dll',
        whisperLibraries: 'whisper.cpp',
        whisperModel: 'turbo.bin',
        gpu: true,
        gpuBackends: 'hear-gpu-1/vulkan',
      ),
      save: (ref, heard) => saved[ref] = heard,
      onGpuFailed: failed,
      log: log?.add,
    );

    Object unsure(WorkerJob<Object?> job) => switch (job) {
      VocalsJob() => separated,
      GigaamJob() => gigaamHeard([(1, 20)], said(words(25, 'zz'), 1, 0.5)),
      WhisperJob(:final ranges) => whisperHeard(ranges!, [
        (language: 'en', words: said(words(25, 'there'), 1, 0.95)),
      ]),
      _ => throw StateError('unexpected ${job.name}'),
    };

    test('every model stage asks for the GPU', () async {
      final runner = FakeRunner(unsure);
      final seen = <HearProgress>[];
      final log = <String>[];
      final run = onGpu(
        runner,
        log: log,
      ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
      run.progress.listen(seen.add);
      await run.result;
      expect(runner.names, ['separate', 'gigaam', 'whisper']);
      final [separate, gigaam, whisper] = [
        for (final job in runner.jobs) job.job,
      ];
      expect((separate as VocalsJob).directMlDevice, directMlBestGpu);
      expect((gigaam as GigaamJob).directMlDevice, directMlBestGpu);
      expect((whisper as WhisperJob).gpuBackends, 'hear-gpu-1/vulkan');
      expect(seen.every((unit) => unit.gpu), isTrue);
      expect(log.last, endsWith('GPU separate gigaam whisper'));
    });

    test('a stage that fails on the GPU runs again on the CPU, and so do '
        'the later stages', () async {
      var failures = 0;
      final log = <String>[];
      final runner = FakeRunner((job) {
        if (job is GigaamJob && job.directMlDevice != null) {
          throw const WorkerJobError('OnnxError: device removed');
        }
        return unsure(job);
      });
      final heard = await onGpu(
        runner,
        failed: () => failures++,
        log: log,
      ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals).result;
      expect(runner.names, ['separate', 'gigaam', 'gigaam', 'whisper']);
      final jobs = [for (final job in runner.jobs) job.job];
      expect((jobs[0] as VocalsJob).directMlDevice, directMlBestGpu);
      expect((jobs[1] as GigaamJob).directMlDevice, directMlBestGpu);
      expect((jobs[2] as GigaamJob).directMlDevice, isNull);
      expect((jobs[3] as WhisperJob).gpuBackends, isNull);
      expect(failures, 1);
      expect(heard.model, HeardModel.whisper);
      expect(saved.keys, ['1_1']);
      expect(log.first, contains('gigaam failed on the GPU (WorkerJobError)'));
      // The line names no error text (paths may be in it).
      expect(log.first, isNot(contains('device removed')));
      expect(log.last, endsWith('GPU separate'));
    });

    test('a Whisper GPU failure is heard again on the CPU', () async {
      final runner = FakeRunner((job) {
        if (job is WhisperJob && job.gpuBackends != null) {
          throw const WorkerJobError('WhisperError: no GPU for whisper.cpp');
        }
        return unsure(job);
      });
      final heard = await onGpu(runner)
          .start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals)
          .result;
      expect(runner.names, ['separate', 'gigaam', 'whisper', 'whisper']);
      expect(heard.language, 'en');
    });

    test('no helper to hear in (plan 10 I2i5): the run fails, no CPU try, '
        'the GPU stays on', () async {
      var failures = 0;
      final runner = FakeRunner(
        (job) => throw const WorkerUnavailable('the helper would not start'),
      );
      final run = onGpu(
        runner,
        failed: () => failures++,
      ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
      await expectLater(run.result, throwsA(isA<WorkerUnavailable>()));
      expect(runner.names, ['separate']);
      expect(failures, 0);
      expect(saved, isEmpty);
    });

    test('a separation ended on the GPU leaves no half vocals or decoded '
        'song for the CPU try (a killed helper cannot clean up)', () async {
      final scratch = Directory('${temp.path}/run')..createSync();
      final decoded = File('${scratch.path}/fit-123-9.f32');
      final stereo = File('${scratch.path}/fit-123-9.f32.vocals');
      final other = File('${scratch.path}/notes.txt')..writeAsStringSync('x');
      final half = File('$vocals.part');
      var seenAtCpuTry = <bool>[];
      final runner = FakeRunner((job) {
        if (job is VocalsJob && job.directMlDevice != null) {
          decoded.writeAsBytesSync([1]);
          stereo.writeAsBytesSync([2]);
          half.writeAsBytesSync([3]);
          throw const WorkerJobError('the helper ended (exit code -1)');
        }
        if (job is VocalsJob) {
          seenAtCpuTry = [
            decoded.existsSync(),
            stereo.existsSync(),
            half.existsSync(),
          ];
        }
        return unsure(job);
      });
      await onGpu(
        runner,
        tempDir: scratch.path,
      ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals).result;
      expect(runner.names, ['separate', 'separate', 'gigaam', 'whisper']);
      expect(seenAtCpuTry, [false, false, false]);
      expect(other.existsSync(), isTrue, reason: 'only the decoder files go');
      expect(saved.keys, ['1_1']);
    });

    test(
      'a separation that fails on the CPU too leaves no half vocals',
      () async {
        final half = File('$vocals.part');
        final runner = FakeRunner((job) {
          if (job is VocalsJob) {
            half.writeAsBytesSync([3]);
            throw const WorkerJobError('the helper ended (exit code 1)');
          }
          return unsure(job);
        });
        await expectLater(
          onGpu(runner)
              .start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals)
              .result,
          throwsA(isA<WorkerJobError>()),
        );
        expect(runner.names, ['separate', 'separate']);
        expect(half.existsSync(), isFalse);
      },
    );

    test('a cancel during a GPU stage stops, with no CPU try', () async {
      final runner = FakeRunner(unsure)..hold = (job) => job is GigaamJob;
      var failures = 0;
      final run = onGpu(
        runner,
        failed: () => failures++,
      ).start(ref: '1_1', audioPath: 'song.mp3', vocalsPath: vocals);
      while (runner.jobs.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      run.cancel();
      runner.jobs.last.fail(const WorkerCancelled());
      await expectLater(run.result, throwsA(isA<WorkerCancelled>()));
      expect(runner.names, ['separate', 'gigaam']);
      expect(failures, 0);
      expect(saved, isEmpty);
    });
  });

  group('pickWhisperGpu', () {
    test('the discrete GPU first, else the built-in one, else none', () {
      expect(pickWhisperGpu(const []), isNull);
      expect(pickWhisperGpu(const [(name: 'Radeon', integrated: true)]), 0);
      expect(
        pickWhisperGpu(const [
          (name: 'Radeon', integrated: true),
          (name: 'RTX', integrated: false),
        ]),
        1,
      );
      expect(
        pickWhisperGpu(const [
          (name: 'RTX', integrated: false),
          (name: 'Radeon', integrated: true),
        ]),
        0,
      );
    });
  });

  group('in the lyrics controller', () {
    late LibraryStore store;
    late List<Track> tracks;
    late Map<int, String> routeKeys;

    setUp(() {
      store = LibraryStore.open(':memory:');
      final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      store.upsertAll(vk, [
        for (var i = 0; i < 2; i++)
          NewTrack(
            sourceKey: '1_$i',
            artist: 'Артист $i',
            title: 'Песня $i',
            durationSec: 200,
            addedAt: i,
          ),
      ]);
      tracks = store.loadAll()
        ..sort((a, b) => a.sourceKey!.compareTo(b.sourceKey!));
      routeKeys = {for (final track in tracks) track.id: track.sourceKey!};
      // Every source said "none" lately: nothing is asked.
      for (final key in ['1_0', '1_1', '1_9']) {
        for (final source in ['vk', 'lrclib']) {
          store.saveLyrics(source, key, null);
        }
      }
    });
    tearDown(() => store.close());

    LyricsController controller() => LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadHeard: store.heardLyricsOf,
      sources: [_NoneSource('lrclib')],
      routeOf: (track) =>
          (key: routeKeys[track.id]!, accessKey: null, call: null),
    );

    HeardLyrics heardWords() => judgeHeard(
      model: HeardModel.gigaam,
      words: said('Я здесь. ${words(25, 'снова')}', 1, 0.95),
      confidence: 0.95,
      russianConfidence: 0.95,
      language: 'ru',
      loud: 100,
      songMs: 200000,
      heardAtMs: 1,
    );

    test('heard words show when no source has lyrics, apart from them', () {
      final lyrics = controller()..show(tracks[0]);
      expect(lyrics.state, isA<LyricsMissing>());
      expect((lyrics.state as LyricsMissing).heard, isNull);
      store.saveHeardLyrics('1_0', heardWords());
      lyrics.heardChanged('1_0');
      final shown = lyrics.state as LyricsShown;
      expect(shown.lyrics.source, heardSource);
      expect(shown.lyrics.lines.first.text, 'Я здесь.');
      expect(lyrics.heard!.model, HeardModel.gigaam);
      // Not one of the sources the chooser lists and asks.
      expect(
        lyrics.choices.map((choice) => choice.source),
        isNot(contains(heardSource)),
      );
      expect(lyricsSourceLabel(heardSource), 'Heard by the app');
    });

    test('no singing found shows as missing with what was heard', () {
      store.saveHeardLyrics(
        '1_0',
        judgeHeard(
          model: null,
          words: const [],
          confidence: 0,
          russianConfidence: 0,
          language: null,
          loud: 0,
          songMs: 200000,
          heardAtMs: 1,
        ),
      );
      final lyrics = controller()..show(tracks[0]);
      final state = lyrics.state as LyricsMissing;
      expect(state.heard!.outcome, HeardOutcome.noSinging);
    });

    test('found lyrics beat heard ones; the user can pick heard', () {
      store.saveHeardLyrics('1_0', heardWords());
      store.saveLyrics(
        'vk',
        '1_0',
        const Lyrics(source: 'vk', lines: [LyricLine('Слова VK')]),
      );
      final lyrics = controller()..show(tracks[0]);
      expect((lyrics.state as LyricsShown).lyrics.source, 'vk');
      lyrics.use(heardSource);
      expect((lyrics.state as LyricsShown).lyrics.source, heardSource);
      expect(store.lyricsPickOf('1_0'), heardSource);
      // Kept after a restart: a new controller shows the pick.
      final again = controller()..show(tracks[0]);
      expect((again.state as LyricsShown).lyrics.source, heardSource);
      expect(again.chosen, heardSource);
    });

    test('a source refresh leaves the heard version alone', () async {
      store.saveHeardLyrics('1_0', heardWords());
      final lyrics = controller()..show(tracks[0]);
      await lyrics.askAll(again: true);
      expect(store.heardLyricsOf('1_0'), isNotNull);
      expect((lyrics.state as LyricsShown).lyrics.source, heardSource);
    });

    test(
      'a version switch during a run: saved under the key at the start',
      () async {
        final lyrics = controller()..show(tracks[0]);
        final runner = FakeRunner(
          (job) => switch (job) {
            VocalsJob() => separated,
            GigaamJob() => gigaamHeard([
              (1, 20),
            ], said('Я здесь. ${words(25, 'снова')}', 1, 0.95)),
            _ => throw StateError('unexpected'),
          },
        )..hold = (job) => job is GigaamJob;
        final hear = HearWords(
          runner: runner,
          paths: const HearWordsPaths(
            separatorModel: '',
            silero: '',
            gigaamFolder: '',
            mpv: '',
            tempDir: '',
            whisperBridge: '',
            whisperLibraries: '',
            whisperModel: '',
          ),
          save: (ref, heard) {
            store.saveHeardLyrics(ref, heard);
            lyrics.heardChanged(ref);
          },
        );
        final song = tracks[0];
        final run = hear.start(
          ref: lyrics.routeKeyOf(song)!,
          audioPath: 'song.mp3',
          vocalsPath: vocals,
        );
        while (runner.jobs.length < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        // Another version is chosen for the song meanwhile: it now plays
        // the upload 1_9, which has no lyrics either. The player starts the
        // same library row again (PlaybackController.versionChanged).
        routeKeys[song.id] = '1_9';
        lyrics.show(song);
        expect(lyrics.shownKey, '1_9');
        final gigaam = runner.jobs.last;
        gigaam.finish(runner.answer(gigaam.job));
        final heard = await run.result;
        expect(run.ref, '1_0');
        expect(store.heardLyricsOf('1_0')!.lines, heard.lines);
        expect(store.heardLyricsOf('1_9'), isNull);
        // The version shown is not given the other version's words.
        expect(lyrics.state, isA<LyricsMissing>());
        expect(lyrics.heard, isNull);
        // Back on the first version, its heard words show.
        routeKeys[song.id] = '1_0';
        lyrics.show(song);
        expect((lyrics.state as LyricsShown).lyrics.source, heardSource);
      },
    );

    test('found lyrics follow a version switch of the same row', () {
      store.saveLyrics(
        'vk',
        '1_0',
        const Lyrics(source: 'vk', lines: [LyricLine('Слова A')]),
      );
      final lyrics = controller()..show(tracks[0]);
      expect((lyrics.state as LyricsShown).lyrics.lines.single.text, 'Слова A');
      routeKeys[tracks[0].id] = '1_9';
      lyrics.show(tracks[0]);
      expect(lyrics.shownKey, '1_9');
      expect(lyrics.state, isA<LyricsMissing>());
    });

    test('a heard save while a dropped ask runs leaves no spinner', () async {
      final slow = _SlowSource('lrclib');
      store
        ..saveLyrics(
          'vk',
          '1_0',
          const Lyrics(source: 'vk', lines: [LyricLine('Слова')]),
        )
        // LRCLIB's "none" is old: it is asked again.
        ..saveLyrics('lrclib', '1_0', null, atMs: 0);
      final lyrics = LyricsController(
        load: store.lyricsOf,
        save: store.saveLyrics,
        loadPick: store.lyricsPickOf,
        savePick: store.saveLyricsPick,
        loadHeard: store.heardLyricsOf,
        sources: [slow],
        routeOf: (track) =>
            (key: routeKeys[track.id]!, accessKey: null, call: null),
      )..show(tracks[0]);
      expect((lyrics.state as LyricsShown).refreshing, isTrue);
      await Future<void>.delayed(Duration.zero);
      lyrics.use('vk');
      store.saveHeardLyrics('1_0', heardWords());
      lyrics.heardChanged('1_0');
      slow.answer.complete(null);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final state = lyrics.state as LyricsShown;
      expect(state.lyrics.source, 'vk');
      expect(state.refreshing, isFalse);
    });

    test('forgetting heard words asks the sources again', () async {
      final failing = _FailingSource('lrclib');
      store
        ..saveLyrics('vk', '1_0', null, atMs: 0)
        ..saveLyrics('lrclib', '1_0', null, atMs: 0);
      final lyrics = LyricsController(
        load: store.lyricsOf,
        save: store.saveLyrics,
        loadPick: store.lyricsPickOf,
        savePick: store.saveLyricsPick,
        loadHeard: store.heardLyricsOf,
        sources: [failing],
        routeOf: (track) =>
            (key: routeKeys[track.id]!, accessKey: null, call: null),
      )..show(tracks[0]);
      await pumpEventQueue();
      expect(lyrics.state, isA<LyricsFailed>());
      store.saveHeardLyrics('1_0', heardWords());
      lyrics.heardChanged('1_0');
      lyrics.use(heardSource);
      expect(store.lyricsPickOf('1_0'), heardSource);
      store.saveHeardLyrics('1_0', null);
      lyrics.heardChanged('1_0');
      // The pick of words no longer kept goes, and the failure (with its
      // retry) comes back instead of "no lyrics".
      expect(store.lyricsPickOf('1_0'), isNull);
      await pumpEventQueue();
      expect(lyrics.state, isA<LyricsFailed>());
      expect(failing.asked, 2);
    });
  });
}

/// An outside source whose answer the test gives.
class _SlowSource implements OutsideLyricsSource {
  _SlowSource(this.id);

  @override
  final String id;
  final answer = Completer<LyricsCandidate?>();

  @override
  Future<LyricsCandidate?> find(SongNames song) => answer.future;
}

/// An outside source that cannot be reached.
class _FailingSource implements OutsideLyricsSource {
  _FailingSource(this.id);

  @override
  final String id;
  var asked = 0;

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    asked++;
    throw const LyricsSourceException('offline');
  }
}

/// An outside source that has nothing.
class _NoneSource implements OutsideLyricsSource {
  _NoneSource(this.id);

  @override
  final String id;

  @override
  Future<LyricsCandidate?> find(SongNames song) async => null;
}
