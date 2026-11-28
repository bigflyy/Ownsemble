// Plan 11 D1d: the karaoke instrumental job on a (fake) job runner: progress,
// Stop as a cancel that waits for the job's end, failures passed on.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/karaoke/instrumental_job.dart';
import 'package:ownsemble/karaoke/karaoke_render.dart';
import 'package:ownsemble/karaoke/karaoke_separate.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';

import 'stt_fakes.dart';

const _job = InstrumentalJob(
  audioPath: 'song.mp3',
  outPath: 'inst.f32',
  modelPath: 'hq4.onnx',
  mpvPath: 'libmpv-2.dll',
  tempDir: 'tmp',
  threads: 4,
);

const _result = InstrumentalResult(
  frames: 10,
  chunks: 1,
  decodeMs: 1,
  separateMs: 2,
  inputScale: 1,
);

void main() {
  test('the separator share is passed on, other units are not', () async {
    final runner = FakeRunner((job) => _result)..hold = (_) => true;
    final shares = <double>[];
    final running = runInstrumental(
      runner: runner,
      job: _job,
      onProgress: shares.add,
      stop: KaraokeStop(),
    );
    await Future<void>.delayed(Duration.zero);
    final fake = runner.jobs.single;
    expect(fake.job, same(_job));
    fake.progressController
      ..add((stage: 'decode', done: 1, total: 1))
      ..add((stage: 'separate', done: 1, total: 4))
      ..add((stage: 'separate', done: 4, total: 4));
    fake.finish(_result);
    await running;
    expect(shares, [0.25, 1]);
  });

  test('stop cancels the job and waits for its end', () async {
    final runner = FakeRunner((job) => _result)..hold = (_) => true;
    final stop = KaraokeStop();
    var ended = false;
    final running = runInstrumental(
      runner: runner,
      job: _job,
      onProgress: (_) {},
      stop: stop,
    ).whenComplete(() => ended = true);
    final stopped = expectLater(running, throwsA(isA<KaraokeStopped>()));
    await Future<void>.delayed(Duration.zero);
    expect(ended, isFalse);
    stop.stop();
    await Future<void>.delayed(Duration.zero);
    expect(runner.jobs.single.cancelled, isTrue);
    await stopped;
    expect(ended, isTrue);
  });

  test('a stop before the start runs nothing', () async {
    final runner = FakeRunner((job) => _result);
    final stop = KaraokeStop()..stop();
    await expectLater(
      runInstrumental(
        runner: runner,
        job: _job,
        onProgress: (_) {},
        stop: stop,
      ),
      throwsA(isA<KaraokeStopped>()),
    );
    expect(runner.jobs, isEmpty);
  });

  test('a failed job is passed on', () async {
    final runner = FakeRunner(
      (job) => throw const WorkerJobError('OnnxError: bad model'),
    );
    await expectLater(
      runInstrumental(
        runner: runner,
        job: _job,
        onProgress: (_) {},
        stop: KaraokeStop(),
      ),
      throwsA(isA<WorkerJobError>()),
    );
  });
}
