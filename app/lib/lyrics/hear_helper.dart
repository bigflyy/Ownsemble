/// "Hear the words" in a helper process (plan 10 I2i5): both ends of the
/// conversation between the app and ownsemble_hear.exe.
///
/// Why a second process: after a GPU run the DirectML and Vulkan drivers
/// stay loaded in the process that used them (about 640 MB against 225 MB
/// on the CPU, plan 10 I2i4). The helper ends after each song, so all of it
/// goes back; a driver crash or hang ends the helper, not the player; and
/// Stop can end the helper at once.
///
/// The conversation is lines of JSON, UTF-8, one message a line:
/// - app -> helper: `{"type":"job","id":N,"job":{...}}` and
///   `{"type":"cancel","id":N}`; closing the helper's input ends it.
/// - helper -> app: `{"type":"ready","version":V}` once, then
///   `{"type":"progress","id":N,"stage":S,"done":D,"total":T}`,
///   `{"type":"log","line":L}` and
///   `{"type":"end","id":N,"outcome":"ok|cancelled|error","value":X,
///   "memory":[...]}`.
///
/// Inside the helper the jobs run on today's [SttWorker] (its isolate and
/// native cancel flag), so the helper's main isolate stays free to read
/// a cancel or the end of its input while a job works.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hear_wire.dart';
import 'stt_worker.dart';

/// The version of the conversation; the app refuses a helper that says
/// another one (a helper left from an older build). 2: the karaoke
/// instrumental job (plan 11 D1d).
const hearHelperVersion = 2;

/// The helper's file name beside ownsemble.exe.
const hearHelperName = 'ownsemble_hear.exe';

// --- The helper's side --------------------------------------------------

/// Serves jobs from [lines] (the helper's input) until it ends, writing
/// each message with [write]. Returns when the input ends; the caller then
/// ends the process at once, which also ends a job still running.
/// [decodeJob] and [encodeResult] are the wire forms ([jobFromJson],
/// [resultToJson]); tests give their own jobs.
Future<void> serveHearJobs({
  required Stream<String> lines,
  required void Function(String line) write,
  required String onnxRuntimePath,
  String? gpuOnnxRuntimePath,
  WorkerJob<Object?> Function(Map<String, Object?> json) decodeJob =
      jobFromJson,
  Object? Function(String jobName, Object? result) encodeResult = resultToJson,
}) async {
  void send(Map<String, Object?> message) {
    try {
      write(jsonEncode(message));
    } on Object {
      // The app is gone: the input ends next and the helper with it.
    }
  }

  final worker = SttWorker(
    onnxRuntimePath: onnxRuntimePath,
    gpuOnnxRuntimePath: gpuOnnxRuntimePath,
    log: (line) => send({'type': 'log', 'line': 'helper $line'}),
  );
  final tasks = <int, WorkerTask<Object?>>{};

  void sendEnd(int id, WorkerTask<Object?>? task, String outcome, Object? v) {
    final memory = task?.memory;
    send({
      'type': 'end',
      'id': id,
      'outcome': outcome,
      'value': outcome == 'cancelled' ? null : v,
      'memory': memory == null ? null : memoryToJson(memory),
    });
  }

  send({'type': 'ready', 'version': hearHelperVersion});
  await for (final line in lines) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      send({'type': 'log', 'line': 'helper: a line that is not a message'});
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    final id = decoded['id'];
    if (id is! int) continue;
    switch (decoded['type']) {
      case 'cancel':
        tasks[id]?.cancel();
      case 'job':
        final WorkerJob<Object?> job;
        try {
          job = decodeJob(decoded['job'] as Map<String, Object?>);
        } on Object catch (error) {
          sendEnd(id, null, 'error', 'the helper cannot read the job: $error');
          continue;
        }
        final task = worker.run(job);
        tasks[id] = task;
        task.progress.listen(
          (progress) => send({
            'type': 'progress',
            'id': id,
            'stage': progress.stage,
            'done': progress.done,
            'total': progress.total,
          }),
        );
        unawaited(
          task.result
              .then<void>(
                (value) {
                  final Object? json;
                  try {
                    json = encodeResult(job.name, value);
                  } on Object catch (error) {
                    sendEnd(id, task, 'error', 'unsendable result: $error');
                    return;
                  }
                  sendEnd(id, task, 'ok', json);
                },
                onError: (Object error) => sendEnd(
                  id,
                  task,
                  error is WorkerCancelled ? 'cancelled' : 'error',
                  error is WorkerJobError ? error.message : '$error',
                ),
              )
              .whenComplete(() => tasks.remove(id)),
        );
    }
  }
  // The app closed the input (it is done, or gone): nothing more to do.
  for (final task in tasks.values) {
    task.cancel();
  }
  unawaited(worker.close());
}

// --- The app's side -----------------------------------------------------

/// Starts the helper: [Process.start] in the app (normal mode, so Windows
/// makes no console window for it), a fake in tests.
typedef StartHelper = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// Runs jobs in ownsemble_hear.exe ([JobRunner] for [HearWords]).
///
/// The helper starts with the first job. When it ends while jobs are open
/// (a crash, a driver that took it down, a kill) those jobs fail with a
/// [WorkerJobError] and the next job starts a new helper: a GPU stage that
/// failed that way runs again on the CPU in a fresh process. A helper that
/// would not start or speaks another version fails its jobs with
/// [WorkerUnavailable] instead (not a GPU fault). A job stopped with
/// [RunningJob.cancel] always ends as [WorkerCancelled], and only once the
/// job's code is done or its helper has really exited, so its files can be
/// touched after that.
class ProcessJobRunner implements JobRunner {
  ProcessJobRunner({
    required this.helperPath,
    required this.onnxRuntimePath,
    this.gpuOnnxRuntimePath,
    this.log,
    StartHelper? start,
    this.cancelGrace = const Duration(seconds: 3),
    this.closeGrace = const Duration(seconds: 5),
    this.readyTimeout = const Duration(seconds: 30),
    this.encodeJob = jobToJson,
    this.decodeResult = resultFromJson,
  }) : _startProcess = start ?? Process.start;

  /// ownsemble_hear.exe.
  final String helperPath;
  final String onnxRuntimePath;
  final String? gpuOnnxRuntimePath;

  /// perf.log: the helper's own lines and how it ended (never its raw
  /// output, which may hold words or paths).
  final void Function(String line)? log;

  /// How long a cancelled job may take to answer before the helper is
  /// ended (a job inside one long native call does not look at its flag).
  final Duration cancelGrace;

  /// How long [close] waits for the helper to end by itself.
  final Duration closeGrace;

  /// How long a new helper may take to say it is ready.
  final Duration readyTimeout;

  final StartHelper _startProcess;

  /// The wire forms ([jobToJson], [resultFromJson]); tests give their own.
  final Map<String, Object?> Function(WorkerJob<Object?> job) encodeJob;
  final Object? Function(String jobName, Object? json) decodeResult;

  _Helper? _helper;
  var _nextId = 0;

  /// The process ids of the helpers this app started that have not exited
  /// yet, for the real checks (none may be left after a run).
  static final runningPids = <int>{};

  @override
  RunningJob<R> run<R>(WorkerJob<R> job) {
    final task = _ProcessTask<R>(_nextId++, job.name);
    final Map<String, Object?> json;
    try {
      json = encodeJob(job);
    } on Object catch (error) {
      task._fail(WorkerJobError('$error'));
      return task;
    }
    final helper = _helper ??= _Helper(this);
    helper.send(task, json);
    return task;
  }

  /// Ends the helper: open jobs are cancelled, its input closed, and it is
  /// ended if it has not gone by itself within [closeGrace]. The memory it
  /// held is back once this returns.
  Future<void> close() async {
    final helper = _helper;
    _helper = null;
    await helper?.close();
  }

  void _log(String line) {
    try {
      log?.call(line);
    } on Object {
      // A lost log line never stops a job.
    }
  }
}

/// One running helper process and the jobs given to it.
class _Helper {
  _Helper(this.runner) {
    unawaited(_start());
  }

  final ProcessJobRunner runner;

  /// The process once it said it is ready; null when it never will.
  final _ready = Completer<Process?>();
  final _tasks = <int, _ProcessTask<Object?>>{};
  Process? _process;
  var _ended = false;
  var _stderrLines = 0;
  Timer? _readyTimer;

  /// Whether the helper said it is ready: before that, its end makes the
  /// jobs [WorkerUnavailable].
  bool get _wasReady => _ready.isCompleted && _process != null;

  Future<void> _start() async {
    final Process process;
    try {
      process = await runner._startProcess(runner.helperPath, [
        '--onnx',
        runner.onnxRuntimePath,
        if (runner.gpuOnnxRuntimePath case final gpu?) ...['--gpu-onnx', gpu],
      ]);
    } on Object catch (error) {
      _end('the helper would not start (${error.runtimeType})', ready: false);
      return;
    }
    _process = process;
    ProcessJobRunner.runningPids.add(process.pid);
    // A write to a helper that is gone fails here too, not only in flush.
    unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    runner._log('hear helper: started, pid ${process.pid}');
    _readyTimer = Timer(runner.readyTimeout, () {
      if (_ready.isCompleted) return;
      runner._log(
        'hear helper: not ready in ${runner.readyTimeout.inSeconds} s, ended',
      );
      process.kill();
    });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object _) {});
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) => _stderrLines++, onError: (Object _) {});
    unawaited(
      process.exitCode.then((code) {
        ProcessJobRunner.runningPids.remove(process.pid);
        runner._log(
          'hear helper: pid ${process.pid} ended, exit code $code'
          '${_stderrLines == 0 ? '' : ', $_stderrLines stderr lines'}',
        );
        _end('the helper ended (exit code $code)', ready: _wasReady);
      }),
    );
  }

  void send(_ProcessTask<Object?> task, Map<String, Object?> job) {
    if (_ended) {
      task._fail(const WorkerUnavailable('the helper ended'));
      return;
    }
    task._helper = this;
    _tasks[task.id] = task;
    _write({'type': 'job', 'id': task.id, 'job': job});
  }

  /// Asks the helper to stop [task]; ends the helper when the job has not
  /// ended within the grace time (counted from now, start included).
  void cancel(_ProcessTask<Object?> task) {
    if (_ended || !_tasks.containsKey(task.id)) return;
    _write({'type': 'cancel', 'id': task.id});
    task._killTimer ??= Timer(runner.cancelGrace, () {
      if (!_tasks.containsKey(task.id)) return;
      runner._log(
        'hear helper: ${task.name} did not stop in '
        '${runner.cancelGrace.inMilliseconds} ms, ended',
      );
      _kill();
    });
  }

  /// Messages wait for the helper to be ready, in order.
  Future<void> _writing = Future.value();

  void _write(Map<String, Object?> message) {
    final line = jsonEncode(message);
    _writing = _writing.then((_) async {
      final process = await _ready.future;
      if (_ended || process == null) return;
      try {
        process.stdin.writeln(line);
        await process.stdin.flush();
      } on Object {
        // The helper is gone; its exit fails the open jobs.
      }
    }, onError: (Object _) {});
  }

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      // Something a native library printed: never a message, never shown
      // (it may hold a path or words).
      runner._log('hear helper: skipped ${line.length} chars of other output');
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message['type']) {
      case 'ready':
        if (_ready.isCompleted) return;
        final version = message['version'];
        if (version != hearHelperVersion) {
          runner._log(
            'hear helper: version $version, the app speaks '
            '$hearHelperVersion: ended',
          );
          _kill();
          return;
        }
        _readyTimer?.cancel();
        _ready.complete(_process);
      case 'log':
        runner._log('${message['line']}');
      case 'progress':
        _tasks[message['id']]?._progress.add((
          stage: message['stage'] as String,
          done: message['done'] as int,
          total: message['total'] as int,
        ));
      case 'end':
        final task = _tasks.remove(message['id']);
        if (task == null) return;
        final memory = message['memory'];
        if (memory != null) task.memory = memoryFromJson(memory);
        switch (message['outcome']) {
          case 'ok' when task._cancelled:
            task._fail(const WorkerCancelled());
          case 'ok':
            final Object? value;
            try {
              value = runner.decodeResult(task.name, message['value']);
            } on Object catch (error) {
              task._fail(WorkerJobError('unreadable result: $error'));
              return;
            }
            task._complete(value);
          case 'cancelled':
            task._fail(const WorkerCancelled());
          default:
            task._fail(WorkerJobError('${message['value']}'));
        }
    }
  }

  /// The helper is gone (or never came): every open job ends. A job the
  /// user cancelled ends as cancelled; any other fails, as
  /// [WorkerUnavailable] when the helper never got [ready].
  void _end(String reason, {required bool ready}) {
    if (_ended) return;
    _ended = true;
    _readyTimer?.cancel();
    // The next job starts a new helper; dropped before the jobs fail, so a
    // retry they start never reaches this one.
    if (identical(runner._helper, this)) runner._helper = null;
    if (!_ready.isCompleted) _ready.complete(null);
    final open = [..._tasks.values];
    _tasks.clear();
    for (final task in open) {
      task._fail(
        task._cancelled
            ? const WorkerCancelled()
            : ready
            ? WorkerJobError(reason)
            : WorkerUnavailable(reason),
      );
    }
  }

  void _kill() => _process?.kill();

  Future<void> close() async {
    for (final task in [..._tasks.values]) {
      task.cancel();
    }
    final process = await _ready.future;
    if (process == null) {
      // Never ready: started but silent, or not started at all.
      final started = _process;
      if (started != null) {
        started.kill();
        await started.exitCode;
      }
      return;
    }
    await _writing;
    try {
      await process.stdin.close();
    } on Object {
      // Already gone.
    }
    final ended = await process.exitCode
        .then<bool>((_) => true)
        .timeout(runner.closeGrace, onTimeout: () => false);
    if (!ended) {
      runner._log(
        'hear helper: did not end in ${runner.closeGrace.inMilliseconds} '
        'ms after its input closed, ended',
      );
      process.kill();
      await process.exitCode;
    }
  }
}

/// A job given to the helper.
class _ProcessTask<R> implements RunningJob<R> {
  _ProcessTask(this.id, this.name);

  final int id;
  final String name;
  final _result = Completer<R>();
  final _progress = StreamController<WorkerProgress>.broadcast(sync: true);
  _Helper? _helper;
  Timer? _killTimer;
  var _cancelled = false;

  /// Memory of the helper during and after the job, when it told it.
  WorkerMemory? memory;

  @override
  Future<R> get result => _result.future;

  @override
  Stream<WorkerProgress> get progress => _progress.stream;

  @override
  void cancel() {
    if (_result.isCompleted || _cancelled) return;
    _cancelled = true;
    _helper?.cancel(this);
  }

  void _complete(Object? value) {
    if (_result.isCompleted) return;
    _result.complete(value as R);
    _finish();
  }

  void _fail(Object error) {
    if (_result.isCompleted) return;
    _result.completeError(error);
    _finish();
  }

  void _finish() {
    _killTimer?.cancel();
    unawaited(_progress.close());
  }
}
