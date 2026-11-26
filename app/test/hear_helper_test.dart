// Plan 10 I2i5: "Hear the words" in a helper process. Both ends of the
// conversation (lib/lyrics/hear_helper.dart): the helper's side on a real
// worker isolate, the app's side against a scripted process, including a
// Stop the helper ignores, a crash mid-job and a helper that never starts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/hear_helper.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';

/// Counts [units] units of [unitMs] each; waits at unit [waitAt] until the
/// file [gate] exists (so a test can cancel during it).
class CountJob extends WorkerJob<int> {
  const CountJob(this.units, {this.unitMs = 2, this.waitAt, this.gate});
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
    return units * 10;
  }
}

Map<String, Object?> _encodeCount(WorkerJob<Object?> job) {
  final count = job as CountJob;
  return {
    'units': count.units,
    'unitMs': count.unitMs,
    'waitAt': count.waitAt,
    'gate': count.gate,
  };
}

WorkerJob<Object?> _decodeCount(Map<String, Object?> json) => CountJob(
  json['units'] as int,
  unitMs: json['unitMs'] as int,
  waitAt: json['waitAt'] as int?,
  gate: json['gate'] as String?,
);

/// A process the test drives: what the app writes to it comes out of
/// [lines]; [say] is the helper writing a message.
class FakeProcess implements Process {
  FakeProcess({this.pid = 41, this.onKill});

  @override
  final int pid;

  /// What kill() does; by default the process exits with code 1.
  final void Function(FakeProcess process)? onKill;
  var kills = 0;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _stdin = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final IOSink _sink = IOSink(_stdin);

  /// The app's lines to the helper (one listener).
  late final Stream<String> lines = _stdin.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  /// The app's lines, collected, for scripted tests.
  final received = <Map<String, Object?>>[];
  var inputClosed = false;

  /// Collects [lines] into [received].
  void collect() {
    lines.listen(
      (line) => received.add(jsonDecode(line) as Map<String, Object?>),
      onDone: () => inputClosed = true,
    );
  }

  void sayLine(String line) => _stdout.add(utf8.encode('$line\n'));
  void say(Map<String, Object?> message) => sayLine(jsonEncode(message));
  void ready([int version = hearHelperVersion]) =>
      say({'type': 'ready', 'version': version});

  void exitWith(int code) {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
  }

  bool get exited => _exit.isCompleted;

  @override
  IOSink get stdin => _sink;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (onKill != null) {
      onKill!(this);
    } else {
      exitWith(1);
    }
    return true;
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  final logged = <String>[];
  setUp(logged.clear);

  group('helper side and app side together (worker isolate inside)', () {
    late List<FakeProcess> started;
    late ProcessJobRunner runner;

    setUp(() {
      started = [];
      runner = ProcessJobRunner(
        helperPath: 'ownsemble_hear.exe',
        onnxRuntimePath: 'unused.dll',
        log: logged.add,
        encodeJob: _encodeCount,
        decodeResult: (name, json) => json,
        start: (exe, args) async {
          expect(exe, 'ownsemble_hear.exe');
          expect(args, ['--onnx', 'unused.dll']);
          final process = FakeProcess(pid: 100 + started.length);
          started.add(process);
          unawaited(
            serveHearJobs(
              lines: process.lines,
              write: process.sayLine,
              onnxRuntimePath: 'unused.dll',
              decodeJob: _decodeCount,
              encodeResult: (name, result) => result,
            ).then((_) => process.exitWith(0)),
          );
          return process;
        },
      );
    });
    tearDown(() => runner.close());

    test('a job runs, reports every unit and the memory, logs it', () async {
      final task = runner.run(const CountJob(4));
      final units = <int>[];
      task.progress.listen((p) => units.add(p.done));
      expect(await task.result, 40);
      expect(units, [1, 2, 3, 4]);
      expect(logged, contains('hear helper: started, pid 100'));
      expect(
        logged.where((line) => line.startsWith('helper stt count: ok in')),
        hasLength(1),
      );
      // One helper for the jobs of a run.
      expect(await runner.run(const CountJob(1)).result, 10);
      expect(started, hasLength(1));
    });

    test('a cancel reaches the job while it works; the helper ends on '
        'close', () async {
      final gate = File(
        '${Directory.systemTemp.createTempSync('hear-helper').path}/go',
      );
      final task = runner.run(CountJob(5, waitAt: 2, gate: gate.path));
      await task.progress.first;
      task.cancel();
      await _settle();
      gate.createSync();
      await expectLater(task.result, throwsA(isA<WorkerCancelled>()));
      expect(started.single.kills, 0);
      await runner.close();
      expect(started.single.exited, isTrue);
      expect(logged, contains('hear helper: pid 100 ended, exit code 0'));
      gate.parent.deleteSync(recursive: true);
    });
  });

  group('app side against a scripted helper', () {
    late List<FakeProcess> started;
    late void Function(FakeProcess process)? onKill;

    ProcessJobRunner runnerWith({
      bool answerReady = true,
      Duration cancelGrace = const Duration(milliseconds: 50),
      Duration closeGrace = const Duration(milliseconds: 50),
      Duration readyTimeout = const Duration(seconds: 5),
      Object? startError,
    }) => ProcessJobRunner(
      helperPath: 'h.exe',
      onnxRuntimePath: 'cpu.dll',
      gpuOnnxRuntimePath: 'dml.dll',
      log: logged.add,
      cancelGrace: cancelGrace,
      closeGrace: closeGrace,
      readyTimeout: readyTimeout,
      encodeJob: _encodeCount,
      decodeResult: (name, json) => json,
      start: (exe, args) async {
        if (startError != null) throw startError;
        expect(args, ['--onnx', 'cpu.dll', '--gpu-onnx', 'dml.dll']);
        final process = FakeProcess(pid: 200 + started.length, onKill: onKill);
        started.add(process);
        process.collect();
        if (answerReady) process.ready();
        return process;
      },
    );

    setUp(() {
      started = [];
      onKill = null;
    });

    test('a helper that ignores a cancel is ended, and the job ends only '
        'once it has really exited', () async {
      // Windows ends a process a little after TerminateProcess returns.
      onKill = (process) =>
          Timer(const Duration(milliseconds: 80), () => process.exitWith(1));
      final runner = runnerWith();
      final task = runner.run(const CountJob(3));
      await _settle();
      expect(started.single.received.single['type'], 'job');
      var ended = false;
      unawaited(task.result.then((_) {}, onError: (_) => ended = true));
      task.cancel();
      await _settle();
      expect(started.single.received.last, {'type': 'cancel', 'id': 0});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(started.single.kills, 1);
      expect(ended, isFalse, reason: 'killed but not yet exited');
      await expectLater(task.result, throwsA(isA<WorkerCancelled>()));
      expect(started.single.exited, isTrue);
      expect(
        logged,
        contains('hear helper: count did not stop in 50 ms, ended'),
      );
    });

    test('a helper that dies mid-job fails it as an error (the GPU fallback '
        'retries), and the next job starts a fresh helper', () async {
      final runner = runnerWith();
      final task = runner.run(const CountJob(3));
      await _settle();
      started.single.say({
        'type': 'progress',
        'id': 0,
        'stage': 'count',
        'done': 1,
        'total': 3,
      });
      started.single.exitWith(-1073741819);
      await expectLater(
        task.result,
        throwsA(
          isA<WorkerJobError>()
              .having(
                (e) => e,
                'not unavailable',
                isNot(isA<WorkerUnavailable>()),
              )
              .having((e) => e.message, 'message', contains('exit code')),
        ),
      );
      final retry = runner.run(const CountJob(1));
      await _settle();
      expect(started, hasLength(2));
      expect(started.last.received.single['id'], 1);
      started.last.say({
        'type': 'end',
        'id': 1,
        'outcome': 'ok',
        'value': 10,
        'memory': [5, 6, 7, 8],
      });
      expect(await retry.result, 10);
      // A late line of the dead helper changes nothing.
      expect(
        logged,
        contains('hear helper: pid 200 ended, exit code -1073741819'),
      );
      await runner.close();
    });

    test('a helper that will not start, ends before it is ready or says '
        'another version: the job is unavailable, not a GPU fault', () async {
      final cannot = runnerWith(startError: const ProcessException('h', []));
      await expectLater(
        cannot.run(const CountJob(1)).result,
        throwsA(isA<WorkerUnavailable>()),
      );

      final silent = runnerWith(answerReady: false);
      final early = silent.run(const CountJob(1));
      await _settle();
      started.single.exitWith(3);
      await expectLater(early.result, throwsA(isA<WorkerUnavailable>()));

      started.clear();
      final old = runnerWith(answerReady: false);
      final job = old.run(const CountJob(1));
      await _settle();
      started.single.ready(hearHelperVersion + 1);
      await expectLater(job.result, throwsA(isA<WorkerUnavailable>()));
      expect(started.single.kills, 1);
      expect(started.single.received, isEmpty, reason: 'no job sent to it');

      started.clear();
      final hung = runnerWith(
        answerReady: false,
        readyTimeout: const Duration(milliseconds: 30),
      );
      final waiting = hung.run(const CountJob(1));
      await expectLater(waiting.result, throwsA(isA<WorkerUnavailable>()));
      expect(started.single.kills, 1);
    });

    test('other output is skipped and never logged as text; errors and '
        'unreadable results fail the job', () async {
      final runner = runnerWith();
      final ok = runner.run(const CountJob(1));
      final failing = expectLater(
        runner.run(const CountJob(2)).result,
        throwsA(isA<WorkerJobError>().having((e) => e.message, 'm', 'boom')),
      );
      await _settle();
      final helper = started.single;
      helper.sayLine('ggml_vulkan: secret path C:/Users/x');
      helper.say({'type': 'log', 'line': 'helper stt count: ok in 3 ms'});
      helper.say({'type': 'end', 'id': 1, 'outcome': 'error', 'value': 'boom'});
      helper.say({
        'type': 'end',
        'id': 0,
        'outcome': 'ok',
        'value': 10,
        'memory': [1, 2, 3, 4],
      });
      expect(await ok.result, 10);
      await failing;
      expect(logged, contains('hear helper: skipped 35 chars of other output'));
      expect(logged.any((line) => line.contains('secret')), isFalse);
      expect(logged, contains('helper stt count: ok in 3 ms'));
      await runner.close();
    });

    test('a result that comes after cancel() is given as cancelled', () async {
      final runner = runnerWith(cancelGrace: const Duration(seconds: 5));
      final task = runner.run(const CountJob(1));
      await _settle();
      task.cancel();
      started.single.say({
        'type': 'end',
        'id': 0,
        'outcome': 'ok',
        'value': 10,
        'memory': null,
      });
      await expectLater(task.result, throwsA(isA<WorkerCancelled>()));
      expect(started.single.kills, 0);
      await runner.close();
    });

    test('close: the input closes and the helper ends by itself; one that '
        'stays is ended', () async {
      final runner = runnerWith();
      final first = expectLater(
        runner.run(const CountJob(1)).result,
        throwsA(isA<WorkerCancelled>()),
      );
      await _settle();
      final polite = started.single;
      final closing = runner.close();
      await _settle();
      expect(polite.inputClosed, isTrue);
      polite.exitWith(0);
      await closing;
      await first;
      expect(polite.kills, 0);

      final stubborn = runnerWith(cancelGrace: const Duration(seconds: 5));
      final job = expectLater(
        stubborn.run(const CountJob(1)).result,
        throwsA(isA<WorkerCancelled>()),
      );
      await _settle();
      await stubborn.close();
      expect(started.last.kills, 1);
      await job;
      expect(
        logged,
        contains(
          'hear helper: did not end in 50 ms after its input closed, ended',
        ),
      );
    });
  });
}
