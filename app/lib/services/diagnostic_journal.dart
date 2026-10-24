import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../media/audio_policy.dart';
import 'diagnostic_schema.dart';

/// Keep bounded, privacy-filtered evidence independently of filesystem latency.
class DiagnosticJournal {
  // Carry one operation through asynchronous callbacks without using recording IDs.
  static final _operationZone = Object();
  // Keep only supported platform families, never machine names or system paths.
  final String platform;
  // Identify the compiled revision when the build supplies one; never infer it from disk.
  final String buildRevision;
  // Separate attempt numbers across application restarts without identifying an account.
  final String runId = List.generate(
    16,
    (_) => Random.secure().nextInt(16).toRadixString(16),
  ).join();
  // Measure event offsets with a monotonic clock rather than wall-clock differences.
  final Stopwatch _clock = Stopwatch()..start();
  // Bound the recent timeline independently from retained failure snapshots.
  final List<Map<String, Object>> _events = [];
  // Keep a bounded index of recent operation summaries.
  final List<_DiagnosticOperation> _operations = [];
  // Preserve failures even when background events fill the ordinary timeline.
  final List<Map<String, Object>> _failures = [];
  // Allocate process-local operation identifiers without track or provider identifiers.
  int _nextOperation = 0;
  // Order events even when several arrive during the same millisecond.
  int _nextEvent = 0;
  // Record the actual bundled adapter digest after its public source has loaded.
  String? _adapterDigest;

  /// Validate environment labels before they enter persisted diagnostic reports.
  DiagnosticJournal({
    String platform = 'unknown',
    String buildRevision = 'unlabelled',
  }) : platform =
           const {
             'windows',
             'linux',
             'android',
             'ios',
             'macos',
             'unknown',
           }.contains(platform)
           ? platform
           : 'unknown',
       buildRevision =
           RegExp(r'^[a-f0-9]{7,40}(?:-dirty)?$').hasMatch(buildRevision)
           ? buildRevision
           : 'unlabelled';

  /// Trace an asynchronous application operation without changing its result or exception.
  Future<T> run<T>(String kind, Future<T> Function() action) async {
    // Accept only fixed kinds so callers cannot smuggle track names into operation IDs.
    final safeKind =
        const {'playback', 'sync', 'metadata', 'connection'}.contains(kind)
        ? kind
        : 'operation';
    // Keep a direct operation object alive even when its summary leaves the recent index.
    final operation = _DiagnosticOperation(
      this,
      '$safeKind-${++_nextOperation}',
      safeKind,
    );
    _operations.add(operation);
    // Bound the summary index; in-flight zone contexts remain independently valid.
    if (_operations.length > 12) _operations.removeAt(0);
    return runZoned(() async {
      record({'stage': 'operation_started'});
      try {
        return await action();
      } catch (error) {
        record({
          'stage': 'operation_failed',
          'category': categoryOf(error),
          if (error is ProofFailure && error.code != null) 'code': error.code!,
        });
        rethrow;
      } finally {
        record({'stage': 'operation_finished'});
      }
    }, zoneValues: {_operationZone: operation});
  }

  /// Add only schema-approved primitives, with a correlation ID owned by this journal.
  void record(Map<String, Object> report) {
    // Filter before retaining anything so private data never enters the event ring.
    final safe = sanitizeDiagnosticEvent(report);
    // Resolve only this journal's zone context; ignore foreign or caller-supplied IDs.
    final candidate = Zone.current[_operationZone];
    // Keep unscoped background events distinct from a foreground playback request.
    final operation =
        candidate is _DiagnosticOperation && identical(candidate.owner, this)
        ? candidate
        : null;
    // Generate public event metadata locally rather than trusting imported timestamps.
    final event = <String, Object>{
      'sequence': ++_nextEvent,
      'offset_ms': _clock.elapsedMilliseconds,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'operation_id': operation?.id ?? 'background',
      ...safe,
    };
    _events.add(event);
    // Keep the event ring bounded when scans or retries emit many observations.
    if (_events.length > 64) _events.removeAt(0);
    // Keep the digest only when schema validation accepted the complete hash.
    if (safe['adapter_sha256'] is String) {
      _adapterDigest = safe['adapter_sha256'] as String;
    }
    operation?.observe(event);
    // Preserve a distinct failure snapshot without losing its preceding operation context.
    if (diagnosticEventIsFailure(safe)) {
      // Reuse the operation key so follow-up symptoms cannot fill every failure slot.
      final id = operation?.id ?? 'background-${event['sequence']}';
      // Retain the first cause while appending later native/cleanup symptoms to its context.
      final previous = _failures
          .where(
            (failure) =>
                failure['run_id'] == runId && failure['operation_id'] == id,
          )
          .firstOrNull;
      // Preserve the original category through generic relay/native follow-up errors.
      final category =
          previous?['category'] as String? ?? safe['category'] as String;
      // Enrich a missing code only when the later observation describes the same cause.
      final code =
          previous?['code'] ??
          (category == safe['category'] ? safe['code'] : null);
      _failures.removeWhere(
        (failure) =>
            failure['run_id'] == runId && failure['operation_id'] == id,
      );
      _failures.add({
        'run_id': runId,
        'operation_id': id,
        'build_revision': buildRevision,
        'updatedAt': event['updatedAt']!,
        'category': category,
        'area': diagnosticFailureArea(category, operation?.phase),
        'code': ?code,
        'adapter_sha256': ?_adapterDigest,
        'events': [
          for (final item in operation?.events ?? [event])
            Map<String, Object>.of(item),
        ],
      });
      // Retain at most four failures across current and previous runs.
      if (_failures.length > 4) _failures.removeAt(0);
    }
  }

  /// Restore only bounded, revalidated failures from this application's previous report.
  void restoreFailures(Object? previous) {
    // Reject incompatible or malformed optional diagnostic files without affecting startup.
    if (previous is! Map ||
        previous['schema_version'] != 1 ||
        previous['failures'] is! List) {
      return;
    }
    // Collect older failures before any failures already emitted by this run.
    final restored = <Map<String, Object>>[];
    for (final item
        in (previous['failures'] as List).reversed.take(4).toList().reversed) {
      // Import no arbitrary objects, raw messages or unbounded lists.
      if (item is! Map ||
          item['events'] is! List ||
          item['run_id'] is! String ||
          !RegExp(r'^[a-f0-9]{16}$').hasMatch(item['run_id'] as String) ||
          item['operation_id'] is! String ||
          !RegExp(
            r'^(?:playback|sync|metadata|connection|operation|background)-\d{1,12}$',
          ).hasMatch(item['operation_id'] as String)) {
        continue;
      }
      // Re-sanitize each historical event; never trust a previously written file blindly.
      final events = <Map<String, Object>>[
        for (final event
            in (item['events'] as List).reversed.take(12).toList().reversed)
          if (event is Map) sanitizeDiagnosticEvent(event),
      ];
      // Recompute the area from a registered category rather than importing free text.
      final category = safeDiagnosticCategory(item['category']);
      // Normalize historical timestamps instead of trusting arbitrary stored text.
      final observed =
          item['updatedAt'] is String &&
              (item['updatedAt'] as String).length <= 40
          ? DateTime.tryParse(item['updatedAt'] as String)
          : null;
      restored.add({
        'run_id': item['run_id'] as String,
        'operation_id': item['operation_id'] as String,
        'category': category,
        if (observed != null) 'updatedAt': observed.toUtc().toIso8601String(),
        if (item['adapter_sha256'] is String &&
            RegExp(r'^[a-f0-9]{64}$')
                .hasMatch(item['adapter_sha256'] as String))
          'adapter_sha256': item['adapter_sha256'] as String,
        'area': diagnosticFailureArea(
          category,
          events.where((event) => event['phase'] is String).lastOrNull?['phase']
              as String?,
        ),
        'build_revision': DiagnosticJournal(
          buildRevision: item['build_revision'] is String
              ? item['build_revision'] as String
              : '',
        ).buildRevision,
        if (item['code'] is int && (item['code'] as int).abs() <= 2147483648)
          'code': item['code'] as int,
        'events': events,
      });
    }
    _failures.insertAll(0, restored);
    // Prefer the most recent evidence when restoring a full failure history.
    while (_failures.length > 4) {
      _failures.removeAt(0);
    }
  }

  /// Return a bounded standalone report; callers cannot mutate retained event state.
  Map<String, Object> snapshot() {
    // Assemble only known report fields from already-filtered event data.
    final report = <String, Object>{
      'schema_version': 1,
      'run_id': runId,
      'platform': platform,
      'build_revision': buildRevision,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'adapter_sha256': ?_adapterDigest,
      'events': _events,
      'operations': [for (final operation in _operations) operation.summary()],
      'failures': _failures,
    };
    // Copy only at export time, keeping the hot event path free of serialization.
    final copy = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
    // Bound exported bytes even when every allowed metric appears in every event.
    final events = copy['events'] as List;
    while (jsonEncode(copy).length > 196000 && events.length > 1) {
      events.removeAt(0);
    }
    // Trim old failure context before discarding a failure's category and area.
    final failures = copy['failures'] as List;
    for (final failure in failures) {
      while (jsonEncode(copy).length > 196000 &&
          (failure['events'] as List).length > 1) {
        (failure['events'] as List).removeAt(0);
      }
    }
    return Map<String, Object>.from(copy);
  }
}

/// Keep one attempt's bounded context separate from unrelated background activity.
class _DiagnosticOperation {
  // Resolve ownership before accepting a zone context from another journal.
  final DiagnosticJournal owner;
  // Use a process-local sequence instead of a recording/account identifier.
  final String id;
  // Distinguish foreground playback, sync and other application operations.
  final String kind;
  // Retain only the last twelve safe events for this attempt.
  final List<Map<String, Object>> events = [];
  // Remember the last observed stage for failure triage.
  String? phase;
  // Record whether the operation emitted a failure before finishing.
  String status = 'running';

  /// Construct an operation without native, provider or filesystem dependencies.
  _DiagnosticOperation(this.owner, this.id, this.kind);

  /// Update the attempt summary without changing another attempt's ownership.
  void observe(Map<String, Object> event) {
    events.add(event);
    // Bound per-attempt context even during a long provider timeout.
    if (events.length > 12) events.removeAt(0);
    // Keep the native startup phase when subsequent provider events have no phase.
    if (event['phase'] is String) phase = event['phase'] as String;
    // Preserve failures through later completion/cleanup events.
    if (diagnosticEventIsFailure(event)) status = 'failed';
    // A completed callback does not by itself prove successful audio playback.
    if (event['stage'] == 'operation_finished' && status != 'failed') {
      status = 'finished';
    }
  }

  /// Export only a fixed summary, leaving detailed evidence in bounded event lists.
  Map<String, Object> summary() => {
    'operation_id': id,
    'kind': kind,
    'status': status,
    'phase': ?phase,
  };
}
