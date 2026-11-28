/// Taking the voice out for a karaoke export (plan 11 D1d): runs
/// [InstrumentalJob] on a job runner (the hear helper in the app) and turns
/// the export's Stop into the job's cancel.
library;

import 'dart:async';

import '../lyrics/stt_worker.dart';
import 'instrumental_job.dart';
import 'karaoke_render.dart';

/// Runs [job] on [runner]. [onProgress] hears the separator's share done.
/// After [stop] the job is cancelled; this returns (throwing
/// [KaraokeStopped]) only once the runner says the job ended, so its files
/// are let go. A failed job throws [WorkerJobError].
Future<void> runInstrumental({
  required JobRunner runner,
  required InstrumentalJob job,
  required void Function(double share) onProgress,
  required KaraokeStop stop,
}) async {
  if (stop.stopped) throw const KaraokeStopped();
  final task = runner.run(job);
  final listening = task.progress.listen((unit) {
    if (unit.stage == 'separate' && unit.total > 0) {
      onProgress(unit.done / unit.total);
    }
  });
  var cancelled = false;
  unawaited(
    stop.future.then((_) {
      cancelled = true;
      task.cancel();
    }),
  );
  try {
    await task.result;
  } on WorkerCancelled {
    throw const KaraokeStopped();
  } finally {
    await listening.cancel();
  }
  if (cancelled || stop.stopped) throw const KaraokeStopped();
}
