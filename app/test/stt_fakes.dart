// A fake "Hear the words" worker and made-up model results, shared by
// hear_words_test.dart and lyrics_hearer_test.dart (plan 10 I2e, I2f).

import 'dart:async';
import 'dart:io';

import 'package:ownsemble/lyrics/gigaam.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:ownsemble/lyrics/whisper.dart';
import 'package:ownsemble/lyrics/whisper_job.dart';

/// A job the fake worker holds: its answer comes from the test.
class FakeJob<R> implements RunningJob<R> {
  FakeJob(this.job);

  final WorkerJob<R> job;
  final _result = Completer<R>();
  final progressController = StreamController<WorkerProgress>.broadcast(
    sync: true,
  );
  var cancelled = false;

  void finish(Object value) {
    if (cancelled || _result.isCompleted) return;
    _result.complete(value as R);
    unawaited(progressController.close());
  }

  void fail(Object error) {
    if (_result.isCompleted) return;
    _result.completeError(error);
    unawaited(progressController.close());
  }

  @override
  Future<R> get result => _result.future;

  @override
  Stream<WorkerProgress> get progress => progressController.stream;

  @override
  void cancel() {
    if (_result.isCompleted) return;
    cancelled = true;
    fail(const WorkerCancelled());
  }
}

/// A worker that answers each job through [answer] at once, unless
/// [hold] says the test answers it itself.
class FakeRunner implements JobRunner {
  FakeRunner(this.answer);

  final Object Function(WorkerJob<Object?> job) answer;
  bool Function(WorkerJob<Object?> job) hold = (_) => false;
  final jobs = <FakeJob<Object?>>[];

  List<String> get names => [for (final job in jobs) job.job.name];

  @override
  RunningJob<R> run<R>(WorkerJob<R> job) {
    final fake = FakeJob<R>(job);
    jobs.add(fake);
    if (!hold(job)) {
      scheduleMicrotask(() {
        try {
          if (job is VocalsJob) {
            File((job as VocalsJob).outPath).writeAsBytesSync([0, 0, 0, 0]);
          }
          fake.finish(answer(job));
        } on Object catch (error) {
          fake.fail(error);
        }
      });
    }
    return fake;
  }
}

const sr = 16000;

/// Words of [text], 0.5 s apart from [start] seconds.
List<HeardWord> said(String text, double start, double confidence) => [
  for (final (i, word) in text.split(' ').indexed)
    HeardWord(start + i * 0.5, start + i * 0.5 + 0.3, word, confidence),
];

/// A GigaAM result over [ranges] (seconds) with [words] in the first chunk.
GigaamJobResult gigaamHeard(
  List<(double, double)> ranges,
  List<HeardWord> words, {
  double loud = 100,
  int seconds = 200,
}) => GigaamJobResult(
  result: GigaamResult(
    samples: seconds * sr,
    speechSeconds: ranges.fold(0, (sum, r) => sum + r.$2 - r.$1),
    chunks: [
      for (final (i, (start, end)) in ranges.indexed)
        (
          range: (start: (start * sr).round(), end: (end * sr).round()),
          frames: 0,
          tokens: const <HeardToken>[],
          words: i == 0 ? words : const <HeardWord>[],
        ),
    ],
  ),
  loadMs: 0,
  vadMs: 0,
  openMs: 0,
  encodeMs: 0,
  decodeMs: 0,
  loudSeconds: loud,
);

typedef Heard = ({String language, List<HeardWord> words});

/// A Whisper result: one chunk per [ranges] entry (samples), each with its
/// language and words.
WhisperJobResult whisperHeard(List<(int, int)> ranges, List<Heard> chunks) =>
    WhisperJobResult(
      result: WhisperResult(
        samples: 200 * sr,
        speechSeconds: 0,
        chunks: [
          for (final (i, (start, end)) in ranges.indexed)
            (
              range: (start: start, end: end),
              language: chunks[i].language,
              tokens: const [],
              words: chunks[i].words,
            ),
        ],
      ),
      loadMs: 0,
      vadMs: 0,
      openMs: 0,
      transcribeMs: 0,
      chunkMs: const [],
    );

String words(int count, String word) => List.filled(count, word).join(' ');
