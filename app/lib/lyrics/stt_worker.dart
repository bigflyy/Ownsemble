/// The background worker of "Hear the words" (plan 10 I2b): one isolate
/// that owns the native model sessions and runs one job at a time.
///
/// A job is a list of bounded units (a separator chunk, a decode); between
/// units it reports progress and looks at a cancel flag. The flag is a
/// word of native memory both isolates see, because the worker's event
/// loop does not run while a job works synchronously, so a message could
/// not reach it. The worker keeps at most one model open, closes it before
/// it opens another, and closes it when the job ends, so the app's memory
/// goes back down after each job; the peak during the job and what is left
/// after it are measured for the log.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../platform/process_memory.dart';
import 'onnx_runtime.dart';

/// Thrown inside a job when its cancel flag is set, and by
/// [WorkerTask.result] after a cancel.
class WorkerCancelled implements Exception {
  const WorkerCancelled();

  @override
  String toString() => 'WorkerCancelled';
}

/// A job that failed inside the worker: its error as text.
class WorkerJobError implements Exception {
  const WorkerJobError(this.message);
  final String message;

  @override
  String toString() => 'WorkerJobError: $message';
}

/// Work the worker runs. It is sent to the worker isolate, so it must hold
/// only plain data (paths, numbers), and so must its result.
abstract class WorkerJob<R> {
  const WorkerJob();

  /// A short name for the log: 'separate'.
  String get name;

  /// Runs on the worker isolate, synchronously, unit by unit.
  R run(WorkerContext context);
}

/// What a job sees of the worker.
class WorkerContext {
  WorkerContext._(this._onnxPath, this._cancelFlag, this._progress);

  final String _onnxPath;
  final Pointer<Int32> _cancelFlag;
  final void Function(String stage, int done, int total) _progress;

  static OnnxRuntime? _runtime;
  static ({String path, int threads, bool arena, OnnxSession session})? _open;

  var _peakWorkingSet = 0;
  var _peakPrivate = 0;

  /// The model at [path], opened for this job; the one open before it (a
  /// different model) is closed first, so only one is in memory.
  OnnxSession model(
    String path, {
    required int threads,
    bool memoryArena = true,
  }) {
    final open = _open;
    if (open != null &&
        open.path == path &&
        open.threads == threads &&
        open.arena == memoryArena) {
      return open.session;
    }
    freeModel();
    final runtime = _runtime ??= OnnxRuntime.load(_onnxPath);
    final session = runtime.open(
      path,
      threads: threads,
      memoryArena: memoryArena,
    );
    _open = (
      path: path,
      threads: threads,
      arena: memoryArena,
      session: session,
    );
    _measure();
    return session;
  }

  /// Closes the open model, if any.
  void freeModel() {
    _open?.session.close();
    _open = null;
  }

  /// Ends a unit: reports [done] of [total] in [stage], then throws
  /// [WorkerCancelled] if the job was cancelled meanwhile.
  void unitDone(String stage, int done, int total) {
    _measure();
    _progress(stage, done, total);
    checkCancelled();
  }

  /// The job's cancel flag (an int32, non-zero once cancelled), for a
  /// native call that can stop midway on its own (whisper.cpp's abort
  /// callback reads it). Valid while the job runs.
  Pointer<Int32> get cancelFlag => _cancelFlag;

  /// Throws [WorkerCancelled] if the job was cancelled.
  void checkCancelled() {
    if (_cancelFlag.value != 0) throw const WorkerCancelled();
  }

  void _measure() {
    final now = processMemory();
    if (now == null) return;
    if (now.workingSet > _peakWorkingSet) _peakWorkingSet = now.workingSet;
    if (now.private > _peakPrivate) _peakPrivate = now.private;
  }
}

/// A job's progress: [done] of [total] units of [stage].
typedef WorkerProgress = ({String stage, int done, int total});

/// Memory during and after a job, in bytes (0 when not measured).
typedef WorkerMemory = ({
  int peakWorkingSet,
  int peakPrivate,
  int afterWorkingSet,
  int afterPrivate,
});

/// A job given to a runner: its result, progress and a way to stop it
/// (the pipeline's view of [WorkerTask], so tests can fake the worker).
abstract interface class RunningJob<R> {
  Future<R> get result;
  Stream<WorkerProgress> get progress;
  void cancel();
}

/// What runs jobs one after another: [SttWorker], or a fake in tests.
abstract interface class JobRunner {
  RunningJob<R> run<R>(WorkerJob<R> job);
}

/// One job given to the worker.
class WorkerTask<R> implements RunningJob<R> {
  WorkerTask._(this._flag);

  final Pointer<Int32> _flag;
  final _result = Completer<R>();
  final _progress = StreamController<WorkerProgress>.broadcast(sync: true);
  WorkerMemory? _memory;
  var _finished = false;

  /// The job's result; throws [WorkerCancelled] after [cancel] or
  /// [WorkerJobError] when the job failed.
  @override
  Future<R> get result => _result.future;

  /// Progress, unit by unit.
  @override
  Stream<WorkerProgress> get progress => _progress.stream;

  /// Memory during and after the job, once it has ended.
  WorkerMemory? get memory => _memory;

  /// Asks the job to stop at the end of the unit it is in. A result that
  /// arrives after this is given as [WorkerCancelled] too.
  @override
  void cancel() {
    if (!_finished) _flag.value = 1;
  }

  void _end() {
    _finished = true;
    calloc.free(_flag);
    unawaited(_progress.close());
  }
}

/// The worker isolate, started on the first job.
class SttWorker implements JobRunner {
  SttWorker({required this.onnxRuntimePath, this.log});

  /// onnxruntime.dll beside the app.
  final String onnxRuntimePath;

  /// One line to perf.log per job: time, outcome and memory.
  final void Function(String line)? log;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Future<void>? _starting;
  Future<void> _queue = Future.value();
  var _nextId = 0;
  final _tasks = <int, (WorkerTask<Object?>, String, Stopwatch)>{};

  /// Every task given and not ended, running or waiting.
  final _open = <WorkerTask<Object?>>{};

  /// Runs [job] on the worker after the jobs given before it.
  @override
  WorkerTask<R> run<R>(WorkerJob<R> job) {
    final task = WorkerTask<R>._(calloc<Int32>()..value = 0);
    _open.add(task);
    unawaited(
      task.result.then((_) {}, onError: (_) {}).whenComplete(() {
        _open.remove(task);
      }),
    );
    final id = _nextId++;
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    unawaited(() async {
      try {
        await previous;
        if (task._flag.value != 0) {
          task._result.completeError(const WorkerCancelled());
          task._end();
          return;
        }
        await _start();
        _tasks[id] = (task, job.name, Stopwatch()..start());
        try {
          _toWorker!.send([id, job, task._flag.address]);
        } on Object catch (error) {
          // A job holding something an isolate cannot take.
          _tasks.remove(id);
          task._result.completeError(WorkerJobError('$error'));
          task._end();
          return;
        }
        await task.result.then((_) {}, onError: (_) {});
      } finally {
        done.complete();
      }
    }());
    return task;
  }

  Future<void> _start() => _starting ??= () async {
    final port = ReceivePort();
    _fromWorker = port;
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message == null || message is List && message.length == 2) {
        // The isolate ended (onExit sends null) or failed outside a job
        // (onError sends [error, stack]): its jobs cannot end.
        _lost(message == null ? 'the worker stopped' : '${message[0]}');
        return;
      }
      _onMessage(message as List<Object?>);
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      (port.sendPort, onnxRuntimePath),
      debugName: 'hear the words',
      onExit: port.sendPort,
      onError: port.sendPort,
    );
    _toWorker = await ready.future;
  }();

  /// Fails every running job and lets the next job start a new isolate.
  void _lost(String reason) {
    for (final (task, _, _) in _tasks.values) {
      task._result.completeError(WorkerJobError(reason));
      task._end();
    }
    _tasks.clear();
    _isolate = null;
    _toWorker = null;
    _starting = null;
    _fromWorker?.close();
  }

  void _onMessage(List<Object?> message) {
    final id = message[0] as int;
    final entry = _tasks[id];
    if (entry == null) return;
    final (task, name, clock) = entry;
    switch (message[1]) {
      case 'progress':
        task._progress.add((
          stage: message[2] as String,
          done: message[3] as int,
          total: message[4] as int,
        ));
        return;
      case 'end':
        _tasks.remove(id);
        final outcome = message[2] as String;
        task._memory = message[4] as WorkerMemory;
        final memory = task._memory!;
        log?.call(
          'stt $name: $outcome in ${clock.elapsedMilliseconds} ms, peak '
          '${_mb(memory.peakWorkingSet)} MB (private '
          '${_mb(memory.peakPrivate)}), after ${_mb(memory.afterWorkingSet)} '
          'MB (private ${_mb(memory.afterPrivate)})',
        );
        switch (outcome) {
          // A result that comes after cancel() is not wanted any more:
          // the job ended between its last check and the message.
          case 'ok' when task._flag.value != 0:
            task._result.completeError(const WorkerCancelled());
          case 'ok':
            task._result.complete(message[3]);
          case 'cancelled':
            task._result.completeError(const WorkerCancelled());
          default:
            task._result.completeError(WorkerJobError(message[3] as String));
        }
        task._end();
    }
  }

  /// Stops the worker; a job running is cancelled at its next unit end
  /// and the isolate is killed after it.
  Future<void> close() async {
    for (final task in [..._open]) {
      task.cancel();
    }
    await _queue;
    final port = _fromWorker;
    _fromWorker = null;
    port?.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _toWorker = null;
    _starting = null;
  }
}

int _mb(int bytes) => (bytes / (1024 * 1024)).round();

void _workerMain((SendPort, String) start) {
  final (toMain, onnxPath) = start;
  final port = ReceivePort();
  toMain.send(port.sendPort);
  port.listen((message) {
    final [id as int, job as WorkerJob<Object?>, flag as int] =
        message as List<Object?>;
    final context = WorkerContext._(
      onnxPath,
      Pointer<Int32>.fromAddress(flag),
      (stage, done, total) => toMain.send([id, 'progress', stage, done, total]),
    );
    String outcome;
    Object? value;
    try {
      context.checkCancelled();
      value = job.run(context);
      outcome = 'ok';
    } on WorkerCancelled {
      outcome = 'cancelled';
    } catch (error) {
      outcome = 'error';
      value = '$error';
    } finally {
      context.freeModel();
    }
    final after = processMemory();
    final WorkerMemory memory = (
      peakWorkingSet: context._peakWorkingSet,
      peakPrivate: context._peakPrivate,
      afterWorkingSet: after?.workingSet ?? 0,
      afterPrivate: after?.private ?? 0,
    );
    toMain.send([id, 'end', outcome, value, memory]);
  });
}
