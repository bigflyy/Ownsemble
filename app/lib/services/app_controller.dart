import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/library_store.dart';
import '../media/audio_cache.dart';
import '../media/audio_policy.dart';
import '../media/artwork_cache.dart';
import '../contracts/playback_engine.dart';
import '../contracts/app_runtime.dart';
import '../contracts/certificate_verifier.dart';
import 'async_wait.dart';
import '../media/streaming_audio.dart';
import '../contracts/music_provider.dart';
import '../provider/cached_source_witness.dart';
import 'playback_queue.dart';
import 'sync_activity.dart';

import 'runtime_diagnostics.dart';
import 'diagnostic_journal.dart';
import 'diagnostic_store.dart';

class AppController extends ChangeNotifier {
  final LibraryStore store;
  final bool demo;
  final Duration startupTimeout;
  final Duration metadataTimeout;
  final bool enableLocalControls;
  final PlaybackEngine player;
  final MusicProvider provider;
  final AudioDecoder decodeAudio;
  final AppRuntime runtime;
  final CertificateVerifier Function() certificateVerifierFactory;
  final queue = PlaybackQueue();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _tick, _scheduler;
  bool offline = false,
      syncing = false,
      disposed = false,
      connecting = false,
      loading = false;
  bool _continueSweep = false;
  int _syncGeneration = 0;
  int _connectionGeneration = 0;
  SyncActivity? _syncActivity;
  String? connectionError;

  /// Restore only completed results; background work never restores as active.
  SyncActivity get syncActivity =>
      _syncActivity ??= SyncActivity.restore(store.setting('last_sync_result'));

  void _saveSyncActivity(SyncActivity activity) {
    _syncActivity = activity;
    store.setSetting('last_sync_result', activity.toJson());
  }

  /// Include scheduled full-scan slices so cancellation remains available between them.
  bool get syncPending => syncing || _continueSweep;

  /// Invalidate late merge/completion callbacks before closing the provider.
  void _cancelSyncActivity({bool includeContinuation = false}) {
    final cancel = syncing || (includeContinuation && _continueSweep);
    ++_syncGeneration;
    _continueSweep = false;
    if (!cancel) return;
    if (store.setting('initial_sync_pending', false) == true) {
      store.setSetting('initial_sync_paused', true);
    }
    _saveSyncActivity(
      SyncActivity(
        phase: 'cancelled',
        mode: syncActivity.mode,
        checked: syncActivity.checked,
        added: syncActivity.added,
        finishedAt: DateTime.now(),
        reason: 'cancelled',
      ),
    );
    _nextSync = DateTime.now().add(const Duration(minutes: 2));
  }

  /// Stop enumeration alone; the selected audio resolver uses a separate port.
  Future<void> cancelSync() async {
    if (!syncPending || syncActivity.phase == 'cancelled') return;
    _cancelSyncActivity(includeContinuation: true);
    _notify(library: false);
    await provider.cancelSync();
  }

  /// Disable automatic reconnection while retaining private sign-in and local data.
  Future<void> disconnectVk() async {
    setAutoSync(false);
    await setOffline(true);
  }

  String message = 'Your music, in your own order.',
      view = 'library',
      query = '';
  int? pileId;
  String? downloadId;
  String? downloadStage;
  String get downloadLabel => switch (downloadStage) {
    'finding_source' => 'Finding source',
    'receiving' =>
      downloadBytes == 0
          ? 'Waiting for audio'
          : downloadBytes < 1048576
          ? '${(downloadBytes / 1024).ceil()} KB received'
          : '${(downloadBytes / 1048576).toStringAsFixed(1)} MB received',
    'materializing' => 'Preparing audio',
    'decoding' => 'Validating complete audio',
    'publishing' => 'Saving offline',
    _ => '',
  };
  int downloadBytes = 0;
  int _request = 0, _cancelDownload = 0;
  // Wake selected-source waits immediately when their download generation expires.
  final _downloadCancellations = StreamController<void>.broadcast(sync: true);
  int _nativeErrors = 0;
  String? _lastNativeCategory;
  int _nativeSignals = 0;
  Map<String, Object> _sourceTimings = {};
  int? _playEvent;
  int _listened = 0, _lastSave = 0;
  bool _wasPlaying = false;
  final _clock = Stopwatch()..start();
  Duration _lastTick = Duration.zero;
  DateTime _nextSync = DateTime.now();
  DateTime _nextPinAttempt = DateTime.now();
  bool _restartRequested = false,
      _acceptanceRequested = false,
      _checking = false;
  final Map<String, Future<CachedAudio>> _downloads = {};
  final _streams = <String, StreamingAudio>{};
  final _streamReady = <String, Completer<StreamingAudio>>{};
  String? _playingStream;
  String? _checkingTrack;
  Future<void>? _checkTask;
  // Retain one in-memory identity so normal/shuffle probes compare the same recording.
  String? _queueStartupTarget;
  Completer<void>? _checkCancelled;
  String? _checkCancelReason;
  int? _checkGeneration;
  Future<void> _downloadTail = Future.value();
  List<LibraryRow>? _rowCache;
  // Bound per-recording display lookups independently of total library/queue size.
  static const _displayCacheLimit = 512;
  // Reuse selected/visible recording metadata between playback-clock updates.
  final _displayTracks = <String, Track?>{};
  // Keep individual pin intent separate from aggregate Pile protection.
  final _displayPins = <String, bool>{};
  // Cache nullable cover keys while keeping file-existence checks in the artwork cache.
  final _displayArtworkKeys = <String, String?>{};
  // Reuse sidebar Piles until a library operation changes their names or counts.
  List<Pile>? _displayPiles;
  // Reuse the aggregate count between catalog mutations.
  int? _displayLibraryCount;
  List<LibraryRow>? _oldAudioSample;
  AudioCache? _activeCache;
  // Correlate safe provider/media events without storing recording or account identifiers.
  late final DiagnosticJournal diagnostics;
  // Persist evidence asynchronously so filesystem latency cannot hold up Play.
  late final DiagnosticStore _diagnosticStore;
  late final ArtworkCache artwork;
  final _artworkTasks = <String, Future<void>>{};
  final _artworkDemand = <String, Map<Object, int>>{};
  final _visibleMetadataTasks = <String, Completer<void>>{};
  final _visibleMetadataQueue = <String>[];
  bool _visibleMetadataWorking = false;
  final _metadataTasks = <String, Future<void>>{};
  final _artworkRetry = <String, DateTime>{};
  late double _volumeLevel, _unmutedVolume;
  late Future<void> _volumeTail;
  double get volumeLevel => _volumeLevel;
  bool get muted => _volumeLevel == 0;
  final metadataErrors = <String, String>{};
  Future<Map<String, Object>>? _recordingRepair;
  AppController(
    this.store, {
    this.demo = false,
    this.startupTimeout = const Duration(seconds: 30),
    this.metadataTimeout = const Duration(seconds: 45),
    this.enableLocalControls = false,
    required PlaybackEngine playbackPlayer,
    required MusicProvider musicProvider,
    required this.decodeAudio,
    this.runtime = const UnsupportedAppRuntime(),
    this.certificateVerifierFactory = strictCertificateVerifier,
    ArtworkCache? artworkCache,
    DiagnosticStore? diagnosticStore,
  }) : player = playbackPlayer,
       provider = musicProvider {
    diagnostics =
        diagnosticStore?.journal ??
        DiagnosticJournal(
          platform: Platform.operatingSystem,
          buildRevision: const String.fromEnvironment(
            'OWNSEMBLE_BUILD_REVISION',
          ),
        );
    _diagnosticStore =
        diagnosticStore ?? DiagnosticStore(store.directory, diagnostics);
    artwork =
        artworkCache ??
        ArtworkCache(
          Directory('${store.directory.path}/artwork'),
          certificateVerifier: certificateVerifierFactory(),
          networkAllowed: () => !disposed && !offline,
        );
    offline = store.setting('offline', false) == true;
    queue.restore(store.setting('queue'));
    double savedVolume(String key, double fallback) {
      final saved = store.setting(key, fallback);
      return saved is num && saved.isFinite
          ? saved.toDouble().clamp(0, 100)
          : fallback;
    }

    _volumeLevel = savedVolume('volume', 75);
    _unmutedVolume = _volumeLevel > 0
        ? _volumeLevel
        : savedVolume('unmuted_volume', 75);
    if (_unmutedVolume == 0) _unmutedVolume = 75;
    _volumeTail = player.setVolume(_volumeLevel);
    _subscriptions.add(
      player.stream.playing.listen((playing) {
        _recordListening();
        _wasPlaying = playing && !player.state.buffering && !loading;
        if (!playing) _flushListening();
        if (!loading && _playEvent != null) {
          message = playing ? 'Playing' : 'Paused';
        }
        _notify(library: !playing);
      }),
    );
    _subscriptions.add(
      player.stream.buffering.listen((buffering) {
        _recordListening();
        _wasPlaying = player.state.playing && !buffering && !loading;
        _notify(library: false);
      }),
    );
    _subscriptions.add(
      player.stream.position.listen((_) => _notify(library: false)),
    );
    _subscriptions.add(
      player.stream.completed.listen((done) {
        if (done && !disposed && !loading && _playEvent != null) {
          unawaited(next(automatic: true));
        }
      }),
    );
    _subscriptions.add(
      player.stream.error.listen((error) {
        ++_nativeErrors;
        _lastNativeCategory = classifyDecoderFailure(error);
        _nativeSignals |= decoderSignalMask(error);
        message = 'Playback failed. Try this track again.';
        _notify();
      }),
    );
    _subscriptions.add(
      player.stream.log.listen((entry) {
        if (entry.level == 'error' || entry.level == 'fatal') {
          _lastNativeCategory = classifyDecoderFailure(
            entry.text,
            _lastNativeCategory,
          );
          _nativeSignals |= decoderSignalMask(entry.text);
        }
      }),
    );
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordListening();
      _reportPlayerState();
    });
    _scheduler = Timer.periodic(const Duration(seconds: 2), (_) => _schedule());
  }
  void providerStatus(String text) {
    // Provider progress belongs to connection/sync controls, never the audio footer.
    _notify(library: false);
  }

  void providerChanged() => _notify();

  /// Request optional provider diagnostics without importing or selecting music.
  Future<void> inspectLibraryMembership() async {
    // Use a capability interface so other providers need no diagnostic stub.
    final inspector = provider;
    // Leave providers without this optional capability untouched.
    if (inspector is! LibraryMembershipDiagnostics) return;
    try {
      await (inspector as LibraryMembershipDiagnostics)
          .inspectLibraryMembership();
    } catch (error, stack) {
      // Keep private-access failures inside the existing sanitized error path.
      _failure(error, stack: stack);
    }
  }

  void providerDiagnostic(Map<String, Object> report) =>
      _writeAudioDiagnostic(report);

  /// Collect existing safe evidence without probing pages, scanning or downloading.
  Future<void> writeDiagnosticReport(String reportId) async {
    // Freeze the selected metadata before comparing locally observed listing identities.
    final selection = current;
    // Count lookalikes only among identities observed by this provider session.
    final listed = selection == null
        ? <Track>[]
        : store
              .rows(view: 'vk')
              .map((row) => row.track)
              .where((track) => provider.libraryPosition(track.id) != null)
              .toList();

    /// Compare display metadata for diagnosis only, never to bind or replace a recording.
    String normalized(String value) =>
        value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    // Retain title matches internally without exporting their content or recording identities.
    final sameTitle = selection == null
        ? <Track>[]
        : listed
              .where(
                (track) =>
                    normalized(track.title) == normalized(selection.title),
              )
              .toList();
    // Separate other performers and versions without selecting a substitute automatically.
    final sameArtistTitle = selection == null
        ? <Track>[]
        : sameTitle
              .where(
                (track) =>
                    normalized(track.artist) == normalized(selection.artist),
              )
              .toList();
    _writeAudioDiagnostic({
      'stage': 'runtime_context',
      'offline': offline,
      'private_signin_active': provider.privateSignInActive,
      'provider_connected': provider.connected,
      'loading': loading,
      'playing': player.state.playing,
      'buffering': player.state.buffering,
      'cached': current != null && store.asset(current!.id) != null,
      'received_bytes': downloadBytes,
      'scanning': syncing,
      if (selection != null) ...{
        'selection_listed': provider.libraryPosition(selection.id) != null,
        'same_title_listed': sameTitle.length,
        'same_artist_title_listed': sameArtistTitle.length,
        'same_metadata_duration_listed': sameArtistTitle
            .where((track) => track.duration == selection.duration)
            .length,
      },
    });
    await _diagnosticStore.exportReport(reportId);
  }

  /// Record schema-approved evidence in memory and coalesce its optional disk writes.
  void _writeAudioDiagnostic(Map<String, Object> report) {
    if (disposed) return;
    diagnostics.record(report);
    _diagnosticStore.changed();
  }

  /// Read the selected identity through the same bounded cache as queue display rows.
  Track? get current {
    // Capture the current occurrence once so cursor changes cannot reuse another recording.
    final entry = queue.current;
    // Keep an empty queue independent of database reads.
    if (entry == null) return null;
    return displayTrack(entry.id);
  }

  /// Reuse one immutable display value while bounding lookups for distant scroll jumps.
  Value _displayValue<Value>(
    Map<String, Value> cache,
    String id,
    Value Function() read,
  ) {
    // Treat a cached null as a completed lookup rather than querying missing records every frame.
    if (cache.containsKey(id)) return cache[id] as Value;
    // Evict the oldest lookup before retaining another visible recording.
    if (cache.length >= _displayCacheLimit) cache.remove(cache.keys.first);
    return cache[id] = read();
  }

  /// Resolve only visible queue metadata and invalidate it with ordinary library changes.
  Track? displayTrack(String id) =>
      _displayValue(_displayTracks, id, () => store.track(id));

  /// Read individual download intent without issuing SQL during every row rebuild.
  bool individuallyPinned(String id) =>
      _displayValue(_displayPins, id, () => store.individuallyPinned(id));

  /// Read the full catalog count once per library mutation, independent of the active filter.
  int get libraryCount => _displayLibraryCount ??= store.count;
  List<LibraryRow> get rows => _rowCache ??= _libraryRows();
  List<LibraryRow> _libraryRows() {
    final source = store.rows(view: view, query: query, pile: pileId);
    if (demo) return source;
    final verified = store.verifiedAssetIds();
    return [
      for (final row in source)
        if (view != 'offline' || verified.contains(row.track.id))
          row.offline && !verified.contains(row.track.id)
              ? LibraryRow(
                  row.track,
                  false,
                  row.pinned,
                  row.occurrence,
                  row.error ?? 'cache_identity_unverified',
                )
              : row,
    ];
  }

  List<Pile> get piles => _displayPiles ??= store.piles();
  bool enriching(String id) => _metadataTasks.containsKey(id);
  Map<String, Object> metadataSummary() {
    int number(String sql) =>
        store.db.select(sql).first.values.first as int? ?? 0;
    return {
      'import_dates': number('SELECT COUNT(*) FROM tracks WHERE updated>0'),
      // Report text quality as aggregate counts without exposing any recording text.
      'cyrillic_titles': number(
        "SELECT COUNT(*) FROM tracks WHERE title GLOB ('*[' || char(1024) || '-' || char(1279) || ']*')",
      ),
      'replacement_metadata': number(
        'SELECT COUNT(*) FROM tracks WHERE instr(title,char(65533))>0 OR instr(artist,char(65533))>0',
      ),
      'question_mark_metadata': number(
        "SELECT COUNT(*) FROM tracks WHERE instr(title,'???')>0 OR instr(artist,'???')>0",
      ),
      'enriched_tracks': number('SELECT COUNT(*) FROM track_metadata'),
      'albums': number(
        "SELECT COUNT(*) FROM track_metadata WHERE json_type(body,'\$.album')='text'",
      ),
      'upload_dates': number(
        "SELECT COUNT(*) FROM track_metadata WHERE json_type(body,'\$.uploadedAt')='integer'",
      ),
      'artwork_cached': number(
        'SELECT COUNT(*) FROM track_metadata WHERE artwork IS NOT NULL',
      ),
      'lyrics_advertised': number(
        "SELECT COUNT(*) FROM track_metadata WHERE json_extract(body,'\$.lyricsAvailable')=1 OR json_type(body,'\$.lyricsId')='integer'",
      ),
      'lyrics_cached': number(
        "SELECT COUNT(*) FROM track_lyrics WHERE json_extract(body,'\$.state')='available'",
      ),
      'lyrics_not_provided': number(
        "SELECT COUNT(*) FROM track_lyrics WHERE json_extract(body,'\$.state')='not_provided'",
      ),
      'pending_details': _metadataTasks.length + _visibleMetadataTasks.length,
      'pending_artwork': _artworkTasks.length,
    };
  }

  void _reportMetadataSummary() {
    if (!disposed) {
      File('${store.directory.path}/metadata-status.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          ...metadataSummary(),
        }),
      );
    }
  }

  /// Reuse cover-key metadata while preserving file validation on each access.
  File? artworkFile(String id) => artwork.localFile(
    _displayValue(_displayArtworkKeys, id, () => store.artworkKey(id)),
  );

  void _mergeObservedMetadata(String id, {Map<String, dynamic>? observed}) {
    final data = observed ?? provider.observedMetadata(id);
    store.mergeMetadata(id, data);
    final lyrics = data['lyrics'];
    if (lyrics is Map) {
      store.saveLyrics(id, lyrics, state: 'available');
    } else if (data['lyricsAvailable'] == false) {
      store.saveLyrics(id, null, state: 'not_provided');
    }
    if (_artworkDemand[id]?.isNotEmpty == true) {
      unawaited(loadArtwork(id, visibleOnly: true));
    }
  }

  Future<void> enrichTrack(String id, {bool force = false}) {
    if (disposed || offline || demo) return Future.value();
    return _metadataTasks.putIfAbsent(
      id,
      () => Future<void>(() async {
        try {
          if (disposed) return;
          final track = store.track(id);
          if (track == null) return;
          if (!provider.connected && !autoSync) {
            throw const ProofFailure('vk_not_connected');
          }
          final data = await provider
              .inspectMetadata(track, force: force)
              .timeout(
                metadataTimeout,
                onTimeout: () =>
                    throw const ProofFailure('metadata_request_timeout'),
              );
          if (disposed) return;
          _mergeObservedMetadata(id, observed: data);
          if (data['lyricsAvailable'] == true && data['lyrics'] == null) {
            store.saveLyrics(id, null, state: 'failed');
          }
          metadataErrors.remove(id);
        } catch (e) {
          if (disposed) return;
          metadataErrors[id] = categoryOf(e);
          store.saveLyrics(id, null, state: 'failed');
        } finally {
          _metadataTasks.remove(id);
          if (!disposed) _notify();
          if (!disposed) _reportMetadataSummary();
        }
      }),
    );
  }

  void watchArtwork(String id, Object owner, {int priority = 1}) {
    if (disposed) return;
    (_artworkDemand[id] ??= {})[owner] = priority;
    unawaited(loadArtwork(id, visibleOnly: true));
  }

  void unwatchArtwork(String id, Object owner) {
    final demand = _artworkDemand[id];
    demand?.remove(owner);
    if (demand?.isEmpty == true) _artworkDemand.remove(id);
    if (!_artworkDemand.containsKey(id) && _visibleMetadataQueue.remove(id)) {
      _visibleMetadataTasks.remove(id)?.complete();
    }
    artwork.prune();
  }

  Future<void> _requestVisibleMetadata(String id) {
    if (demo ||
        disposed ||
        offline ||
        (!provider.connected && !autoSync) ||
        _artworkDemand[id]?.isNotEmpty != true) {
      return Future.value();
    }
    final task = _visibleMetadataTasks.putIfAbsent(id, () {
      _visibleMetadataQueue.add(id);
      return Completer<void>();
    });
    scheduleMicrotask(_pumpVisibleMetadata);
    return task.future;
  }

  Future<void> _pumpVisibleMetadata() async {
    if (_visibleMetadataWorking) return;
    _visibleMetadataWorking = true;
    try {
      while (_visibleMetadataQueue.isNotEmpty) {
        int priority(String id) => (_artworkDemand[id]?.values ?? const <int>[])
            .fold<int>(0, (a, b) => a > b ? a : b);
        _visibleMetadataQueue.sort(
          (a, b) => priority(b).compareTo(priority(a)),
        );
        final id = _visibleMetadataQueue.removeAt(0);
        final task = _visibleMetadataTasks[id]!;
        var alive = true;
        bool needed() =>
            alive &&
            !disposed &&
            !offline &&
            _artworkDemand[id]?.isNotEmpty == true;
        try {
          while (needed() && (loading || downloadId != null)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          if (!needed()) continue;
          final track = store.track(id);
          if (track == null) continue;
          final data = await provider
              .inspectMetadata(
                track,
                includeLyrics: false,
                cancelled: () => !needed(),
              )
              .timeout(metadataTimeout);
          if (!needed()) continue;
          _mergeObservedMetadata(id, observed: data);
          if (provider.artworkSource(id) == null) {
            _artworkRetry[id] = DateTime.now().add(const Duration(minutes: 1));
          }
          _notify(library: false);
        } catch (error) {
          if (needed() && categoryOf(error) != 'cancelled') {
            _artworkRetry[id] = DateTime.now().add(const Duration(minutes: 1));
          }
        } finally {
          alive = false;
          _visibleMetadataTasks.remove(id);
          task.complete();
          if (!disposed) _reportMetadataSummary();
        }
      }
    } finally {
      _visibleMetadataWorking = false;
    }
  }

  Future<void> loadArtwork(String id, {bool visibleOnly = false}) {
    if (disposed ||
        offline ||
        (visibleOnly && _artworkDemand[id]?.isNotEmpty != true) ||
        artworkFile(id) != null ||
        DateTime.now().isBefore(
          _artworkRetry[id] ?? DateTime.fromMillisecondsSinceEpoch(0),
        )) {
      return Future.value();
    }
    final source = provider.artworkSource(id);
    if (source == null) {
      return visibleOnly ? _requestVisibleMetadata(id) : Future.value();
    }
    bool needed() => !visibleOnly || _artworkDemand[id]?.isNotEmpty == true;
    return _artworkTasks.putIfAbsent(id, () async {
      try {
        while (!disposed &&
            !offline &&
            needed() &&
            (loading || downloadId != null)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (disposed || offline || !needed()) return;
        final protected = store.db
            .select(
              'SELECT DISTINCT m.artwork FROM track_metadata m JOIN pins p ON p.track=m.track WHERE m.artwork IS NOT NULL',
            )
            .map((r) => r['artwork'] as String)
            .toSet();
        final priorities = _artworkDemand[id]?.values ?? const <int>[];
        final priority = priorities.fold<int>(0, (a, b) => a > b ? a : b);
        final key = await artwork.obtain(
          source,
          protectedKeys: protected,
          needed: needed,
          priority: priority,
        );
        if (disposed || offline || !needed()) return;
        store.saveArtwork(id, key);
        // Refresh a formerly missing key without invalidating the entire library for one cover.
        _displayArtworkKeys.remove(id);
        _notify(library: false);
      } catch (error) {
        if (!disposed && needed() && categoryOf(error) != 'cancelled') {
          _artworkRetry[id] = DateTime.now().add(const Duration(minutes: 1));
        }
      } finally {
        _artworkTasks.remove(id);
        if (!disposed) _reportMetadataSummary();
        if (!disposed &&
            !offline &&
            visibleOnly &&
            needed() &&
            artworkFile(id) == null &&
            !DateTime.now().isBefore(
              _artworkRetry[id] ?? DateTime.fromMillisecondsSinceEpoch(0),
            )) {
          scheduleMicrotask(
            () => unawaited(loadArtwork(id, visibleOnly: true)),
          );
        }
      }
    });
  }

  Future<Map<String, Object>> repairMismatchedCache() {
    if (_recordingRepair != null) return _recordingRepair!;
    final task = Future<Map<String, Object>>(() async {
      final report = <String, Object>{'phase': 'running'};
      void save() => File('${store.directory.path}/recording-integrity.json')
          .writeAsStringSync(
            jsonEncode({
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
              ...report,
            }),
          );
      try {
        final mismatches = store.db.select(
          'SELECT a.track FROM assets a JOIN tracks t ON t.id=a.track WHERE t.duration>0 AND ABS(a.duration-t.duration)>5',
        );
        report['mismatches_before'] = mismatches.length;
        if (mismatches.length != 1) {
          throw const ProofFailure('cache_mismatch_not_unique');
        }
        final track = store.track(mismatches.single['track'] as String)!;
        save();
        await stopPlayback(diagnostic: true);
        final asset = await ensureAsset(track);
        await AudioCache(
          cacheDirectory,
          decodeAudio,
          certificateVerifier: certificateVerifierFactory(),
        ).verify(asset, expectedTrack: track, requireIdentity: true);
        store.setSetting('recording_repair_sample_id', track.id);
        report.addAll({
          'phase': 'finished',
          'identity_bound': true,
          'duration_matched': true,
          'original_preserved': true,
        });
      } catch (error) {
        report.addAll({'phase': 'failed', 'category': categoryOf(error)});
      }
      if (!disposed) save();
      return report;
    });
    _recordingRepair = task;
    task.whenComplete(() {
      if (identical(_recordingRepair, task)) _recordingRepair = null;
    });
    return task;
  }

  bool get autoSync => store.setting('auto_sync', false) == true;
  int get quota => store.setting('quota_bytes', 2 * 1024 * 1024 * 1024) as int;
  String get heading => pileId != null
      ? piles.where((p) => p.id == pileId).firstOrNull?.name ?? 'Pile'
      : switch (view) {
          'offline' => 'Available offline',
          'recent' => 'Recently played',
          'most' => 'Most played',
          'vk' => 'VK music',
          _ => 'Your library',
        };
  void _notify({bool library = true}) {
    // Refresh catalog-derived display values only for mutations, never playback-clock ticks.
    if (library) {
      _rowCache = null;
      _displayTracks.clear();
      _displayPins.clear();
      _displayArtworkKeys.clear();
      _displayPiles = null;
      _displayLibraryCount = null;
    }
    if (!disposed) notifyListeners();
  }

  void browse(String next, {int? pile}) {
    view = next;
    pileId = pile;
    query = '';
    _notify();
  }

  void search(String text) {
    query = text;
    _notify();
  }

  void _saveQueue() => store.setSetting('queue', queue.toJson());

  /// Correlate connection evidence independently from foreground playback.
  Future<void> connectVk() => diagnostics.run('connection', _connectVk);

  /// Preserve the existing explicit consent/private sign-in connection flow.
  Future<void> _connectVk() async {
    if (demo) {
      message = 'This preview uses generated music. Open the regular app to connect VK.';
      _notify();
      return;
    }
    if (connecting || disposed) return;
    final generation = ++_connectionGeneration;
    connectionError = null;
    offline = false;
    store.setSetting('offline', false);
    store.setSetting('auto_sync', true);
    connecting = true;
    _notify();
    try {
      await provider.finishPrivateSignIn();
      if (disposed || offline || generation != _connectionGeneration) return;
      await provider.connect();
      if (disposed || offline || generation != _connectionGeneration) return;
      _nextSync = DateTime.now();
    } catch (e) {
      if (!disposed && generation == _connectionGeneration) {
        connectionError = SyncActivity.safeReason(categoryOf(e));
        _failure(e, audioMessage: false);
      }
    } finally {
      if (generation == _connectionGeneration) connecting = false;
      _notify();
    }
  }

  Future<void> signInVk() async {
    if (demo) return;
    try {
      await provider.signInPrivately();
    } catch (e) {
      if (!disposed) {
        connectionError = SyncActivity.safeReason(categoryOf(e));
        _failure(e, audioMessage: false);
      }
    }
  }

  Future<void> _schedule() async {
    _pollControl();
    if (_restartRequested &&
        !loading &&
        !player.state.playing &&
        !syncing &&
        downloadId == null &&
        !_checking) {
      _restartRequested = false;
      unawaited(_restart());
      return;
    }
    if (disposed ||
        demo ||
        offline ||
        _checking ||
        !autoSync ||
        provider.privateSignInActive) {
      return;
    }
    if (syncing) return;
    if (!provider.connected) {
      // Start only after persisted consent; leave login interaction private.
      if (!connecting) {
        connecting = true;
        connectionError = null;
        _notify(library: false);
        try {
          await provider.connect();
        } catch (e) {
          connectionError = SyncActivity.safeReason(categoryOf(e));
          _failure(e, audioMessage: false);
          _nextSync = DateTime.now().add(const Duration(minutes: 2));
        } finally {
          connecting = false;
          _notify(library: false);
        }
      }
      return;
    }
    if (!syncing &&
        !loading &&
        downloadId == null &&
        !DateTime.now().isBefore(_nextSync)) {
      await refresh(full: false);
    }
    if (_acceptanceRequested &&
        !loading &&
        downloadId == null &&
        !player.state.playing &&
        _playEvent == null &&
        store.count > 0) {
      unawaited(_checkSample());
      return;
    }
    if (!syncing && !loading && downloadId == null) unawaited(_pumpPins());
  }

  /// Keep sync evidence separate from concurrent playback attempts.
  Future<void> refresh({bool full = true}) =>
      diagnostics.run('sync', () => _refresh(full: full));

  /// Honor an explicit short check even when initial discovery is unfinished.
  Future<void> checkNewest() {
    if (syncPending) return Future.value();
    return diagnostics.run('sync', () => _refresh(full: false, headOnly: true));
  }

  /// Describe the dated provider witness separately from all preserved local recordings.
  String get libraryCoverageSummary {
    // Keep provider membership distinct from historical rows saved in this application.
    final count = store.setting('provider_library_count');
    // Parse only the app-owned timestamp; missing legacy settings remain partial.
    final verified = DateTime.tryParse(
      store.setting('provider_library_verified_at', '').toString(),
    );
    // Display complete coverage only when its count and date are available.
    if (store.setting('coverage') == 'complete' &&
        count is int &&
        count >= 0 &&
        verified != null) {
      return 'Automatic refresh checks newest entries. $count ${count == 1 ? 'recording' : 'recordings'} in last verified VK listing (${verified.toIso8601String().split('T').first}); $libraryCount saved locally.';
    }
    return 'Automatic refresh checks newest entries. VK listing coverage is partial. Scan full library checks the full listing; saved music stays available.';
  }

  /// Run the existing bounded sync policy without changing import or deletion behavior.
  Future<void> _refresh({bool full = true, bool headOnly = false}) async {
    if (disposed || offline || syncing || demo || !provider.connected) return;
    final generation = ++_syncGeneration;
    syncing = true;
    final watch = Stopwatch()..start();
    // Respect a completed empty library instead of repeating full discovery forever.
    final initial =
        store.setting('initial_sync_pending', store.count == 0) == true;
    // Keep quiet/incomplete initial imports pending without repeating broad scans every poll.
    final initialPaused = store.setting('initial_sync_paused', false) == true;
    // Resume active slices automatically; paused discovery still permits bounded head checks.
    final broad =
        !headOnly && (full || (initial && !initialPaused) || _continueSweep);
    final fromTop = headOnly || full || !_continueSweep;
    final checkpoint = store.syncHead;
    final before = store.count;
    var received = 0;
    _syncActivity = SyncActivity(
      phase: 'running',
      mode: broad ? 'full' : 'head',
    );
    _notify(library: false);
    bool active() => !disposed && !offline && generation == _syncGeneration;
    void report(String phase, {String? reason, int checked = 0}) {
      _writeAudioDiagnostic({
        'stage': 'sync_status',
        'phase': phase,
        'mode': broad ? 'full' : 'head',
        'manual': full,
        'checkpoint_count': checkpoint.length,
        'checked': checked,
        'new_tracks': store.count - before,
        'elapsed_ms': watch.elapsedMilliseconds,
      });
      File('${store.directory.path}/sync-status.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'phase': phase,
          'mode': broad ? 'full' : 'head',
          'manual': full,
          'checkpoint_count': checkpoint.length,
          'checked': checked,
          'new_tracks': store.count - before,
          'elapsed_ms': watch.elapsedMilliseconds,
          'reason': ?reason,
        }),
      );
    }

    try {
      report('running');
      if (headOnly && initial) store.setSetting('initial_sync_paused', true);
      // Preserve incomplete discovery independently of whether the current request checks the head.
      if (initial) store.setSetting('initial_sync_pending', true);
      // Resume explicit or active broad discovery without treating its end as verified coverage.
      if (broad && initial) store.setSetting('initial_sync_paused', false);
      if (fromTop) store.setSetting('sweep_epoch', store.now);
      final epoch = store.setting('sweep_epoch', store.now) as int;
      final result = await provider.sync(
        (tracks) {
          if (!active()) return;
          received += tracks.length;
          store.merge(tracks, discoveredAt: epoch);
          store.transaction(() {
            for (final track in tracks) {
              final position = provider.libraryPosition(track.id);
              if (position != null) {
                store.noteProviderPosition(track.id, position, epoch);
              }
              final unavailable = provider.trackUnavailable(track.id);
              if (unavailable != null) {
                store.noteAvailability(track.id, unavailable);
              }
              final reference = provider.musicReference(track.id);
              if (reference != null) {
                store.saveMusicReference(track.id, reference);
              }
              _mergeObservedMetadata(track.id);
            }
          });
          _syncActivity = SyncActivity(
            phase: 'running',
            mode: broad ? 'full' : 'head',
            checked: received,
            added: store.count - before,
          );
          _notify();
        },
        fromTop: fromTop,
        newestOnly: !broad,
        checkpoint: checkpoint,
      );
      if (!active()) return;
      _continueSweep = broad && result.continueSweep;
      // Accept complete membership only from the provider's validated unique end witness.
      final complete = result.reason == 'provider_end' && !result.continueSweep;
      // Carry the original head across full-scan slices; never replace it after a partial scan.
      if (result.head.isNotEmpty &&
          (complete ||
              (fromTop &&
                  ['known_head', 'head_seeded'].contains(result.reason)))) {
        store.saveSyncHead(result.head);
      }
      // A quiet/page/time boundary cannot prove the provider's complete membership.
      if (!complete && initial && broad && !_continueSweep) {
        store.setSetting('initial_sync_paused', true);
      }
      store.setSetting('last_sync', DateTime.now().toIso8601String());
      // Record the verified provider size separately from the preserved local catalog.
      if (complete) {
        store.setSetting('initial_sync_pending', false);
        store.setSetting('initial_sync_paused', false);
        store.setSetting('provider_library_count', result.discovered);
        store.setSetting(
          'provider_library_verified_at',
          DateTime.now().toIso8601String(),
        );
        store.setSetting('coverage', 'complete');
      }
      // Keep the dated full witness during ordinary head polling.
      else if (broad) {
        store.setSetting('coverage', 'partial');
      }
      _nextSync = DateTime.now().add(
        Duration(seconds: _continueSweep ? 5 : 120),
      );
      final succeeded =
          complete ||
          (!broad && ['known_head', 'head_seeded'].contains(result.reason));
      _saveSyncActivity(
        SyncActivity(
          phase: result.reason == 'cancelled'
              ? 'cancelled'
              : succeeded
              ? 'succeeded'
              : 'partial',
          mode: broad ? 'full' : 'head',
          checked: result.discovered,
          added: store.count - before,
          finishedAt: DateTime.now(),
          reason: SyncActivity.safeReason(result.reason),
        ),
      );
      store.report(
        complete ? 'sync_complete' : 'sync_partial',
        count: store.count,
      );
      report('finished', reason: result.reason, checked: result.discovered);
      _reportMetadataSummary();
    } catch (e) {
      if (!active()) return;
      _continueSweep = false;
      // Preserve pending initial discovery after a failed or revoked provider request.
      if (initial) store.setSetting('initial_sync_paused', true);
      _nextSync = DateTime.now().add(const Duration(minutes: 2));
      _saveSyncActivity(
        SyncActivity(
          phase: categoryOf(e) == 'cancelled' ? 'cancelled' : 'failed',
          mode: broad ? 'full' : 'head',
          checked: received,
          added: store.count - before,
          finishedAt: DateTime.now(),
          reason: SyncActivity.safeReason(categoryOf(e)),
        ),
      );
      _failure(e, audioMessage: false);
      report('failed', reason: categoryOf(e));
    } finally {
      syncing = false;
      _notify();
    }
  }

  Future<void> setOffline(bool value) async {
    offline = value;
    store.setSetting('offline', value);
    if (value) {
      ++_connectionGeneration;
      connecting = false;
      await cancelSync();
      artwork.cancel();
      _cancelCheck('offline');
      _cancelPendingDownloads();
      if (loading) {
        ++_request;
        loading = false;
      }
      _downloads.clear();
      _activeCache?.cancel();
      if (_playingStream != null) await player.pause();
      await _closeStreams();
      _notify();
      await provider.disconnect();
      message = 'Offline mode · saved music is ready.';
    } else {
      message = 'Online mode';
      _nextSync = DateTime.now();
    }
    _notify();
  }

  void setAutoSync(bool enabled) {
    store.setSetting('auto_sync', enabled);
    _nextSync = DateTime.now();
    _notify();
  }

  Future<void> playLibrary(List<LibraryRow> list) async {
    var selected = list.indexWhere(
      (row) => row.offline || !isProviderRestricted(row.error),
    );
    final local = list.indexWhere((row) => row.offline);
    // When the beginning is unavailable, a verified local song can start
    // immediately while metadata refresh updates the remaining availability.
    if (selected > 0 && local >= 0) selected = local;
    for (var attempt = 0; selected >= 0 && attempt < 3; attempt++) {
      final expectedRequest = _request + 1;
      await playRows(list, selected);
      if (disposed || _request != expectedRequest) return;
      final failedId = list[selected].track.id;
      final failed = store.rows().any(
        (row) => row.track.id == failedId && isProviderRestricted(row.error),
      );
      if (!failed) return;
      if (local >= 0 && local != selected) {
        selected = local;
      } else {
        selected = list.indexWhere(
          (row) => row.offline || !isProviderRestricted(row.error),
          selected + 1,
        );
      }
    }
    message = 'The attempted recordings are restricted in VK. Choose another song from your saved library.';
    _notify(library: false);
  }

  Future<void> playRows(
    List<LibraryRow> list,
    int selected, {
    bool diagnostic = false,
  }) async {
    queue.replace(
      list.map((r) => QueueEntry(r.track.id, r.occurrence)).toList(),
      selected,
    );
    if (!diagnostic) _saveQueue();
    await playCurrent(diagnostic: diagnostic);
  }

  void enqueue(LibraryRow row) {
    queue.append(QueueEntry(row.track.id, row.occurrence));
    _saveQueue();
    _notify();
  }

  void _reportPlayerState() {
    if (disposed) return;
    try {
      File('${store.directory.path}/player-state.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'loading': loading,
          'playing': player.state.playing,
          'buffering': player.state.buffering,
          'position_ms': player.state.position.inMilliseconds,
          'duration_ms': player.state.duration.inMilliseconds,
          'volume': player.state.volume,
          'cached': current != null && store.asset(current!.id) != null,
          'download_stage': downloadStage,
          'received_bytes': downloadBytes,
        }),
      );
    } catch (_) {
      /* Numeric diagnostics do not block the player. */
    }
  }

  void _reportPlayback(String phase, Stopwatch watch, {String? category}) {
    _writeAudioDiagnostic({
      'stage': 'playback_status',
      'phase': phase,
      'elapsed_ms': watch.elapsedMilliseconds,
      'loading': loading,
      'playing': player.state.playing,
      'buffering': player.state.buffering,
      'cached': current != null && store.asset(current!.id) != null,
      'received_bytes': downloadBytes,
      'category': ?category,
    });
    try {
      File('${store.directory.path}/playback-status.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'phase': phase,
          'elapsed_ms': watch.elapsedMilliseconds,
          'loading': loading,
          'playing': player.state.playing,
          'buffering': player.state.buffering,
          'position_ms': player.state.position.inMilliseconds,
          'cached': current != null && store.asset(current!.id) != null,
          'download_stage': downloadStage,
          'received_bytes': downloadBytes,
          'provider_connected': provider.connected,
          'scanning': syncing,
          'category': ?category,
        }),
      );
    } catch (_) {
      /* Diagnostics cannot block playback. */
    }
  }

  /// Keep every asynchronous source/native/cache event bound to this Play attempt.
  Future<void> playCurrent({bool diagnostic = false}) =>
      diagnostics.run('playback', () => _playCurrent(diagnostic: diagnostic));

  /// Run the existing exact-recording startup and request ownership checks.
  Future<void> _playCurrent({
    bool diagnostic = false,
    int? recoveryRequest,
    Stopwatch? startupWatch,
    ProofFailure? originalSourceFailure,
  }) async {
    final track = current;
    if (track == null) return;
    if (!diagnostic && recoveryRequest == null) {
      _cancelCheck('selection_changed');
    }
    if (!diagnostic && recoveryRequest == null) _saveQueue();
    final request = recoveryRequest ?? ++_request;
    if (request != _request || disposed) return;
    _finishListening();
    loading = true;
    store.trackError(track.id, null);
    message = 'Preparing ${track.title}…';
    _notify();
    final watch = startupWatch ?? (Stopwatch()..start());
    var delegatedRecovery = false;
    var phase = 'stopping_previous';
    void enterPhase(String next) {
      phase = next;
      // Update the in-memory journal immediately. Periodic disk snapshots alone
      // misattribute subsecond failures to the preceding phase.
      _writeAudioDiagnostic({
        'stage': 'playback_status',
        'phase': phase,
        'elapsed_ms': watch.elapsedMilliseconds,
      });
    }

    String? playbackError;
    // Keep the selected relay's original failure available throughout startup.
    StreamingAudio? openingStream;
    _reportPlayback(phase, watch);
    final progress = Timer.periodic(const Duration(seconds: 1), (_) {
      if (request == _request) _reportPlayback(phase, watch);
    });
    final remainingBudget = startupTimeout - watch.elapsed;
    final deadline = Timer(remainingBudget, () {
      if (request != _request || !loading || disposed) return;
      unawaited(stopPlayback());
      store.trackError(track.id, 'player_start_timeout');
      _failure(const ProofFailure('player_start_timeout'));
      _reportPlayback('failed', watch, category: 'player_start_timeout');
    });
    try {
      await player.stop().timeout(const Duration(seconds: 5));
      if (request != _request || disposed) return;
      // Cancel even before source lookup has assigned downloadId, including a pending connection.
      if (_downloads.keys.any((id) => id != track.id) &&
          _streams[downloadId]?.downloadComplete != true) {
        _cancelPendingDownloads();
        _activeCache?.cancel();
        _downloads.clear();
        // Let native browser cleanup finish independently of the newer selection.
        unawaited(provider.cancelResolution().catchError((Object _) {}));
      }
      if (_playingStream != null && _playingStream != track.id) {
        final previous = _playingStream;
        _playingStream = null;
        if (downloadId != previous) {
          await _streams.remove(previous)?.close();
        }
      }
      enterPhase('resolving_source');
      final (asset, stream) = await _preparePlayback(track);
      openingStream = stream;
      if (request != _request || disposed) return;
      enterPhase('opening_native_player');
      final errorsBeforeOpen = _nativeErrors;
      final startup = Stopwatch()..start();
      if (asset != null) {
        await player.openLocal(asset.entry);
      } else {
        _playingStream = track.id;
        await player.openStream(await stream!.open());
      }
      enterPhase('waiting_first_audio');
      await waitUntil(
        () =>
            request != _request ||
            disposed ||
            openingStream?.failure != null ||
            (_nativeErrors != errorsBeforeOpen &&
                startup.elapsed > const Duration(seconds: 2)) ||
            (player.state.playing &&
                !player.state.buffering &&
                player.state.position.inMilliseconds >= 100),
        'player_start_timeout',
        timeout: const Duration(seconds: 45),
      );
      if (request != _request || disposed) {
        return;
      }
      // Prefer the actual transfer failure over the native relay-open symptom.
      final transferFailure = openingStream?.failure;
      // Stop startup immediately if its upstream source has already failed.
      if (transferFailure != null) throw transferFailure;
      if (!(player.state.playing &&
          !player.state.buffering &&
          player.state.position.inMilliseconds >= 100)) {
        throw ProofFailure(_lastNativeCategory ?? 'player_start_failed');
      }
      if (!diagnostic) _playEvent = store.startPlay(track.id);
      _listened = 0;
      _lastSave = 0;
      _lastTick = _clock.elapsed;
      _wasPlaying = player.state.playing && !player.state.buffering;
      store.touchAsset(track.id);
      store.trackError(track.id, null);
      store.setSetting('last_start_ms', watch.elapsedMilliseconds);
      message = asset != null
          ? 'Playing from your local cache'
          : 'Streaming · saving for offline playback';
      await enforceQuota();
      enterPhase('playing');
    } catch (e, stack) {
      if (request == _request) {
        // Preserve upstream transport errors even when the player reports a generic open failure.
        final failure = openingStream?.failure ?? e;
        try {
          await player.stop().timeout(const Duration(seconds: 5));
        } catch (_) {
          /* Preserve the original failure. */
        }
        // A newer request owns player state once this cleanup acknowledgement returns.
        if (request != _request || disposed) return;
        // Close only the relay owned by this failed startup, after native unload.
        final failedStream = openingStream;
        // Leave a replacement relay untouched if another request already installed it.
        if (failedStream != null &&
            identical(_streams[track.id], failedStream)) {
          _streams.remove(track.id);
          // Release the failed selection without changing another request's source.
          if (_playingStream == track.id) _playingStream = null;
          try {
            await failedStream.close(cancel: true);
          } catch (_) {
            /* Preserve the original startup failure. */
          }
        }
        // Keep late cleanup from replacing a newer request's successful status.
        if (request != _request || disposed) return;
        final recovery = provider is RejectedSourceRecovery
            ? provider as RejectedSourceRecovery
            : null;
        if (originalSourceFailure == null &&
            failure is AudioDestinationFailure &&
            failedStream != null &&
            recovery != null &&
            recovery.rejectSource(track.id, failedStream.source)) {
          // Retry this identity once through current discovery. Do not follow the
          // rejected destination, reset the total deadline, or publish its bytes.
          final pending = _downloads.remove(track.id);
          if (pending != null) {
            try {
              // Keep the original deadline and cancellation subscription active
              // until the old download has relinquished its serialized lane.
              await _awaitDownload(pending, _cancelDownload);
            } catch (_) {
              /* Original cause retained. */
            }
          }
          if (request != _request || disposed) return;
          if (startupTimeout - watch.elapsed > Duration.zero) {
            _writeAudioDiagnostic({
              'stage': 'reference_source_retry',
              'category': failure.category,
            });
            progress.cancel();
            deadline.cancel();
            delegatedRecovery = true;
            // Recovery belongs to the same foreground request, including a
            // diagnostic's queue/history ownership and total startup deadline.
            await _playCurrent(
              diagnostic: diagnostic,
              recoveryRequest: request,
              startupWatch: watch,
              originalSourceFailure: failure,
            );
            return;
          }
        }
        if (originalSourceFailure != null) {
          _writeAudioDiagnostic({
            'stage': 'reference_source_retry_failed',
            'category': categoryOf(failure),
          });
        }
        final reportedFailure = originalSourceFailure ?? failure;
        phase = 'failed';
        playbackError = categoryOf(reportedFailure);
        store.trackError(track.id, categoryOf(reportedFailure));
        _failure(reportedFailure, stack: stack);
        _reportPlayback(phase, watch, category: categoryOf(reportedFailure));
      }
    } finally {
      progress.cancel();
      deadline.cancel();
      if (!delegatedRecovery && request == _request) {
        loading = false;
        _reportPlayback(phase, watch, category: playbackError);
        _notify();
      }
    }
  }

  Future<void> togglePlay({bool diagnostic = false}) async {
    if (!diagnostic) _cancelCheck('user_play_pause');
    if (loading) {
      await stopPlayback();
      return;
    }
    if (player.state.playing) {
      await player.pause();
    } else if (_playEvent != null || diagnostic) {
      await player.play();
    } else {
      await playCurrent();
    }
    _notify();
  }

  Future<void> stopPlayback({bool diagnostic = false}) async {
    if (!diagnostic) _cancelCheck('user_stop');
    ++_request;
    _cancelPendingDownloads();
    final stream = _streams.remove(_playingStream);
    final activeCache = _activeCache;
    _playingStream = null;
    _downloads.clear();
    _streamReady.clear();
    _finishListening();
    loading = false;
    message = 'Playback stopped';
    _notify();
    // Unload native media before destroying its HTTP source. Pausing leaves
    // demuxing alive; closing that relay can poison the next local open.
    final resolution = provider.cancelResolution();
    try {
      await player.stop().timeout(const Duration(seconds: 5));
    } catch (e) {
      if (!disposed) _failure(e);
    } finally {
      activeCache?.cancel();
      await stream?.close(cancel: true);
      await resolution;
    }
  }

  Future<void> next({bool automatic = false}) async {
    _finishListening();
    if (queue.next(automatic: automatic) != null) {
      _saveQueue();
      await playCurrent();
    } else {
      await stopPlayback();
    }
  }

  Future<void> previous() async {
    _cancelCheck('user_previous');
    if (!loading && player.state.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    if (queue.previous() != null) {
      _saveQueue();
      await playCurrent();
    }
  }

  Future<void> seek(double seconds, {bool diagnostic = false}) async {
    if (!diagnostic) _cancelCheck('user_seek');
    await player.seek(Duration(milliseconds: (seconds * 1000).round()));
  }

  Future<void> toggleMute() => volume(muted ? _unmutedVolume : 0);

  Future<void> volume(double value) {
    if (!value.isFinite || disposed) return Future.value();
    final level = value.clamp(0.0, 100.0);
    _volumeLevel = level;
    if (level > 0) _unmutedVolume = level;
    store.transaction(() {
      store.setSetting('volume', level);
      store.setSetting('unmuted_volume', _unmutedVolume);
    });
    _notify(library: false);
    // Publish intent immediately, but serialize native writes so an earlier
    // slow mute/slider change cannot overwrite the most recent selection.
    final pending = _volumeTail.then((_) => player.setVolume(level));
    _volumeTail = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  void shuffle() {
    queue.setShuffle(!queue.shuffle);
    _saveQueue();
    _notify();
  }

  void repeat() {
    queue.repeat = QueueRepeat.values[(queue.repeat.index + 1) % 3];
    _saveQueue();
    _notify();
  }

  void _recordListening() {
    final elapsed = _clock.elapsed;
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    if (_playEvent != null && _wasPlaying && !loading) {
      _listened += delta.inMilliseconds.clamp(0, 2000);
      if (_listened - _lastSave >= 5000) {
        store.listen(
          _playEvent!,
          _listened,
          player.state.duration.inMilliseconds / 1000,
        );
        _lastSave = _listened;
        if (view == 'recent' || view == 'most') _notify();
      }
    }
  }

  void _finishListening() {
    _recordListening();
    _flushListening();
    _playEvent = null;
    _wasPlaying = false;
  }

  void _flushListening() {
    if (_playEvent != null) {
      store.listen(
        _playEvent!,
        _listened,
        player.state.duration.inMilliseconds / 1000,
      );
    }
  }

  /// Invalidate old work and release source waits without waiting for an adapter callback.
  void _cancelPendingDownloads() {
    ++_cancelDownload;
    _downloadCancellations.add(null);
  }

  /// Bound a provider wait by its download generation and observe late completions safely.
  Future<T> _awaitDownload<T>(Future<T> operation, int token) async {
    // Reject work invalidated before its provider callback was attached.
    if (disposed || token != _cancelDownload) {
      // Observe a future already created by the caller without accepting its result.
      unawaited(operation.then<void>((_) {}, onError: (Object _) {}));
      throw const ProofFailure('cancelled');
    }
    // Complete only this wait when a new generation invalidates its result.
    final cancellation = Completer<T>();
    // Remove this subscription after either source completion or cancellation.
    final subscription = _downloadCancellations.stream.listen((_) {
      // Complete once even if Stop and shutdown arrive during the same callback.
      if (!cancellation.isCompleted) {
        cancellation.completeError(const ProofFailure('cancelled'));
      }
    });
    try {
      return await Future.any([operation, cancellation.future]);
    } finally {
      await subscription.cancel();
    }
  }

  /// Reuse verified assets or queue one cancellable source/download operation per recording.
  Future<CachedAudio> ensureAsset(Track track, {bool playback = false}) {
    if (_downloads.containsKey(track.id)) return _downloads[track.id]!;
    // Capture ownership before local verification or queueing. Stop must also
    // invalidate work that has not reached the download lane yet.
    final token = _cancelDownload;
    final future = () async {
      // Valid local music bypasses unrelated network work. A failed cache
      // check rejoins the serialized lane before recovery or downloading.
      final saved = store.asset(track.id);
      if (saved != null) {
        try {
          await _safeCacheFolder(track.id, saved.entry);
          await AudioCache(
            cacheDirectory,
            decodeAudio,
            certificateVerifier: certificateVerifierFactory(),
          ).verify(saved, expectedTrack: track, requireIdentity: !demo);
          if (!demo) store.markAssetIdentity(saved);
          return saved;
        } catch (_) {
          if (offline) rethrow;
          // The queued path verifies/replaces the stale asset atomically.
        }
      }
      final pending = _downloadTail.then((_) {
        if (disposed ||
            token != _cancelDownload ||
            (playback && current?.id != track.id)) {
          throw const ProofFailure('cancelled');
        }
        return _obtainAsset(track, token: token);
      });
      _downloadTail = pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return pending;
    }();
    _downloads[track.id] = future;
    future.then(
      (_) {
        if (identical(_downloads[track.id], future)) {
          _downloads.remove(track.id);
        }
      },
      onError: (Object error, StackTrace _) {
        if (identical(_downloads[track.id], future)) {
          _downloads.remove(track.id);
        }
        if (_playingStream == track.id &&
            current?.id == track.id &&
            categoryOf(error) != 'cancelled' &&
            !disposed) {
          store.trackError(track.id, categoryOf(error));
          _failure(error);
        }
      },
    );
    return future;
  }

  Future<(CachedAudio?, StreamingAudio?)> _preparePlayback(
    Track track, {
    bool playback = true,
  }) async {
    // Offline/demo require local verification; an online legacy cache may need a streaming replacement.
    if (offline || demo) {
      return (await ensureAsset(track, playback: playback), null);
    }
    final ready = _streamReady.putIfAbsent(
      track.id,
      Completer<StreamingAudio>.new,
    );
    final existing = _streams[track.id];
    // Prefer a verified local file over a completed relay, but resume an active replacement immediately.
    if (existing != null &&
        (store.asset(track.id) == null || !existing.downloadComplete) &&
        !ready.isCompleted) {
      ready.complete(existing);
    }
    try {
      return await Future.any<(CachedAudio?, StreamingAudio?)>([
        ensureAsset(track, playback: playback).then((asset) => (asset, null)),
        ready.future.then((stream) => (null, stream)),
      ]);
    } finally {
      if (identical(_streamReady[track.id], ready)) {
        _streamReady.remove(track.id);
      }
    }
  }

  Future<void> _closeStreams() async {
    _playingStream = null;
    for (final stream in _streams.values.toList()) {
      await stream.close(cancel: true);
    }
    _streams.clear();
  }

  Directory get cacheDirectory => Directory('${store.directory.path}/audio');
  Future<CachedAudio> _obtainAsset(Track track, {required int token}) async {
    final progressWatch = Stopwatch()..start();
    var lastProgress = -100;
    final cache = AudioCache(
      cacheDirectory,
      decodeAudio,
      onDiagnostic: _writeAudioDiagnostic,
      certificateVerifier: certificateVerifierFactory(),
      cancelled: () => disposed || token != _cancelDownload,
      onProgress: (bytes) {
        if (disposed || token != _cancelDownload) return;
        downloadBytes = bytes;
        if (progressWatch.elapsedMilliseconds - lastProgress >= 100) {
          lastProgress = progressWatch.elapsedMilliseconds;
          _notify(library: false);
        }
      },
    )..offline = offline;
    final saved = store.asset(track.id);
    if (saved != null) {
      try {
        await _safeCacheFolder(track.id, saved.entry);
        await cache.verify(saved, expectedTrack: track, requireIdentity: !demo);
        if (!demo) store.markAssetIdentity(saved);
        return saved;
      } catch (error) {
        if (offline) rethrow;
        _writeAudioDiagnostic({
          'stage': 'cache_revalidation_required',
          'category': categoryOf(error),
          'preserved': true,
        });
      }
    } else {
      // Recover an atomic publication whose SQLite update was interrupted.
      final recovered = await _recoverAsset(track, cache);
      if (recovered != null) return recovered;
    }
    if (offline) throw const ProofFailure('track_not_cached');
    if (demo) throw const ProofFailure('preview_track_not_cached');
    if (!provider.connected) {
      // Consent is persistent; an early Play waits for the shared connection
      // instead of misreporting an ordinary navigation as expired sign-in.
      if (!autoSync) throw const ProofFailure('private_signin_required');
      await _awaitDownload(provider.connect(), token);
      if (disposed || token != _cancelDownload) {
        throw const ProofFailure('cancelled');
      }
    }
    downloadId = track.id;
    _sourceTimings = {};
    downloadStage = 'finding_source';
    _activeCache = cache;
    downloadBytes = 0;
    _notify();
    StreamingAudio? stream;
    try {
      final sourceWatch = Stopwatch()..start();
      final resolved = await _awaitDownload(
        provider.resolve(
          track,
          musicKey: store.musicReference(track.id),
          cancelled: () => disposed || token != _cancelDownload,
          manifestSegments: (source, userAgent) async {
            // Reject a late adapter request before it starts any obsolete network work.
            if (disposed || token != _cancelDownload) {
              throw const ProofFailure('cancelled');
            }
            final watch = Stopwatch()..start();
            try {
              final segments = await loadManifestSegments(source, (uri) async {
                return utf8.decode(
                  await cache.fetch(
                    uri,
                    userAgent: userAgent,
                    limit: 2 * 1024 * 1024,
                  ),
                );
              });
              _writeAudioDiagnostic({
                'stage': 'witness_manifest',
                'segments': segments.length,
                'elapsed_ms': watch.elapsedMilliseconds,
              });
              return segments;
            } catch (error) {
              _writeAudioDiagnostic({
                'stage': 'witness_manifest_failed',
                'category': categoryOf(error),
                if (error is ProofFailure && error.code != null)
                  'code': error.code!,
                'elapsed_ms': watch.elapsedMilliseconds,
              });
              rethrow;
            }
          },
          prepareCandidate: (source, userAgent) {
            // Ignore candidates delivered after Stop or a newer song selection.
            if (disposed || token != _cancelDownload) return;
            stream ??= StreamingAudio(cache, source, userAgent: userAgent);
            unawaited(
              stream!.prepare().then<void>((_) {}, onError: (Object _) {}),
            );
          },
        ),
        token,
      );
      // Reject a late resolution before changing bindings or shared timing state.
      if (disposed || token != _cancelDownload) {
        throw const ProofFailure('cancelled');
      }
      resolved.requireTrack(track);
      _writeAudioDiagnostic({
        'stage': 'recording_source_bound',
        'identity_bound': true,
        'identity_evidence': resolved.evidence,
      });
      _sourceTimings = {
        'identity_bound': true,
        'identity_evidence': resolved.evidence,
        ...resolved.timings,
        'source_return_ms': sourceWatch.elapsedMilliseconds,
        'prefix_prepared_at_resolution': stream?.prepared == true,
        'prefix_source_matched': stream?.source == resolved.source,
      };
      if (token != _cancelDownload) throw const ProofFailure('cancelled');
      message = 'Saving complete audio for ${track.title}…';
      downloadStage = 'receiving';
      _notify();
      if (stream != null && stream!.source != resolved.source) {
        // A later segment witness can identify a different candidate. Drop
        // provisional bytes; only the final verified source may be played or
        // published. The shared network owner still handles Stop/cancellation.
        await stream!.close();
        stream = null;
      }
      stream ??= StreamingAudio(
        cache,
        resolved.source,
        userAgent: resolved.userAgent,
      );
      _streams[track.id] = stream!;
      final ready = _streamReady[track.id];
      if (ready != null && !ready.isCompleted) ready.complete(stream!);
      final sharedCache = AudioCache(
        cacheDirectory,
        decodeAudio,
        certificateVerifier: certificateVerifierFactory(),
        cancelled: () => disposed || token != _cancelDownload,
        resourceLoader: stream!.fetch,
        onStage: (stage) {
          if (disposed || token != _cancelDownload) return;
          downloadStage = stage;
          _writeAudioDiagnostic({
            'stage': 'cache_stage',
            'download_stage': stage,
          });
          _notify(library: false);
        },
      );
      final asset = await _awaitDownload(
        sharedCache.save(
          track,
          resolved.source,
          userAgent: resolved.userAgent,
          recordingEvidence: resolved.evidence,
          preserveExisting: true,
        ),
        token,
      );
      if (disposed || token != _cancelDownload) {
        throw const ProofFailure('cancelled');
      }
      store.saveAsset(asset, identityVerified: true);
      store.trackError(track.id, null);
      await enforceQuota();
      if (_playingStream == track.id) {
        message = player.state.playing
            ? 'Playing · saved offline'
            : 'Paused · saved offline';
      }
      return asset;
    } catch (error) {
      // Record the transfer cause before relay cleanup and generic native errors obscure it.
      _writeAudioDiagnostic(audioTransferDiagnostic(error));
      rethrow;
    } finally {
      if (stream != null &&
          (!identical(_streams[track.id], stream) ||
              (_playingStream != track.id &&
                  _checkingTrack != track.id &&
                  !_streamReady.containsKey(track.id)))) {
        if (identical(_streams[track.id], stream)) _streams.remove(track.id);
        await stream!.close(cancel: true);
      }
      // Leave a newer selection's progress untouched when old cancellation unwinds late.
      if (identical(_activeCache, cache)) {
        _activeCache = null;
        downloadId = null;
        downloadStage = null;
        downloadBytes = 0;
        _notify();
      }
    }
  }

  Future<CachedAudio?> _recoverAsset(Track track, AudioCache cache) async {
    final folder = Directory('${cacheDirectory.path}/${track.id}');
    if (!await folder.exists()) return null;
    if (!demo && !File('${folder.path}/recording.json').existsSync()) {
      return null;
    }
    try {
      await _safeCacheFolder(track.id, '${folder.path}/audio.mp3');
      final integrity = Map<String, dynamic>.from(
        jsonDecode(await File('${folder.path}/integrity.json').readAsString()),
      );
      final names = integrity.keys.toList()..sort();
      final ordered = {for (final name in names) name: integrity[name]};
      final entry = ['mp3', 'm4a', 'ts', 'm3u8']
          .map((e) => File('${folder.path}/audio.$e'))
          .where((f) => f.existsSync())
          .first;
      var bytes = 0;
      for (final name in names) {
        if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name)) {
          throw const ProofFailure('cache_integrity_failed');
        }
        bytes += await File('${folder.path}/$name').length();
      }
      final duration = await decodeAudio(entry.path);
      final recovered = CachedAudio(
        track.id,
        entry.path,
        sha256.convert(utf8.encode(jsonEncode(ordered))).toString(),
        bytes,
        duration,
      );
      await cache.verify(
        recovered,
        expectedTrack: track,
        requireIdentity: !demo,
      );
      store.saveAsset(recovered, identityVerified: !demo);
      return recovered;
    } catch (_) {
      // Preserve an old/suspect publication until a proven replacement succeeds.
      return null;
    }
  }

  Future<Directory> _safeCacheFolder(String id, String entry) async {
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(id)) {
      throw const ProofFailure('cache_path_invalid');
    }
    final expected = Directory('${cacheDirectory.path}/$id');
    final root = cacheDirectory.absolute.path
        .replaceAll('\\', '/')
        .toLowerCase();
    final actual = (await expected.resolveSymbolicLinks())
        .replaceAll('\\', '/')
        .toLowerCase();
    final parent = (await File(
      entry,
    ).parent.resolveSymbolicLinks()).replaceAll('\\', '/').toLowerCase();
    if (actual != '$root/$id' || parent != actual) {
      throw const ProofFailure('cache_path_invalid');
    }
    return expected;
  }

  Future<void> _deleteAsset(String id) async {
    final folder = Directory('${cacheDirectory.path}/$id');
    if (await folder.exists()) {
      final safe = await _safeCacheFolder(id, '${folder.path}/audio.mp3');
      await safe.delete(recursive: true);
    }
    store.forgetAsset(id);
  }

  Future<void> enforceQuota() async {
    final protected = {if (current != null) current!.id, ?downloadId};
    for (final id in store.evictionOrder(protected)) {
      if (store.usedBytes(pinned: false) <= quota) break;
      await _deleteAsset(id);
    }
    if (store.usedBytes(pinned: false) > quota) {
      message = 'Cache budget reached. The current track is protected.';
    }
    _notify();
  }

  Future<void> setQuota(int bytes) async {
    store.setSetting('quota_bytes', bytes);
    await enforceQuota();
  }

  Future<void> pinTrack(String id) async {
    store.pinTrack(id, !store.individuallyPinned(id));
    _notify();
    if (store.isPinned(id)) {
      unawaited(_pumpPins());
    } else {
      await enforceQuota();
    }
  }

  Future<void> pinPile(int id, bool value) async {
    store.pinPile(id, value);
    _notify();
    if (value) {
      unawaited(_pumpPins());
    } else {
      await enforceQuota();
    }
  }

  bool _pumping = false;
  Future<void> _pumpPins() async {
    if (_pumping ||
        disposed ||
        offline ||
        loading ||
        downloadId != null ||
        demo ||
        DateTime.now().isBefore(_nextPinAttempt)) {
      return;
    }
    _pumping = true;
    try {
      for (final id in store.pendingPins) {
        if (!store.isPinned(id)) continue;
        if (disposed || offline || loading) break;
        final track = store.track(id);
        if (track == null) continue;
        try {
          await ensureAsset(track);
        } catch (e) {
          store.trackError(id, categoryOf(e));
          _nextPinAttempt = DateTime.now().add(const Duration(minutes: 2));
          _failure(e);
          break;
        }
      }
    } finally {
      _pumping = false;
      _notify();
    }
  }

  int createPile(String name) {
    final id = store.createPile(name);
    _notify();
    return id;
  }

  void renamePile(int id, String name) {
    store.renamePile(id, name);
    _notify();
  }

  void deletePile(int id) {
    store.deletePile(id);
    if (pileId == id) browse('library');
    _notify();
  }

  void addToPile(int pile, String track) {
    store.addToPile(pile, track);
    _notify();
    unawaited(_pumpPins());
  }

  void removeOccurrence(int id) {
    store.removeOccurrence(id);
    _notify();
  }

  void cancelDownload() {
    unawaited(stopPlayback());
  }

  void _failure(Object error, {StackTrace? stack, bool audioMessage = true}) {
    recordRuntimeFailure(error, stack, reporter: _writeAudioDiagnostic);
    final category =
        error is FileSystemException &&
            [28, 112].contains(error.osError?.errorCode)
        ? 'storage_full'
        : categoryOf(error);
    store.report(category);
    try {
      File('${store.directory.path}/runtime-error.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          ...runtimeDiagnostic(error, stack),
          'category': category,
        }),
      );
    } catch (_) {
      /* Status and controls still work if the report cannot save. */
    }
    if (audioMessage) message = friendlyError(category);
    _notify();
  }

  /// Inspect a user-named recording locally without exporting catalog text or guessing a version.
  void _inspectNamedRecording(Map request) {
    /// Compare only the explicit display metadata supplied for this diagnostic request.
    String normalized(String value) =>
        value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    // Retain matching identities only inside the application boundary.
    final matches = store
        .rows(view: 'vk')
        .where(
          (row) =>
              normalized(row.track.title) ==
                  normalized(request['title'] as String) &&
              normalized(row.track.artist) ==
                  normalized(request['artist'] as String),
        )
        .toList();
    // Prefer the already selected exact identity only when its metadata matches the report.
    final selected = matches
        .where((row) => row.track.id == current?.id)
        .firstOrNull;
    // Reject ambiguous names rather than silently choosing a different recording.
    final target = selected ?? (matches.length == 1 ? matches.single : null);
    File(
      '${store.directory.path}/named-recording-status.json',
    ).writeAsStringSync(
      jsonEncode({
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'report_id': request['nonce'],
        'catalog_matches': matches.length,
        'listed_matches': matches
            .where((row) => provider.libraryPosition(row.track.id) != null)
            .length,
        'selection_matches': selected != null,
        'ambiguous': matches.length > 1 && selected == null,
        'checking': request['command'] == 'check-recording' && target != null,
      }),
    );
    // Run existing main-player acceptance only for an unambiguous requested identity.
    if (request['command'] == 'check-recording' && target != null) {
      unawaited(_checkSample(targetId: target.track.id));
    }
  }

  void _pollControl() {
    if (demo || disposed || !enableLocalControls) return;
    final file = File('${store.directory.path}/control.json');
    try {
      if (!file.existsSync() || file.lengthSync() > 1024) return;
      final raw = jsonDecode(file.readAsStringSync());
      // Permit only a bounded named-music diagnostic, never arbitrary paths, URLs or browser operations.
      if (raw is Map &&
          ['inspect-recording', 'check-recording'].contains(raw['command'])) {
        // Reject malformed text and replayed requests before any catalog lookup.
        if (raw.length != 4 ||
            raw.keys.any(
              (key) => !['command', 'nonce', 'title', 'artist'].contains(key),
            ) ||
            raw['nonce'] is! String ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(raw['nonce'] as String) ||
            store.setting('control_nonce') == raw['nonce'] ||
            ['title', 'artist'].any(
              (key) =>
                  raw[key] is! String ||
                  (raw[key] as String).trim().isEmpty ||
                  (raw[key] as String).length > 160,
            )) {
          return;
        }
        store.setSetting('control_nonce', raw['nonce']);
        _inspectNamedRecording(raw);
        return;
      }
      if (raw is! Map ||
          raw.length != 2 ||
          raw.keys.any((k) => !['command', 'nonce'].contains(k)) ||
          ![
            'restart',
            'check',
            'play',
            'play-current',
            'play-uncached',
            'play-deep',
            'play-last',
            'play-old-1',
            'play-old-10',
            'play-old-25',
            'play-old-50',
            'play-old-100',
            'play-old-250',
            'play-cached',
            'audible',
            'pause',
            'resume',
            'seek-middle',
            'stop',
            'next',
            'refresh-head',
            'refresh-full',
            'metadata-summary',
            'inspect-current',
            'inspect-old',
            'inspect-lyrics',
            'inspect-library',
            'write-diagnostics',
            'mute',
            'repair-mismatched-cache',
            'check-repaired',
            'check-current',
            'check-old',
            'check-queue-normal',
            'check-queue-shuffle',
          ].contains(raw['command']) ||
          raw['nonce'] is! String ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(raw['nonce'] as String) ||
          store.setting('control_nonce') == raw['nonce']) {
        return;
      }
      store.setSetting('control_nonce', raw['nonce']);
      // Silence only the app's own player before any separately requested live playback check.
      if (raw['command'] == 'mute') unawaited(volume(0));
      // Export only existing evidence; this fixed command must not access VK pages.
      if (raw['command'] == 'write-diagnostics') {
        unawaited(
          writeDiagnosticReport(raw['nonce'] as String)
              .catchError((Object error) {
                _failure(const ProofFailure('diagnostics_export_failed'));
              }),
        );
      }
      if ([
        'check-queue-normal',
        'check-queue-shuffle',
      ].contains(raw['command'])) {
        unawaited(
          checkQueueStartup(shuffled: raw['command'] == 'check-queue-shuffle'),
        );
      }
      if (raw['command'] == 'check-old') {
        final list = store.rows(view: 'vk');
        if (list.isNotEmpty) {
          unawaited(
            _checkSample(
              targetId:
                  list[(list.length - 25).clamp(0, list.length - 1)].track.id,
            ),
          );
        }
      }
      if (raw['command'] == 'check-repaired') {
        unawaited(checkRepairedControls());
      }
      if (raw['command'] == 'check-current' && current != null) {
        unawaited(_checkSample(targetId: current!.id));
      }
      if (raw['command'] == 'repair-mismatched-cache') {
        unawaited(repairMismatchedCache());
      }
      if (raw['command'] == 'metadata-summary') _reportMetadataSummary();
      // Run read-only provider diagnostics only for this explicit fixed command.
      if (raw['command'] == 'inspect-library') {
        unawaited(inspectLibraryMembership());
      }
      if (raw['command'] == 'inspect-lyrics') {
        final track = store
            .rows(view: 'vk')
            .where(
              (row) => store.metadata(row.track.id)['lyricsAvailable'] == true,
            )
            .firstOrNull
            ?.track;
        if (track != null) unawaited(enrichTrack(track.id, force: true));
      }
      if (raw['command'] == 'inspect-current' ||
          raw['command'] == 'inspect-old') {
        final list = raw['command'] == 'inspect-old'
            ? store.rows(view: 'vk')
            : const <LibraryRow>[];
        final track = raw['command'] == 'inspect-old' && list.isNotEmpty
            ? list[(list.length - 25).clamp(0, list.length - 1)].track
            : current;
        if (track != null) unawaited(enrichTrack(track.id, force: true));
      }
      if (raw['command'] == 'refresh-head') unawaited(refresh(full: false));
      if (raw['command'] == 'refresh-full') unawaited(refresh());
      if (raw['command'] == 'play' && rows.isNotEmpty) {
        unawaited(playLibrary(rows));
      }
      if ((raw['command'] == 'play-deep' || raw['command'] == 'play-last') &&
          rows.isNotEmpty) {
        final visible = rows;
        final index = raw['command'] == 'play-last'
            ? visible.length - 1
            : (visible.length - 1).clamp(0, 2000);
        _writeAudioDiagnostic({
          'stage': 'ordinary_selection',
          'ordinal': index,
          'rows': visible.length,
        });
        unawaited(playRows(visible, index));
      }
      if ([
        'play-old-1',
        'play-old-10',
        'play-old-25',
        'play-old-50',
        'play-old-100',
        'play-old-250',
      ].contains(raw['command'])) {
        // Freeze the test set before selecting; later sync must not change
        // which recording a repeated fixed command addresses.
        final sample = _oldAudioSample ??= store.rows(view: 'vk');
        if (sample.isNotEmpty) {
          final offset = int.parse((raw['command'] as String).split('-').last);
          final index = (sample.length - offset).clamp(0, sample.length - 1);
          _writeAudioDiagnostic({
            'stage': 'old_audio_selection',
            'ordinal': index,
            'rows': sample.length,
            'offset_from_end': offset,
            'music_age_bucket': provider.musicAgeBucket(sample[index].track.id),
          });
          unawaited(playRows(sample, index));
        }
      }
      if (raw['command'] == 'play-current') unawaited(playCurrent());
      if (raw['command'] == 'audible') unawaited(volume(50));
      if (raw['command'] == 'play-cached') {
        final visible = rows;
        final index = visible.indexWhere(
          (row) => store.asset(row.track.id) != null,
        );
        if (index >= 0) unawaited(playRows(visible, index));
      }
      if (raw['command'] == 'play-uncached') {
        final visible = rows;
        final index = visible.indexWhere(
          (row) => store.asset(row.track.id) == null,
        );
        if (index >= 0) unawaited(playRows(visible, index));
      }
      if (raw['command'] == 'pause' && player.state.playing) {
        unawaited(togglePlay());
      }
      if (raw['command'] == 'resume' && !loading && !player.state.playing) {
        unawaited(togglePlay());
      }
      if (raw['command'] == 'seek-middle' && !loading && current != null) {
        unawaited(seek(current!.duration / 2));
      }
      if (raw['command'] == 'stop') unawaited(stopPlayback());
      if (raw['command'] == 'next') unawaited(next());
      if (raw['command'] == 'restart') _restartRequested = true;
      if (raw['command'] == 'check' && autoSync) _acceptanceRequested = true;
    } catch (_) {
      store.report('control_invalid');
    }
  }

  Future<void> _restart() async {
    try {
      store.report('app_restarting');
      await runtime.restartAfter(shutdown);
    } catch (e) {
      if (!disposed) _failure(e);
    }
  }

  void _cancelCheck(String reason) {
    if (!_checking || _checkCancelled?.isCompleted == true) return;
    _checkCancelReason = reason;
    if (reason != 'deadline' && reason != 'shutdown') ++_request;
    _checkCancelled?.complete();
    if (_checkGeneration == _cancelDownload) {
      _cancelPendingDownloads();
      _activeCache?.cancel();
      _downloads.clear();
      _streamReady.clear();
      unawaited(provider.cancelResolution());
    }
  }

  Future<void> checkOfflineControls() => _checkSample(cachedOnly: true);

  Future<void> checkRepairedControls() async {
    var id = store.setting('recording_repair_sample_id');
    if (id is! String) {
      final verified = store.rows().where((row) {
        final asset = store.asset(row.track.id);
        return asset != null &&
            File('${File(asset.entry).parent.path}/recording.json')
                .existsSync();
      }).toList();
      if (verified.length != 1) return;
      id = verified.single.track.id;
      store.setSetting('recording_repair_sample_id', id);
    }
    await _checkSample(targetId: id);
  }

  /// Probe one stable uncached recording through the real full-queue startup path.
  /// The fixed control accepts no identities/paths and refuses audible playback.
  Future<void> checkQueueStartup({required bool shuffled}) async {
    if (disposed || _checking) return;
    String? refusal;
    if (!muted || player.state.volume != 0) {
      refusal = 'diagnostic_requires_mute';
    }
    if (offline || !provider.connected) refusal ??= 'vk_not_connected';
    if (refusal == null && _queueStartupTarget == null) {
      final candidates = store
          .rows()
          .where((row) => !row.offline && !isProviderRestricted(row.error))
          .toList();
      if (candidates.isEmpty) {
        refusal = 'diagnostic_no_uncached_tracks';
      } else {
        _queueStartupTarget = candidates[candidates.length ~/ 2].track.id;
      }
    }
    if (refusal != null) {
      File('${store.directory.path}/queue-check.json').writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'running': false,
          'passed': false,
          'category': refusal,
          'queue_mode': shuffled ? 'shuffle' : 'normal',
        }),
      );
      return;
    }
    await _checkSample(
      targetId: _queueStartupTarget,
      startupOnly: true,
      queueShuffle: shuffled,
    );
  }

  Future<void> _checkSample({
    bool cachedOnly = false,
    String? targetId,
    bool startupOnly = false,
    bool? queueShuffle,
  }) {
    if (_checkTask != null) return _checkTask!;
    final task = _runSampleCheck(
      cachedOnly: cachedOnly,
      targetId: targetId,
      startupOnly: startupOnly,
      queueShuffle: queueShuffle,
    );
    _checkTask = task;
    task.whenComplete(() {
      if (identical(_checkTask, task)) _checkTask = null;
    });
    return task;
  }

  Future<void> _runSampleCheck({
    bool cachedOnly = false,
    String? targetId,
    bool startupOnly = false,
    bool? queueShuffle,
  }) async {
    if (_checking || (!cachedOnly && (offline || !provider.connected))) return;
    _acceptanceRequested = false;
    _checking = true;
    _checkCancelled = Completer<void>();
    _checkCancelReason = null;
    _checkGeneration = _cancelDownload;
    final watch = Stopwatch()..start();
    final savedQueue = queue.toJson();
    var ownedRequest = _request;
    var stage = 'preparing';
    var lastBytes = 0;
    var lastProgress = 0;
    StreamingAudio? checkStream;
    List<LibraryRow>? queueRows;
    final result = <String, Object>{
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'running': true,
      'fresh_offline_process': cachedOnly,
      'player': 'main',
      if (queueShuffle != null)
        'queue_mode': queueShuffle ? 'shuffle' : 'normal',
    };
    void checkpoint([String? next]) {
      if (next != null) stage = next;
      if (downloadBytes > lastBytes) {
        lastBytes = downloadBytes;
        lastProgress = watch.elapsedMilliseconds;
      }
      result.remove('transfer_stage');
      result.addAll({
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'stage': stage,
        'elapsed_ms': watch.elapsedMilliseconds,
        'received_bytes': lastBytes,
        'last_progress_ms': lastProgress,
        'position_ms': player.state.position.inMilliseconds,
        'duration_ms': player.state.duration.inMilliseconds,
        'buffering': player.state.buffering,
        'playing': player.state.playing,
        'native_category': ?_lastNativeCategory,
        'native_signals': _nativeSignals,
        'transfer_stage': ?downloadStage,
        'cancel_reason': ?_checkCancelReason,
      });
      File(
        '${store.directory.path}/${startupOnly
            ? 'queue-check'
            : cachedOnly
            ? 'offline-check'
            : 'sample-check'}.json',
      ).writeAsStringSync(jsonEncode(result));
    }

    Future<T> checked<T>(Future<T> future) => Future.any<T>([
      future,
      _checkCancelled!.future.then<T>(
        (_) => throw const ProofFailure('cancelled'),
      ),
    ]);
    Future<void> start(LibraryRow row) async {
      final entries = queueRows ?? [row];
      final selected = entries.indexWhere(
        (entry) => entry.track.id == row.track.id,
      );
      if (selected < 0) throw const ProofFailure('main_control_start_failed');
      if (queueShuffle != null) queue.shuffle = queueShuffle;
      final operation = playRows(entries, selected, diagnostic: true);
      ownedRequest = _request;
      await checked(operation);
      result['selected_identity_preserved'] = current?.id == row.track.id;
      if (current?.id != row.track.id ||
          !player.state.playing ||
          player.state.position.inMilliseconds < 100) {
        final failure = store
            .rows()
            .firstWhere((r) => r.track.id == row.track.id)
            .error;
        throw ProofFailure(failure ?? 'main_control_start_failed');
      }
    }

    Future<void> stop() async {
      final operation = stopPlayback(diagnostic: true);
      ownedRequest = _request;
      await checked(operation);
      if (loading || player.state.playing) {
        throw const ProofFailure('main_control_stop_failed');
      }
    }

    final timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => checkpoint(),
    );
    final deadline = Timer(
      const Duration(minutes: 3),
      () => _cancelCheck('deadline'),
    );
    try {
      final rows = store.rows();
      if (queueShuffle != null) queueRows = rows;
      final accepted = store.setting('acceptance_sample_id');
      final lastSample = accepted is String && store.asset(accepted) != null
          ? accepted
          : current?.id;
      final row = targetId != null
          ? rows.firstWhere((row) => row.track.id == targetId)
          : cachedOnly
          ? rows.firstWhere(
              (row) => row.offline && row.track.id == lastSample,
              orElse: () => rows.firstWhere((row) => row.offline),
            )
          : rows.firstWhere((row) => !row.offline, orElse: () => rows.first);
      final sample = row.track;
      final wasCached = row.offline;
      result['was_cached'] = wasCached;
      if (queueRows != null) result['queue_size'] = queueRows.length;
      result['selection_had_error'] = row.error != null;
      _checkingTrack = sample.id;
      checkpoint('main_play');
      // Exercise the same controller methods bound to the visible UI, using
      // the app's real player/audio output. No separate muted stream player.
      // Diagnostic playback writes no history and does not persist its queue.
      await start(row);
      checkStream = _streams[sample.id];
      result.addAll({
        'streamed': _playingStream == sample.id,
        'first_audio_ms': watch.elapsedMilliseconds,
        if (!wasCached) ..._sourceTimings,
        if (!wasCached && _sourceTimings['source_return_ms'] is int)
          'native_start_ms':
              watch.elapsedMilliseconds -
              (_sourceTimings['source_return_ms'] as int),
        'played_before_complete': store.asset(sample.id) == null,
        'main_play': true,
      });
      if (startupOnly) {
        result['passed'] = true;
        checkpoint('startup_complete');
        return;
      }
      checkpoint('main_pause');
      await checked(togglePlay(diagnostic: true));
      await checked(
        waitUntil(() => !player.state.playing, 'main_control_pause_failed'),
      );
      // Position stream events may still be queued after Pause. Measure the
      // native playback clock instead of treating a late event as more audio.
      if (!await checked(player.isPaused())) {
        throw const ProofFailure('main_control_pause_failed');
      }
      // During stream startup mpv can correct its initial timestamp even
      // while paused. Require three stable native readings (bounded to 2 s),
      // then measure a separate 300 ms window; continuous progress still fails.
      Future<double> clockSeconds() async {
        final value = await checked(player.clockSeconds());
        if (value == null || !value.isFinite || value < 0) {
          throw const ProofFailure('main_control_pause_failed');
        }
        return value;
      }

      var pausedSeconds = await clockSeconds();
      final settling = Stopwatch()..start();
      var stable = 0;
      while (stable < 3) {
        if (settling.elapsed >= const Duration(seconds: 2)) {
          throw const ProofFailure('main_control_pause_failed');
        }
        await checked(Future<void>.delayed(const Duration(milliseconds: 100)));
        final current = await clockSeconds();
        stable = (current - pausedSeconds).abs() <= 0.002 ? stable + 1 : 0;
        pausedSeconds = current;
      }
      result['pause_settle_ms'] = settling.elapsedMilliseconds;
      final pausedAt = Duration(milliseconds: (pausedSeconds * 1000).round());
      result['pause_position_ms'] = pausedAt.inMilliseconds;
      await checked(Future<void>.delayed(const Duration(milliseconds: 300)));
      final afterSeconds = await checked(player.clockSeconds());
      result['pause_after_ms'] = afterSeconds == null
          ? -1
          : (afterSeconds * 1000).round();
      if (!await checked(player.isPaused()) ||
          afterSeconds == null ||
          !afterSeconds.isFinite ||
          (afterSeconds - pausedSeconds).abs() > 0.01) {
        throw const ProofFailure('main_control_pause_failed');
      }
      result['main_pause'] = true;
      checkpoint('main_resume');
      await checked(togglePlay(diagnostic: true));
      await checked(
        waitUntil(
          () =>
              player.state.playing &&
              player.state.position >
                  pausedAt + const Duration(milliseconds: 150),
          'main_control_resume_failed',
        ),
      );
      result['main_resume'] = true;
      checkpoint('main_seek');
      final target = player.state.duration.inMilliseconds / 2000;
      result['seek_target_ms'] = (target * 1000).round();
      await checked(seek(target, diagnostic: true));
      await checked(
        waitUntil(
          () => player.state.position.inMilliseconds > target * 1000 + 150,
          'main_control_seek_failed',
          timeout: const Duration(seconds: 45),
        ),
      );
      result['main_seek'] = true;
      result['stream_seek'] = _playingStream == sample.id;
      checkpoint('complete_cache');
      final asset = await checked(ensureAsset(sample));
      store.setSetting('acceptance_sample_id', sample.id);
      checkpoint('main_stop');
      await stop();
      result['main_stop'] = true;
      checkpoint('local_play_seek');
      await start(row);
      if (_playingStream != null) {
        throw const ProofFailure('local_play_used_stream');
      }
      final localTarget = player.state.duration.inMilliseconds / 2000;
      await checked(seek(localTarget, diagnostic: true));
      await checked(
        waitUntil(
          () => player.state.position.inMilliseconds > localTarget * 1000 + 150,
          'main_local_seek_failed',
        ),
      );
      await stop();
      result.addAll({
        'passed': true,
        'complete_bytes': asset.bytes,
        'duration': asset.duration,
        'local_play_seek': true,
        'was_cached': wasCached,
        'offline_mode': offline,
        'provider_connected': provider.connected,
      });
      store.report(
        cachedOnly
            ? 'offline_controls_passed'
            : wasCached
            ? 'cached_sample_controls_passed'
            : 'stream_cache_controls_passed',
        count: store.count,
      );
      message = 'Sample verified: complete cache and player controls.';
    } catch (e) {
      result.addAll({'passed': false, 'category': categoryOf(e)});
      if (_checkCancelReason == null && !disposed) _failure(e);
    } finally {
      deadline.cancel();
      timer.cancel();
      // A newer foreground request owns the player and queue immediately.
      // Never stop or restore over it while the cancelled check unwinds.
      if (_request == ownedRequest) {
        final completionMessage = message;
        if (!disposed) {
          await stopPlayback(diagnostic: true);
          message = completionMessage;
        }
        queue.restore(savedQueue);
      }
      final sampleId = _checkingTrack;
      _checkingTrack = null;
      if (sampleId != null &&
          _playingStream != sampleId &&
          identical(_streams[sampleId], checkStream)) {
        _streams.remove(sampleId);
        await checkStream?.close(cancel: _checkCancelReason != null);
      }
      result['running'] = false;
      checkpoint();
      _checkGeneration = null;
      _checking = false;
      _notify();
    }
  }

  Future<void> shutdown() async {
    if (disposed) return;
    _finishListening();
    _saveQueue();
    _cancelSyncActivity();
    ++_connectionGeneration;
    _cancelCheck('shutdown');
    ++_request;
    disposed = true;
    _cancelPendingDownloads();
    _activeCache?.cancel();
    _tick?.cancel();
    _scheduler?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _closeStreams();
    artwork.close();
    await _volumeTail;
    await player.dispose();
    await provider.disconnect();
    await _checkTask;
    // Pending download work may still unwind; only close after it releases DB.
    await _downloadTail;
    await _downloadCancellations.close();
    // Drain optional reports after producers stop, without holding shutdown indefinitely.
    try {
      await _diagnosticStore.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      /* A failed optional report cannot prevent app closure. */
    }
    store.report('app_closed', count: store.count);
    store.close();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}

bool isProviderRestricted(String? category) =>
    category == 'audio_restricted' ||
    category?.startsWith('audio_restricted_') == true ||
    category == 'audio_play_control_disabled';

String friendlyError(String category) => switch (category) {
  'cache_identity_unverified' => 'This older download needs an online recording check before playback. Its original files are preserved.',
  'audio_identity_mismatch' || 'audio_identity_unverified' => 'VK did not provide audio bound to this exact recording. Playback stopped to avoid the wrong song.',
  'audio_duration_mismatch' => 'The audio does not match this recording’s duration. Playback stopped; the existing files are preserved.',
  'private_signin_in_progress' =>
    'Finish VK sign-in privately, then press Connect VK.',
  'private_signin_required' => 'VK needs sign-in. Open Settings and choose Sign in privately. Saved music is still available.',
  'vk_not_connected' =>
    'Connect VK to load this track. Your saved music is still available.',
  'track_not_cached' =>
    'This song is not saved offline. Reconnect to download it.',
  'cancelled' => 'Download cancelled. You can retry the track.',
  'audio_source_unavailable' || 'audio_source_not_resolved' => 'Ownsemble could not resolve audio for this song. Your saved library is preserved.',
  'audio_restricted' => 'VK restricts this recording and provides no audio source. Other songs and saved music are still available.',
  'audio_restricted_copyright' =>
    'VK restricts this recording at the rights holder request.',
  'audio_restricted_region' =>
    'VK restricts this recording in the current region.',
  'audio_restricted_subscription' =>
    'VK requires a subscription for this recording.',
  'audio_restricted_age' => 'VK applies an age restriction to this recording.',
  'audio_play_control_disabled' =>
    'The selected recording has a disabled Play control in VK.',
  'audio_source_ambiguous' =>
    'VK exposed several sources. Playback stopped to avoid the wrong song.',
  'music_adapter_unsupported' ||
  'play_control_unsupported' ||
  'music_search_unsupported' ||
  'personal_music_unconfirmed' =>
    'VK changed its music page. Your library and cached songs are safe.',
  'music_rows_timeout' || 'music_page_timeout' =>
    'VK’s track list has not finished loading. Playback can be retried.',
  'music_input_timeout' =>
    'VK’s playback control did not respond. Playback was stopped.',
  'player_start_failed' || 'player_start_timeout' =>
    'Audio did not start in the player. Choose Play to retry.',
  'browser_mute_unavailable' =>
    'The background browser could not be silenced. Playback was stopped.',
  'track_not_in_search_results' || 'track_not_loaded' => 'This song was not found within the loading budget. Try again after refresh.',
  'audio_network_failed' || 'audio_http_failed' =>
    'The download could not finish. Check your connection and retry.',
  'cache_path_invalid' || 'cache_integrity_failed' =>
    'The cached file could not be verified. Retry while online.',
  'audio_incomplete' =>
    'VK returned incomplete audio. Retry to resolve a fresh source.',
  'storage_full' => 'Storage is full. Free space or reduce the automatic cache budget, then retry.',
  _ => 'The operation could not finish. Your library is saved; try again.',
};
