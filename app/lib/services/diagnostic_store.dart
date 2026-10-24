import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diagnostic_journal.dart';

/// Persist bounded diagnostics in coalesced asynchronous writes outside playback.
class DiagnosticStore {
  // Restrict storage to the application-owned report directory supplied by composition.
  final Directory directory;
  // Keep event collection independent from the optional filesystem sink.
  final DiagnosticJournal journal;
  // Substitute a controlled slow/failing sink in generated tests.
  final Future<void> Function(String, String)? _writeOverride;
  // Restore only the previous bounded application report, never browser or catalog data.
  late final Future<void> ready;
  // Coalesce many events into one pending flush.
  Timer? _timer;
  // Allow at most one physical write batch at a time.
  Future<void>? _flushing;
  // Remember events arriving while a write is in progress without queueing more writes.
  bool _dirty = false;
  // Stop scheduling timers once the application is shutting down.
  bool _closed = false;
  // Expose only a counter when the optional diagnostic destination fails.
  int writeFailures = 0;

  /// Begin bounded recovery without awaiting disk I/O in the application constructor.
  DiagnosticStore(
    this.directory,
    this.journal, {
    Future<void> Function(String, String)? write,
  }) : _writeOverride = write {
    ready = _restore();
  }

  /// Collect generated widget-test evidence without scheduling real filesystem work.
  DiagnosticStore.memory()
    : directory = Directory(''),
      journal = DiagnosticJournal(),
      _writeOverride = _discard {
    ready = Future.value();
  }

  /// Finish an in-memory diagnostic batch without touching application files.
  static Future<void> _discard(String name, String contents) async {}

  /// Ignore missing, oversized or corrupt diagnostic files during ordinary startup.
  Future<void> _restore() async {
    try {
      // Open only this application's fixed diagnostic filename.
      final file = File('${directory.path}/diagnostics.json');
      // Reject oversized evidence before reading or parsing its body.
      if (!await file.exists() || await file.length() > 196608) return;
      journal.restoreFailures(jsonDecode(await file.readAsString()));
    } catch (_) {
      /* Optional diagnostics must never block application startup. */
    }
  }

  /// Mark new evidence without serialization, filesystem access or an awaited future.
  void changed() {
    // Leave already-closing stores and active/queued batches untouched.
    if (_closed) return;
    _dirty = true;
    // Keep one timer or one in-flight batch regardless of event volume.
    if (_timer != null || _flushing != null) return;
    _timer = Timer(const Duration(milliseconds: 250), () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Atomically replace a fixed application-owned report, without writing private content.
  Future<void> _write(String name, String contents) async {
    // A generated sink can model a full/slow disk without filesystem side effects.
    if (_writeOverride != null) {
      await _writeOverride(name, contents);
      return;
    }
    await directory.create(recursive: true);
    // Write one temporary file beside its destination before replacing the report.
    final temporary = File('${directory.path}/$name.tmp');
    await temporary.writeAsString(contents);
    await temporary.rename('${directory.path}/$name');
  }

  /// Flush at most one batch, coalescing changes received while the sink is blocked.
  Future<void> flush() {
    // Share an active batch instead of accumulating a future chain per event.
    if (_flushing != null) return _flushing!;
    _timer?.cancel();
    _timer = null;
    // Schedule asynchronously so the field is assigned before the batch can complete.
    final batch = Future<void>.microtask(() async {
      await ready;
      // Leave an unchanged store alone, including a newly opened application.
      if (!_dirty) return;
      _dirty = false;
      try {
        // Serialize the bounded snapshot once per batch, outside the event hot path.
        final report = journal.snapshot();
        report['write_failures'] = writeFailures;
        await _write('diagnostics.json', jsonEncode(report));
        // Preserve fixed legacy filenames for existing sanitized tooling.
        final events = (report['events'] as List).cast<Map>();
        await _write(
          'audio-diagnostics.json',
          jsonEncode({
            if (events.isNotEmpty) ...events.last,
            'events': events.reversed.take(40).toList().reversed.toList(),
          }),
        );
        // Retain the latest safe binding shape independently from the noisy event ring.
        final binding = events
            .where((event) => event['stage'] == 'music_binding')
            .lastOrNull;
        // Avoid replacing an existing binding report when this batch contains none.
        if (binding != null) {
          await _write('source-binding.json', jsonEncode(binding));
        }
      } catch (_) {
        writeFailures++;
      }
    });
    _flushing = batch.whenComplete(() {
      _flushing = null;
      // Schedule only one follow-up batch if new events arrived during this write.
      if (_dirty && !_closed) changed();
    });
    return _flushing!;
  }

  /// Produce a fresh standalone artifact only for a validated fixed control request.
  Future<void> exportReport(String reportId) async {
    // Reject caller-supplied paths or arbitrary identifiers before touching the filesystem.
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(reportId)) {
      throw ArgumentError('Invalid report identifier');
    }
    await flush();
    // Export only the current safe snapshot, never arbitrary existing report contents.
    final report = journal.snapshot();
    report['report_id'] = reportId;
    report['write_failures'] = writeFailures;
    await _write('diagnostics-report.json', jsonEncode(report));
  }

  /// Drain the latest optional evidence without keeping a periodic writer alive.
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await flush();
    // Include changes that arrived during an earlier in-flight batch.
    if (_dirty) await flush();
  }
}
