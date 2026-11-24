// Plan 10 I2b: the "Hear the words" worker runs one job at a time on its
// own isolate, reports progress, and stops between units when cancelled.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';

/// Counts [units] units, each [unitMs] of busy work; waits at unit
/// [waitAt] until [gate] exists (so a test can cancel during it).
class CountJob extends WorkerJob<int> {
  const CountJob(this.units, {this.unitMs = 5, this.waitAt, this.gate});
  final int units;
  final int unitMs;
  final int? waitAt;
  final String? gate;

  @override
  String get name => 'count';

  @override
  int run(WorkerContext context) {
    for (var i = 1; i <= units; i++) {
      if (i == waitAt) {
        final until = DateTime.now().add(const Duration(seconds: 10));
        while (!File(gate!).existsSync() && DateTime.now().isBefore(until)) {
          sleep(const Duration(milliseconds: 5));
        }
      }
      final end = DateTime.now().add(Duration(milliseconds: unitMs));
      while (DateTime.now().isBefore(end)) {}
      context.unitDone('count', i, units);
    }
    return units;
  }
}

class FailJob extends WorkerJob<void> {
  const FailJob();

  @override
  String get name => 'fail';

  @override
  void run(WorkerContext context) => throw StateError('broken model');
}

/// Ends the worker isolate from inside, like a crash would.
class ExitJob extends WorkerJob<void> {
  const ExitJob();

  @override
  String get name => 'exit';

  @override
  void run(WorkerContext context) => Isolate.exit();
}

void main() {
  late SttWorker worker;
  final logged = <String>[];
  setUp(() {
    logged.clear();
    worker = SttWorker(onnxRuntimePath: 'unused.dll', log: logged.add);
  });
  tearDown(() => worker.close());

  test('runs a job, reports every unit and memory, logs it', () async {
    final task = worker.run(const CountJob(4));
    final seen = <int>[];
    task.progress.listen((p) => seen.add(p.done));
    expect(await task.result, 4);
    expect(seen, [1, 2, 3, 4]);
    final memory = task.memory!;
    expect(memory.peakWorkingSet, greaterThan(0));
    expect(memory.afterWorkingSet, greaterThan(0));
    expect(logged.single, startsWith('stt count: ok in '));
    expect(logged.single, contains('peak '));
  });

  test('a cancel stops at the end of the unit it is in', () async {
    final dir = Directory.systemTemp.createTempSync('worker-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gate = '${dir.path}/go';
    final task = worker.run(CountJob(10, waitAt: 3, gate: gate));
    final seen = <int>[];
    task.progress.listen((p) {
      seen.add(p.done);
      if (p.done == 2) {
        // The job is now in unit 3, waiting for the gate.
        task.cancel();
        File(gate).writeAsStringSync('');
      }
    });
    await expectLater(task.result, throwsA(isA<WorkerCancelled>()));
    expect(seen, [1, 2, 3], reason: 'unit 3 finishes, unit 4 never starts');
    expect(logged.single, startsWith('stt count: cancelled'));
  });

  test(
    'a failure comes back as WorkerJobError and the worker goes on',
    () async {
      final failing = worker.run(const FailJob());
      await expectLater(
        failing.result,
        throwsA(
          isA<WorkerJobError>().having(
            (e) => e.message,
            'message',
            contains('broken model'),
          ),
        ),
      );
      expect(await worker.run(const CountJob(1)).result, 1);
    },
  );

  test('jobs run one after another, in order', () async {
    final order = <String>[];
    final first = worker.run(const CountJob(3, unitMs: 20));
    final second = worker.run(const CountJob(2));
    first.progress.listen((p) => order.add('a${p.done}'));
    second.progress.listen((p) => order.add('b${p.done}'));
    await Future.wait([first.result, second.result]);
    expect(order, ['a1', 'a2', 'a3', 'b1', 'b2']);
  });

  test('a job cancelled while it waits never starts', () async {
    final first = worker.run(const CountJob(3, unitMs: 20));
    final second = worker.run(const CountJob(2));
    var started = false;
    second.progress.listen((_) => started = true);
    second.cancel();
    expect(await first.result, 3);
    await expectLater(second.result, throwsA(isA<WorkerCancelled>()));
    expect(started, isFalse);
  });

  test(
    'a worker that dies fails its job, and the next job gets a new one',
    () async {
      await expectLater(
        worker.run(const ExitJob()).result,
        throwsA(isA<WorkerJobError>()),
      );
      expect(await worker.run(const CountJob(2)).result, 2);
    },
  );

  test('close cancels the running job and the waiting ones', () async {
    final dir = Directory.systemTemp.createTempSync('worker-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gate = '${dir.path}/go';
    final running = worker.run(CountJob(5, waitAt: 2, gate: gate));
    final waiting = worker.run(const CountJob(2));
    var waitingStarted = false;
    waiting.progress.listen((_) => waitingStarted = true);
    final first = Completer<void>();
    running.progress.listen((p) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    final closing = worker.close();
    File(gate).writeAsStringSync('');
    await closing;
    await expectLater(running.result, throwsA(isA<WorkerCancelled>()));
    await expectLater(waiting.result, throwsA(isA<WorkerCancelled>()));
    expect(waitingStarted, isFalse);
  });
}
