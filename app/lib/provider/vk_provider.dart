import 'dart:async';
import 'dart:convert';

import '../media/audio_policy.dart';
import '../media/artwork_policy.dart';
import '../data/music_metadata.dart';
import 'music_navigation.dart';
import 'audio_url_decoder.dart';
import 'source_memory.dart';
import 'library_scanner.dart';
import 'library_navigation.dart';
import '../contracts/music_browser.dart';
import '../contracts/music_provider.dart';
export '../contracts/music_provider.dart';
import 'guarded_input.dart';
import 'progress_budget.dart';

import 'standby_resource.dart';

/// The only module that owns VK page access. No cookies, auth responses,
/// framework stores or arbitrary caller-supplied scripts leave this boundary.
class VkProvider implements MusicProvider {
  final MusicBrowserFactory browserFactory;
  final Future<String> Function() loadAdapter;
  final void Function(String) status;
  final void Function() changed;
  final void Function(Map<String, Object>)? diagnostic;
  int _captureRequests = 0, _captureApproved = 0, _cdpRequests = 0;
  final _requestKinds = <String, int>{};
  final _networkKinds = <String, int>{};
  MusicBrowser? _browser;
  VkProvider? _playback;
  final bool _playbackOnly;
  late final StandbyResource<VkProvider> _standby;
  DateTime _nextWarmAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  final _navigation = MusicNavigation();
  @override
  bool connected = false;
  @override
  bool get privateSignInActive => _privateSignInActive;
  bool _privateSignInActive = false;
  int _privateSignInGeneration = 0;
  bool _capturing = false,
      _yieldScan = false,
      _closed = false,
      _pageLoading = false;
  bool _reusableDocument = false, _networkListening = false;
  int _documentGeneration = 0, _connectionGeneration = 0;
  final _candidates = <Uri>{};
  final _segmentWitnesses = <Uri>{};
  final _sourceMemory = SourceMemory();
  final _musicReferences = <String, String>{};
  final _knownUnavailable = <String, bool>{};
  final _libraryPositions = <String, int>{};
  final _musicAgeBuckets = <String, String>{};
  final _metadata = <String, Map<String, dynamic>>{};
  final _metadataRequests = <String, Future<Map<String, dynamic>>>{};
  VkProvider? _detailsPage;
  Future<void> _metadataLane = Future.value();
  @override
  Map<String, dynamic> observedMetadata(String id) =>
      Map.of(_metadata[id] ?? {});
  @override
  Uri? artworkSource(String id) {
    final value = _metadata[id]?['artworkURL'];
    final uri = value is String ? Uri.tryParse(value) : null;
    return uri != null && allowedArtwork(uri) ? uri : null;
  }

  @override
  String musicAgeBucket(String id) => _musicAgeBuckets[id] ?? 'unknown';
  @override
  int? libraryPosition(String id) => _libraryPositions[id];
  @override
  bool? trackUnavailable(String id) => _knownUnavailable[id];
  @override
  String? musicReference(String id) => _musicReferences[id];
  Future<SyncResult>? _scan;
  Future<void>? _connectionTask;
  final _lock = _OperationLock();
  Completer<void> _terminated = Completer<void>();
  VkProvider({
    required this.browserFactory,
    required this.loadAdapter,
    required this.status,
    required this.changed,
    this.diagnostic,
    bool playbackOnly = false,
  }) : _playbackOnly = playbackOnly {
    if (!playbackOnly) {
      _standby = StandbyResource<VkProvider>(
        create: _newPlaybackPage,
        prepare: (page) async {
          final watch = Stopwatch()..start();
          await page.connect();
          await page._ensurePersonal();
          // Navigation/row presence only: no track extraction, activation or
          // audio download until a user-selected track is being resolved.
          while (!page._closed) {
            final readiness = await page._action('readiness');
            if (readiness['count'] is num && (readiness['count'] as num) > 0) {
              break;
            }
            if (watch.elapsed > const Duration(seconds: 40)) {
              throw const ProofFailure('music_rows_timeout');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (page._closed) throw const ProofFailure('cancelled');
          diagnostic?.call({
            'stage': 'standby_ready',
            'elapsed_ms': watch.elapsedMilliseconds,
          });
        },
        dispose: (page) => page.disconnect(),
        failed: (error) {
          if (categoryOf(error) == 'cancelled') return;
          _nextWarmAttempt = DateTime.now().add(const Duration(minutes: 1));
          if (!_closed) {
            diagnostic?.call({
              'stage': 'standby_failed',
              'category': categoryOf(error),
            });
          }
        },
      );
    }
  }

  VkProvider _newPlaybackPage() {
    late VkProvider page;
    page = VkProvider(
      browserFactory: browserFactory,
      loadAdapter: loadAdapter,
      playbackOnly: true,
      status: (text) {
        if (identical(_playback, page)) status(text);
      },
      changed: changed,
      diagnostic: (report) => diagnostic?.call({
        ...report,
        'independent_page': true,
        'scanning': _scan != null,
        'standby': !identical(_playback, page),
      }),
    );
    return page;
  }

  bool get playbackPageReady => !_playbackOnly && _standby.isReady;
  void preparePlaybackPage() {
    if (_playbackOnly ||
        _privateSignInActive ||
        _closed ||
        !connected ||
        !browserFactory.prepared ||
        _playback != null ||
        DateTime.now().isBefore(_nextWarmAttempt)) {
      return;
    }
    _standby.warm();
  }

  @override
  Future<void> connect() {
    final existing = _connectionTask;
    if (existing != null) return existing;
    final task = _connect();
    _connectionTask = task;
    task.then<void>(
      (_) {
        if (identical(_connectionTask, task)) _connectionTask = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_connectionTask, task)) _connectionTask = null;
      },
    );
    return task;
  }

  Future<void> _connect() async {
    if (_browser != null) {
      if (_privateSignInActive) return;
      await pollRoute();
      return;
    }
    final generation = ++_connectionGeneration;
    _closed = false;
    if (_terminated.isCompleted) _terminated = Completer<void>();
    final terminated = _terminated;
    bool active() => !_closed && generation == _connectionGeneration;
    void requireActive() {
      if (!active()) throw const ProofFailure('cancelled');
    }

    requireMusicBrowserCapabilities(browserFactory);
    _networkListening = false;
    try {
      // This is called only after one-time connection consent (or persisted sync).
      // The application uses its session internally; no profile is inspected.
      final musicStarted = Completer<void>();
      await Future.any<void>([
        browserFactory.prepare(),
        terminated.future.then((_) => throw const ProofFailure('cancelled')),
      ]);
      requireActive();
      // Consent already reached connect: prepare both hidden pages concurrently.
      if (!_playbackOnly && !_privateSignInActive) _standby.warm();
      _browser = browserFactory.create(
        BrowserEvents(
          exited: () {
            if (!active()) return;
            if (!_terminated.isCompleted) _terminated.complete();
            connected = false;
            _capturing = false;
            _pageLoading = false;
            _browser = null;
            _navigation.observe(null);
            changed();
          },
          started: (uri) {
            if (!active()) return;
            _documentGeneration++;
            if (!musicStarted.isCompleted &&
                uri != null &&
                classifyMusicRoute(Uri.tryParse(uri.toString())) ==
                    MusicRoute.music) {
              musicStarted.complete();
            }
            _pageLoading = true;
            connected = false;
            _capturing = false;
          },
          loaded: (uri) {
            if (!active()) return;
            _pageLoading = false;
            _observe(uri);
          },
          historyChanged: (uri) {
            if (active()) _observe(uri);
          },
          errored: () {
            if (!active()) return;
            _pageLoading = false;
            status(
              'VK is taking longer to load. Your local library is available.',
            );
          },
          request: (uri) {
            if (active()) _captureUri(uri);
          },
          allowNavigation: (uri) =>
              uri == null ||
              uri.scheme == 'about' ||
              uri.scheme == 'https' &&
                  [
                    'vk.com',
                    'vk.ru',
                  ].any((h) => uri.host == h || uri.host.endsWith('.$h')),
        ),
      );
      _pageLoading = true;
      await Future.any<void>([
        _browser!.open(
          Uri.parse(
            _playbackOnly && !_privateSignInActive
                ? 'about:blank'
                : 'https://vk.ru/audios',
          ),
        ),
        _terminated.future.then((_) => throw const ProofFailure('cancelled')),
      ]).timeout(const Duration(seconds: 30));
      requireActive();
      await _requireMuted();
      requireActive();
      if (_playbackOnly && !_privateSignInActive) {
        // Capacity only; do not read/extract music until a selection. Starting
        // with a blank document lets this run before any music-page prefetch.
        await _browser!.addDocumentStartScript(
          'performance.setResourceTimingBufferSize(4096);',
        );
        requireActive();
        await _browser!.navigate(Uri.parse('https://vk.ru/audios'));
        // loadUrl returns before navigation starts. Do not classify the initial
        // blank document as a sign-in requirement during that transition.
        await Future.any<void>([
          musicStarted.future,
          _terminated.future.then((_) => throw const ProofFailure('cancelled')),
        ]).timeout(const Duration(seconds: 30));
      }
      if (!_privateSignInActive) await _browser?.hide();
    } catch (_) {
      if (active()) {
        _closed = true;
        connected = false;
        _capturing = false;
        if (!terminated.isCompleted) terminated.complete();
        await _closeBrowser();
        _browser = null;
        _navigation.observe(null);
        changed();
      }
      rethrow;
    }
  }

  void _captureUri(Uri? uri, {bool cdp = false}) {
    if (!_capturing || !_navigation.isMusic || _closed) return;
    _captureRequests++;
    if (uri == null || !allowedAudio(uri)) return;
    if (cdp) _cdpRequests++;
    _captureApproved++;
    final path = uri.path.toLowerCase();
    final kind = path.endsWith('.m3u8')
        ? 'manifest'
        : RegExp(r'\.(?:mp3|m4a)$').hasMatch(path)
        ? 'direct'
        : RegExp(r'\.(?:ts|aac|m4s)$').hasMatch(path)
        ? 'segment'
        : 'other';
    _requestKinds.update(kind, (n) => n + 1, ifAbsent: () => 1);
    if (kind == 'segment' && _segmentWitnesses.length < 64) {
      _segmentWitnesses.add(uri);
    }
    if (audioCandidate(uri)) _candidates.add(uri);
  }

  @override
  Future<void> signInPrivately() async {
    final generation = ++_privateSignInGeneration;
    _privateSignInActive = true;
    connected = false;
    _capturing = false;
    _yieldScan = true;
    changed();
    try {
      // Quiesce other documents before displaying a shared-session login flow.
      await cancelResolution();
      if (!_playbackOnly) await _standby.discard();
      await _detailsPage?.disconnect();
      _detailsPage = null;
      if (!_privateSignInActive || generation != _privateSignInGeneration) {
        throw const ProofFailure('cancelled');
      }
      await connect();
      if (!_privateSignInActive || generation != _privateSignInGeneration) {
        throw const ProofFailure('cancelled');
      }
      await _browser?.showPrivateSignIn();
      status('Finish VK sign-in privately, then return and press Connect VK.');
    } catch (_) {
      if (generation == _privateSignInGeneration) _privateSignInActive = false;
      rethrow;
    }
  }

  @override
  Future<void> finishPrivateSignIn() async {
    if (!_privateSignInActive) return;
    ++_privateSignInGeneration;
    _privateSignInActive = false;
    await _browser?.finishPrivateSignIn();
    changed();
  }

  void _requireBackgroundAccess() {
    if (_privateSignInActive) {
      throw const ProofFailure('private_signin_in_progress');
    }
  }

  void _observe(Uri? uri) {
    _navigation.observe(uri);
    connected = !_privateSignInActive && _navigation.isMusic;
    if (!connected) {
      _capturing = false;
      _sourceMemory.clear();
    }
    changed();
    preparePlaybackPage();
  }

  Future<void> pollRoute() async {
    if (_privateSignInActive) return;
    if (_browser == null || _closed) return;
    final isMusic = await _navigation.refresh(
      readUrl: () async {
        final url = await _musicUrl();
        return url == null ? null : Uri.tryParse(url.toString());
      },
      openMusic: () async {
        _requireBackgroundAccess();
        await _browser!.navigate(Uri.parse('https://vk.ru/audios'));
      },
    );
    _requireBackgroundAccess();
    connected = isMusic;
    changed();
    preparePlaybackPage();
  }

  Future<dynamic> _evaluate(String script) async {
    _requireBackgroundAccess();
    final privateGeneration = _privateSignInGeneration;
    if (_closed || _browser == null) {
      throw const ProofFailure('vk_not_connected');
    }
    final result =
        await Future.any<dynamic>([
          _browser!.evaluate(script),
          _terminated.future.then((_) => throw const ProofFailure('cancelled')),
        ]).timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw const ProofFailure('music_page_timeout'),
        );
    _requireBackgroundAccess();
    if (privateGeneration != _privateSignInGeneration) {
      throw const ProofFailure('cancelled');
    }
    return result;
  }

  Future<Uri?> _musicUrl() async {
    _requireBackgroundAccess();
    final privateGeneration = _privateSignInGeneration;
    if (_browser == null || _closed) throw const ProofFailure('cancelled');
    final url =
        await Future.any<Uri?>([
          _browser!.currentUrl(),
          _terminated.future.then((_) => throw const ProofFailure('cancelled')),
        ]).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ProofFailure('music_page_timeout'),
        );
    _requireBackgroundAccess();
    if (privateGeneration != _privateSignInGeneration) {
      throw const ProofFailure('cancelled');
    }
    return url;
  }

  Future<void> _requireMuted() async {
    if (_browser == null) throw const ProofFailure('vk_not_connected');
    try {
      final muted = await _browser!.isAudioIsolated().timeout(
        const Duration(seconds: 10),
      );
      if (!muted) throw const ProofFailure('browser_mute_unavailable');
    } catch (_) {
      await _closeBrowser();
      throw const ProofFailure('browser_mute_unavailable');
    }
  }

  /// A new selection or Stop releases the old renderer immediately. Closing
  /// this page cannot scroll, stop or disconnect the independent scanner.
  @override
  Future<void> cancelResolution() async {
    final playback = _playback;
    _playback = null;
    if (playback == null) return;
    playback._closed = true;
    if (!playback._terminated.isCompleted) playback._terminated.complete();
    playback._capturing = false;
    playback._candidates.clear();
    await playback._closeBrowser();
  }

  Future<void> _closeBrowser() async {
    try {
      await _browser?.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      // The renderer is already marked closed and natively muted. Cleanup
      // cannot hold the download lane or the application's controls forever.
    }
  }

  Future<bool> _isHidden() async {
    try {
      return await _browser?.isHidden().timeout(const Duration(seconds: 2)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  void _guard() {
    _requireBackgroundAccess();
    if (_closed || !_navigation.isMusic) {
      throw const ProofFailure('private_signin_required');
    }
  }

  Future<Map<String, dynamic>> _action(
    String action, {
    String id = '',
    int waitMs = 0,
    num? since,
    String? musicKey,
    String? musicQuery,
    num? x,
    num? y,
  }) async {
    _guard();
    final value = await _evaluate(
      '(async()=>JSON.stringify(await window.ownsembleMusic.action(${jsonEncode(action)},${jsonEncode(id)},${jsonEncode({'waitMs': waitMs, 'since': ?since, 'musicKey': ?musicKey, 'musicQuery': ?musicQuery, 'x': ?x, 'y': ?y})})))()',
    );
    final data = value is String ? jsonDecode(value) : value;
    if (data is Map && data['error'] != null) {
      final counts = data['counts'];
      const allowed = [
        'musicSearchInputs',
        'targetWidth',
        'targetHeight',
        'viewportWidth',
        'viewportHeight',
        'visibleDocument',
        'hitPresent',
        'hitInsideTarget',
        'hitSameTrack',
        'hitBlockedControl',
        'myMusicTargets',
        'selectedTargets',
        'headingMatch',
        'personalURLMatch',
      ];
      diagnostic?.call({
        'stage': 'action_failed',
        'action': action,
        if (counts is Map)
          'counts': {
            for (final key in allowed)
              if (counts[key] is num &&
                  (counts[key] as num) >= 0 &&
                  (counts[key] as num) <= 100000)
                key: counts[key] as num,
          },
      });
    }
    if (data is Map &&
        data['blocked'] == true &&
        ['play', 'play-position', 'verify-play-hit'].contains(action)) {
      throw const ProofFailure('audio_play_control_disabled');
    }
    return decodeMap(data);
  }

  Future<void> _install() async {
    _guard();
    await _evaluate('(async()=>{${await loadAdapter()}return true;})()');
  }

  Future<void> _ensurePersonal({bool Function()? cancelled}) async {
    _requireBackgroundAccess();
    if (_browser == null) throw const ProofFailure('vk_not_connected');
    final watch = Stopwatch()..start();
    var retryNavigationAt = Duration.zero;
    while (watch.elapsed < const Duration(seconds: 90)) {
      _requireBackgroundAccess();
      if (_closed || cancelled?.call() == true) {
        throw const ProofFailure('cancelled');
      }
      await _navigation.refresh(
        readUrl: () async {
          final u = await _musicUrl();
          return u == null ? null : Uri.tryParse(u.toString());
        },
        openMusic: () async {
          _requireBackgroundAccess();
          await _browser!.navigate(Uri.parse('https://vk.ru/audios'));
        },
      );
      if (!_navigation.isMusic) {
        connected = false;
        changed();
        // Wait for navigation, without evaluating anything off the music route.
        if (_pageLoading ||
            _navigation.isBlankDocument &&
                watch.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        // Do not evaluate scripts or inspect fields on a login page.
        throw const ProofFailure('private_signin_required');
      }
      try {
        await _install();
        final result = await _action(
          watch.elapsed >= retryNavigationAt
              ? 'open-my-music'
              : 'verify-my-music',
        );
        if (result['navigationAttempted'] == true) {
          retryNavigationAt = watch.elapsed + const Duration(seconds: 8);
        }
        if (result['personal'] == true) {
          await _browser?.finishPrivateSignIn().timeout(
            const Duration(seconds: 5),
          );
          connected = true;
          return;
        }
      } on ProofFailure catch (e) {
        if (e.category == 'private_signin_required') rethrow;
        if (e.category == 'cancelled') rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
    throw const ProofFailure('personal_music_unconfirmed');
  }

  Future<Map<String, dynamic>> _read({
    String? targetId,
    bool resolveTarget = false,
    bool includeLyrics = false,
  }) async {
    _guard();
    final data = decodeMap(
      await _evaluate(
        '(async()=>JSON.stringify(await window.ownsembleMusic.read(${jsonEncode({'targetId': ?targetId, 'includeReferences': true, 'includeAvailability': true, 'includeMetadata': true, 'includeLyrics': includeLyrics, if (resolveTarget) 'resolveTarget': true})})))()',
      ),
    );
    final raw = data['tracks'];
    if (raw is! List || raw.length > 50000) {
      throw const ProofFailure('music_adapter_unsupported');
    }
    for (final row in raw.whereType<Map>()) {
      final id = row['id'], extra = row['enrichment'];
      if (id is! String ||
          !RegExp(r'^-?\d+_\d+$').hasMatch(id) ||
          extra is! Map) {
        continue;
      }
      final clean = sanitizeMetadata(extra);
      final artwork = extra['artworkURL'];
      final uri = artwork is String ? Uri.tryParse(artwork) : null;
      if (uri != null && allowedArtwork(uri)) {
        clean['artworkURL'] = uri.toString();
      }
      final lyrics = sanitizeLyrics(
        extra['lyrics'] is Map ? extra['lyrics'] as Map : null,
      );
      if (lyrics != null) clean['lyrics'] = lyrics;
      _metadata[id] = {...?_metadata[id], ...clean};
      if (_metadata.length > 8192) _metadata.remove(_metadata.keys.first);
    }
    if (!_playbackOnly) {
      final shape = data['diagnostics'] is Map
          ? (data['diagnostics'] as Map)['metadataShape']
          : null;
      final values = raw
          .whereType<Map>()
          .map((r) => r['enrichment'])
          .whereType<Map>()
          .toList();
      diagnostic?.call({
        'stage': 'metadata_read',
        'rows': raw.length,
        for (final key in [
          'album',
          'subtitle',
          'artists',
          'artworkURL',
          'uploadedAt',
          'lyricsId',
          'lyricsAvailable',
          'lyrics',
        ])
          key: values.where((v) => v[key] != null && v[key] != false).length,
        'vk_added_verified': 0,
        if (shape is Map)
          'metadata_shape': {
            for (final key in [
              'albumThumb',
              'audioThumb',
              'photo_34',
              'photo_68',
              'photo_135',
              'photo_270',
              'photo_300',
              'photo_600',
              'photo_1200',
              'imageHTTPS',
              'imageUserapi',
              'imageVkuseraudio',
              'imageVkuserphoto',
              'lyricsButtons',
              'menuButtons',
              'lyricsInfo',
              'lyricsInfoText',
            ])
              if (shape[key] is num) key: shape[key],
          },
      });
    }
    final references = data['musicReferences'];
    if (references is List && references.length <= 50000) {
      for (final ref in references.whereType<Map>()) {
        final id = ref['id'], key = ref['musicKey'];
        if (id is String &&
            key is String &&
            RegExp(r'^-?\d+_\d+$').hasMatch(id) &&
            RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(key)) {
          _musicReferences[id] = key;
        }
      }
    }
    if (!_playbackOnly) {
      final userAgent = data['userAgent'];
      final userId = data['userId'];
      if (userAgent is String) {
        for (final row in raw.whereType<Map>()) {
          try {
            final track = Track.fromJson(Map<String, dynamic>.from(row));
            final age = row['musicAgeBucket'];
            if ([
              'before2010',
              '2010to2014',
              '2015to2019',
              '2020plus',
            ].contains(age)) {
              _musicAgeBuckets[track.id] = age as String;
            }
            if (row['unavailable'] == true &&
                (row['url'] is! String ||
                    (row['url'] as String).trim().isEmpty)) {
              _knownUnavailable[track.id] = true;
              _sourceMemory.forget(track.id);
              continue;
            }
            final value = row['url'];
            final uri = value is String
                ? decodeAudioSource(value, userId is num ? userId.toInt() : 0)
                : null;
            if (uri != null) {
              _knownUnavailable[track.id] = false;
              _sourceMemory.remember(track.id, uri, userAgent);
            }
          } on ProofFailure {
            /* Invalid metadata is never a source reference. */
          }
        }
      }
    }
    return data;
  }

  List<Track> _tracks(Map<String, dynamic> data) => (data['tracks'] as List)
      .map((v) => Track.fromJson(Map<String, dynamic>.from(v)))
      .toList();

  Future<Map<String, dynamic>> _readWhenReady(
    bool Function()? cancelled,
  ) async {
    final watch = Stopwatch()..start();
    final budget = ProgressBudget(
      quietLimit: const Duration(seconds: 30),
      hardLimit: const Duration(seconds: 90),
    );
    while (true) {
      await _resolutionGuard(cancelled);
      try {
        return await _read();
      } on ProofFailure catch (e) {
        if (e.category != 'music_adapter_unsupported') rethrow;
      }
      // A selected navigation tab can precede its track list. Wait for actual
      // rows and loading progress instead of failing the first empty render.
      final state = await _action('readiness');
      if (budget.expired(
        watch.elapsed,
        progress: state['count'],
        loading: state['loading'] == true,
      )) {
        diagnostic?.call({
          'stage': 'rows_timeout',
          'rows': state['count'] is num ? state['count'] as num : 0,
          'loading': state['loading'] == true,
        });
        throw const ProofFailure('music_rows_timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
  }

  @override
  Future<SyncResult> sync(
    void Function(List<Track>) merge, {
    required bool fromTop,
    bool newestOnly = false,
    List<String> checkpoint = const [],
  }) {
    if (_privateSignInActive) {
      return Future.error(const ProofFailure('private_signin_in_progress'));
    }
    if (_scan != null) return _scan!;
    _yieldScan = false;
    final future = _lock.run(() async {
      _requireBackgroundAccess();
      await prepareLibraryDocument(
        fromTop: fromTop,
        requireMusicRoute: () async {
          final url = await _musicUrl();
          if (classifyMusicRoute(
                url == null ? null : Uri.tryParse(url.toString()),
              ) !=
              MusicRoute.music) {
            throw const ProofFailure('private_signin_required');
          }
        },
        reload: () async {
          _libraryPositions.clear();
          // Only navigation is permitted on the old document. Require the
          // full route/form/personal witness again on the fresh document.
          final generation = _documentGeneration;
          await _requireMuted();
          _requireBackgroundAccess();
          await _browser!.reload();
          final navigation = Stopwatch()..start();
          while (_documentGeneration == generation || _pageLoading) {
            if (_closed || _yieldScan) throw const ProofFailure('cancelled');
            if (navigation.elapsed >= const Duration(seconds: 30)) {
              throw const ProofFailure('music_page_timeout');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        },
        requirePersonal: _ensurePersonal,
        install: _install,
        reset: () async {
          await _action('reset');
        },
      );
      // Hiding happens only after the guarded personal-music witness succeeds.
      // Progress remains bounded if a provider throttles background loading.
      _requireBackgroundAccess();
      await _browser?.hide();
      final watch = Stopwatch()..start();
      final result = await LibraryScanner(
        elapsed: () => watch.elapsed,
        cancelled: () => _yieldScan || _closed,
        newestOnly: newestOnly,
        checkpoint: checkpoint,
        quietLimit: Duration(seconds: newestOnly ? 5 : 45),
        hardLimit: Duration(seconds: newestOnly ? 15 : 90),
        progress: (count) => status(
          '${newestOnly ? 'Checking newest VK entries' : 'Refreshing VK'} · $count tracks checked · coverage partial',
        ),
        merge: merge,
        read: () async {
          _guard();
          final witness = await _action('verify-my-music');
          if (witness['personal'] != true) {
            throw const ProofFailure('personal_music_unconfirmed');
          }
          try {
            final tracks = _tracks(await _read());
            for (final track in tracks) {
              _libraryPositions.putIfAbsent(
                track.id,
                () => _libraryPositions.length,
              );
            }
            return tracks;
          } on ProofFailure catch (e) {
            if (e.category != 'music_adapter_unsupported') rethrow;
            return [];
          }
        },
        advance: (milliseconds, retry) async {
          final value = await _action(
            retry ? 'retry-pagination' : 'advance',
            waitMs: milliseconds,
          );
          return value['loading'] == true;
        },
      ).run();
      return SyncResult(
        result.count,
        result.continueSweep,
        reason: result.reason,
        head: result.head,
      );
    });
    _scan = future;
    future.then(
      (_) {
        _scan = null;
      },
      onError: (Object _, StackTrace _) {
        _scan = null;
      },
    );
    return future;
  }

  Future<ResolvedAudio?> _resolveReference(
    Track track, {
    String? musicKey,
  }) async {
    final key = _musicReferences[track.id] ?? musicKey;
    if (key == null || !key.startsWith('r1_')) return null;
    final personal = await _action('verify-my-music');
    if (personal['personal'] != true) return null;
    Map<String, dynamic> result;
    try {
      result = await _action(
        'resolve-reference',
        id: track.id,
        musicKey: key.substring(3),
      );
    } on ProofFailure catch (error) {
      if (error.category == 'private_signin_required' ||
          error.category == 'cancelled') {
        rethrow;
      }
      diagnostic?.call({'stage': 'reference_source_unsupported'});
      return null;
    }
    final counts = result['counts'];
    if (counts is Map) {
      diagnostic?.call({
        'stage': 'reference_source',
        'counts': {
          for (final key in [
            'matched',
            'urlsFound',
            'responseNodes',
            'responseBatch',
          ])
            if (counts[key] is num) key: counts[key] as num,
        },
      });
    }
    final value = result['source'];
    final user = result['userId'];
    final agent = result['userAgent'];
    final source = value is String
        ? decodeAudioSource(value, user is num ? user.toInt() : 0)
        : null;
    if (source != null && agent is String && agent.length <= 512) {
      return ResolvedAudio(
        source,
        agent,
        recordingId: track.id,
        evidence: 'exact_reload',
        timings: {'source_from_reference': true, 'page_wait_ms': 0},
      );
    }
    return null;
  }

  @override
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) async {
    _requireBackgroundAccess();
    if (connected && !_closed) {
      final remembered = _sourceMemory.lookup(track.id);
      if (remembered != null) {
        final personal = await _action('verify-my-music');
        if (personal['personal'] == true) {
          diagnostic?.call({
            'stage': 'source_memory_hit',
            'music_age_bucket': musicAgeBucket(track.id),
            'age_ms': DateTime.now()
                .difference(remembered.observed)
                .inMilliseconds,
          });
          return ResolvedAudio(
            remembered.source,
            remembered.userAgent,
            recordingId: track.id,
            evidence: 'metadata_row',
            timings: {'source_from_memory': true, 'page_wait_ms': 0},
          );
        }
      }
    }
    final referenceTried = connected && !_closed;
    if (referenceTried) {
      final reference = await _resolveReference(track, musicKey: musicKey);
      if (reference != null) return reference;
    }
    // Separate hidden pages share the application's environment/session, but
    // never scroll or activate each other's document. No session is exported.
    final watch = Stopwatch()..start();
    final readyBeforeSelection = _standby.isReady;
    final prepared = _standby.take();
    final playback = _playback = prepared.value;
    diagnostic?.call({
      'stage': 'resolve_started',
      'prepared_before_selection': readyBeforeSelection,
    });
    try {
      await prepared.ready;
      final pageReadyMs = watch.elapsedMilliseconds;
      final resolved = await playback._resolveSelected(
        track,
        tryReference: !referenceTried,
        musicKey: _musicReferences[track.id] ?? musicKey,
        cancelled: cancelled,
        prepareCandidate: prepareCandidate,
        manifestSegments: manifestSegments,
      );
      _metadata.addAll(playback._metadata);
      final timings = <String, Object>{
        ...resolved.timings,
        'prepared_before_selection': readyBeforeSelection,
        'page_wait_ms': pageReadyMs,
        'source_resolution_ms': watch.elapsedMilliseconds,
      };
      diagnostic?.call({'stage': 'resolve_finished', ...timings});
      return ResolvedAudio(
        resolved.source,
        resolved.userAgent,
        recordingId: resolved.recordingId,
        evidence: resolved.evidence,
        timings: timings,
      );
    } finally {
      if (identical(_playback, playback)) _playback = null;
      playback._capturing = false;
      playback._candidates.clear();
      if (!_privateSignInActive &&
          !_closed &&
          !playback._closed &&
          playback._reusableDocument) {
        // Exact metadata lookup never activated browser audio. Reuse this
        // muted document; every new selection still rechecks route/form/id.
        await _standby.returnUnused(prepared);
        diagnostic?.call({'stage': 'standby_reused'});
      } else {
        // Activated/failed/cancelled documents can retain detached media.
        playback._closed = true;
        if (!playback._terminated.isCompleted) playback._terminated.complete();
        await prepared.close();
        preparePlaybackPage();
      }
    }
  }

  Future<ResolvedAudio> _resolveSelected(
    Track track, {
    bool tryReference = true,
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) async {
    return _lock.run(() async {
      _reusableDocument = false;
      diagnostic?.call({'stage': 'personal_music'});
      await _ensurePersonal(cancelled: cancelled);
      await _resolutionGuard(cancelled);
      await _install();
      await _browser?.hide();
      await _action('verify-my-music');
      if (tryReference) {
        final reference = await _resolveReference(track, musicKey: musicKey);
        if (reference != null) {
          _reusableDocument = true;
          return reference;
        }
      }
      await _browser!.activate();
      // requestWillBeSent also witnesses renderer/browser-cache requests that
      // may bypass WebResourceRequested. Read only the music URL, never request
      // headers, cookie values, bodies or authentication responses.
      if (!_networkListening) {
        await _browser!.observeRequests((data) {
          if (!_capturing || !_navigation.isMusic || _closed) {
            return;
          }
          final type = ['Media', 'Fetch', 'XHR', 'Other'].contains(data.kind)
              ? data.kind
              : 'non_media';
          _networkKinds.update(type, (n) => n + 1, ifAbsent: () => 1);
          final value = data.uri?.toString();
          if (value is String) {
            final uri = Uri.tryParse(value);
            if (uri != null &&
                (type == 'Media' ||
                    RegExp(
                      r'\.(?:mp3|m3u8|m4a|ts|aac|m4s)$',
                      caseSensitive: false,
                    ).hasMatch(uri.path))) {
              final reason = uri.scheme != 'https'
                  ? 'media_scheme'
                  : uri.userInfo.isNotEmpty
                  ? 'media_userinfo'
                  : uri.hasPort
                  ? 'media_port'
                  : !allowedAudio(uri)
                  ? 'media_host'
                  : 'media_approved';
              _networkKinds.update(reason, (n) => n + 1, ifAbsent: () => 1);
              final extension =
                  RegExp(
                    r'\.(mp3|m3u8|m4a|ts|aac|m4s)$',
                    caseSensitive: false,
                  ).firstMatch(uri.path)?.group(1)?.toLowerCase() ??
                  'other';
              _networkKinds.update(
                'extension_$extension',
                (n) => n + 1,
                ifAbsent: () => 1,
              );
              for (final label in [
                'vkuseraudio',
                'useraudio',
                'userapi',
                'vk-cdn',
                'vkuser',
                'vkuservideo',
                'vkuserlive',
                'mail',
                'okcdn',
                'mycdn',
              ]) {
                if (uri.host.split('.').contains(label)) {
                  _networkKinds.update(
                    'label_$label',
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  );
                }
              }
              if (uri.host.endsWith('.')) {
                _networkKinds.update(
                  'host_trailing_dot',
                  (n) => n + 1,
                  ifAbsent: () => 1,
                );
              }
              for (final tld in ['net', 'com', 'ru', 'me', 'org', 'audio']) {
                if (uri.host.endsWith('.$tld')) {
                  _networkKinds.update(
                    'tld_$tld',
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  );
                }
              }
              for (final suffix in [
                'mycdn.me',
                'vkuser.net',
                'vk.me',
                'vk.com',
                'vk.ru',
                'vkuservideo.net',
                'vkuseraudio.ru',
                'vkusercdn.net',
                'vkcdn.audio',
              ]) {
                if (uri.host == suffix || uri.host.endsWith('.$suffix')) {
                  _networkKinds.update(
                    'service_$suffix',
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  );
                }
              }
            }
            _captureUri(uri, cdp: true);
          }
        });
        _networkListening = true;
      }
      await _action('reset');
      final watch = Stopwatch()..start();
      Map<String, dynamic>? position;
      num? captureSince;
      String userAgent = 'Ownsemble/0.1';
      final budget = ProgressBudget(
        quietLimit: const Duration(seconds: 45),
        hardLimit: const Duration(minutes: 8),
      );
      final seen = <String>{};
      Stopwatch? searchWatch;
      diagnostic?.call({'stage': 'finding_track'});
      while (position == null) {
        await _resolutionGuard(cancelled);
        Map<String, dynamic> data;
        if (searchWatch != null) {
          if (searchWatch.elapsed > const Duration(seconds: 10)) {
            throw const ProofFailure('track_not_in_search_results');
          }
          try {
            data = await _read(targetId: track.id);
          } on ProofFailure catch (error) {
            if (error.category != 'music_adapter_unsupported') {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
        } else {
          data = await _readWhenReady(cancelled);
        }
        final tracks = _tracks(data);
        seen.addAll(tracks.map((t) => t.id));
        if (tracks.any((t) => t.id == track.id)) {
          final binding = data['diagnostics'];
          if (binding is Map) {
            final selectedRows = (data['tracks'] as List)
                .whereType<Map>()
                .where((row) => row['id'] == track.id);
            final selectedValue = selectedRows.firstOrNull?['url'];
            final selectedUri = selectedValue is String
                ? Uri.tryParse(selectedValue)
                : null;
            diagnostic?.call({
              'stage': 'music_binding',
              'music_age_bucket':
                  [
                    'before2010',
                    '2010to2014',
                    '2015to2019',
                    '2020plus',
                  ].contains(selectedRows.firstOrNull?['musicAgeBucket'])
                  ? selectedRows.firstOrNull!['musicAgeBucket'] as String
                  : 'unknown',
              'source_shape': {
                'https': selectedUri?.scheme == 'https',
                'trailing_dot': selectedUri?.host.endsWith('.') == true,
                'tld_ru': selectedUri?.host.endsWith('.ru') == true,
                'tld_net': selectedUri?.host.endsWith('.net') == true,
                'tld_com': selectedUri?.host.endsWith('.com') == true,
                'http': selectedUri?.scheme == 'http',
                'relative': selectedUri?.scheme.isEmpty == true,
                'approved': selectedUri != null && allowedAudio(selectedUri),
                'port': selectedUri?.hasPort == true,
                'userinfo': selectedUri?.userInfo.isNotEmpty == true,
                'hls_component':
                    selectedUri?.path.toLowerCase().contains('.m3u8') == true,
                'hls_path':
                    selectedUri?.path.toLowerCase().contains('/hls/') == true,
                'mp3_component':
                    selectedUri?.path.toLowerCase().contains('.mp3') == true,
                'mpd_component':
                    selectedUri?.path.toLowerCase().contains('.mpd') == true,
                'aac_component':
                    selectedUri?.path.toLowerCase().contains('.aac') == true,
                'blob': selectedUri?.scheme == 'blob',
                'labels': {
                  for (final label in [
                    'vkuseraudio',
                    'useraudio',
                    'userapi',
                    'okcdn',
                    'vk-cdn',
                    'vkuser',
                    'vk',
                  ])
                    label: selectedUri?.host.split('.').contains(label) == true,
                },
              },
              'counts': {
                'userIdPresent':
                    data['userId'] is num && (data['userId'] as num) > 0
                    ? 1
                    : 0,
                'encodedURLs': (data['tracks'] as List)
                    .whereType<Map>()
                    .where(
                      (row) =>
                          row['url'] is String &&
                          (row['url'] as String).contains(
                            '/mp3/audio_api_unavailable.mp3',
                          ),
                    )
                    .length,
                for (final key in [
                  'availableFalse',
                  'deleted',
                  'blocked',
                  'unavailable',
                  'restricted',
                ])
                  'hint_$key':
                      selectedRows.firstOrNull?['availabilityHints'] is Map &&
                          (selectedRows.firstOrNull!['availabilityHints']
                                  as Map)[key] ==
                              true
                      ? 1
                      : 0,
                for (final key in [
                  'modernRows',
                  'modernPropsFound',
                  'modernAudioMatched',
                  'modernURLsFound',
                  'modernDOMMetadata',
                  'musicUnavailable',
                  'musicReloadHashes',
                  'reloadReferences',
                  'musicObjects',
                  'musicArrays',
                  'musicId',
                  'musicOwner',
                  'musicFullId',
                  'musicURL',
                ])
                  if (binding[key] is num) key: binding[key] as num,
              },
            });
          }
          if (data['userAgent'] is String) {
            userAgent = data['userAgent'] as String;
          }
          final direct = _selectedSource(data, track.id);
          if (direct != null) {
            diagnostic?.call({
              'stage': 'source_captured',
              'metadata_candidates': 1,
            });
            _reusableDocument = true;
            return ResolvedAudio(
              direct,
              userAgent,
              recordingId: track.id,
              evidence: 'metadata_row',
            );
          }
          final restriction = (data['tracks'] as List)
              .whereType<Map>()
              .where(
                (row) => row['id'] == track.id && row['unavailable'] == true,
              )
              .firstOrNull;
          if (restriction != null) {
            final reason = restriction['restrictionReason'];
            final category =
                ['copyright', 'region', 'subscription', 'age'].contains(reason)
                ? 'audio_restricted_$reason'
                : 'audio_restricted';
            diagnostic?.call({
              'stage': 'provider_restriction',
              'category': category,
            });
            _reusableDocument = true;
            throw ProofFailure(category);
          }
          final refreshed = await _read(
            targetId: track.id,
            resolveTarget: true,
          );
          final refreshCounts = refreshed['diagnostics'];
          if (refreshCounts is Map) {
            diagnostic?.call({
              'stage': 'target_source_refresh',
              'counts': {
                for (final key in [
                  'targetReloadAttempted',
                  'targetReloadMatched',
                  'targetReloadURLFound',
                ])
                  if (refreshCounts[key] is num) key: refreshCounts[key] as num,
              },
            });
          }
          final refreshedSource = _selectedSource(refreshed, track.id);
          if (refreshedSource != null) {
            _reusableDocument = true;
            return ResolvedAudio(
              refreshedSource,
              userAgent,
              recordingId: track.id,
              evidence: 'exact_reload',
            );
          }
          // Hovering/scrolling the exact row can prefetch its manifest. Start
          // the witness BEFORE play-position, not after its hover and delay.
          _candidates.clear();
          _segmentWitnesses.clear();
          _captureRequests = 0;
          _captureApproved = 0;
          _cdpRequests = 0;
          _requestKinds.clear();
          _networkKinds.clear();
          final boundary = await _action('begin-audio-capture');
          final since = boundary['since'];
          if (since is! num || !since.isFinite || since < 0) {
            throw const ProofFailure('adapter_response_invalid');
          }
          captureSince = since;
          diagnostic?.call({
            'stage': 'capture_boundary',
            'historical_audio_sources':
                ((await _action('audio-resources', since: 0))['urls'] as List)
                    .length,
            'timing_entries_before': boundary['timingEntriesBefore'] is int
                ? boundary['timingEntriesBefore'] as int
                : 0,
          });
          _capturing = true;
          final result = await _action('play-position', id: track.id);
          if (result['position'] is Map) {
            position = Map<String, dynamic>.from(result['position']);
          } else {
            throw const ProofFailure('play_control_unsupported');
          }
          break;
        }
        status('Finding ${track.title} in VK…');
        if (budget.expired(watch.elapsed, progress: seen.length)) {
          throw const ProofFailure('track_not_loaded');
        }
        if (searchWatch == null) {
          try {
            final search = await _action(
              'search-track',
              musicQuery: track.title,
            );
            diagnostic?.call({
              'stage': 'music_search_input',
              'counts': Map<String, Object>.from(search['counts'] as Map),
            });
          } on ProofFailure catch (error) {
            if (error.category == 'private_signin_required' ||
                error.category == 'cancelled') {
              rethrow;
            }
            throw const ProofFailure('music_search_unsupported');
          }
          diagnostic?.call({'stage': 'music_search', 'searched': true});
          searchWatch = Stopwatch()..start();
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await _action('pause');
      await _action('verify-my-music');
      // The native click resolves a source; the app's local player owns sound.
      await _evaluate('''(()=>{
        for(const audio of document.querySelectorAll('audio')) audio.muted=true;
        if(!window.ownsembleCaptureMute){
          window.ownsembleCaptureMute=true;
          document.addEventListener('play',event=>{
            if(event.target?.tagName==='AUDIO')event.target.muted=true;
          },true);
        }
        return true;
      })()''');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      var timingCandidates = 0;
      var captured = false;
      try {
        _capturing = true;
        diagnostic?.call({'stage': 'activating_track'});
        final fresh = await _action('play-position', id: track.id);
        position = Map<String, dynamic>.from(fresh['position'] as Map);
        final before = Map<String, Object>.from(
          (await _action('probe-playback', id: track.id))['counts'] as Map,
        );
        diagnostic?.call({'stage': 'playback_controls', 'counts': before});
        await _tap(
          track.id,
          (position['x'] as num).toDouble(),
          (position['y'] as num).toDouble(),
        );
        final after = Map<String, Object>.from(
          (await _action('probe-playback', id: track.id))['counts'] as Map,
        );
        diagnostic?.call({
          'stage': 'activated_playback_controls',
          'counts': after,
        });
        // A Play icon also remains visible while VK initializes detached media.
        // A second click at that point toggles/cancels the pending selection.
        // Send one trusted activation and observe it without toggling again.
        final sourceWatch = Stopwatch()..start();
        var preparedCandidate = false;
        Uri? boundSource;
        var boundEvidence = 'metadata_row';
        var eligible = <Uri>{};
        var matchedCount = 0;
        var nextReport = Duration.zero;
        while (sourceWatch.elapsed < const Duration(seconds: 30)) {
          await _resolutionGuard(cancelled);
          // This witness also rejects sign-in forms appearing on a music URL.
          await _action('verify-my-music');
          try {
            final selected = _selectedSource(
              await _read(targetId: track.id),
              track.id,
            );
            if (selected != null) {
              boundSource = selected;
              boundEvidence = 'metadata_row';
            }
          } on ProofFailure catch (e) {
            if (e.category != 'music_adapter_unsupported') rethrow;
          }
          final observed = await _action(
            'audio-resources',
            since: captureSince,
          );
          final urls = observed['urls'];
          if (urls is List && urls.length <= 32) {
            for (final value in urls) {
              if (value is! String) continue;
              final uri = Uri.tryParse(value);
              if (uri != null && audioCandidate(uri)) _candidates.add(uri);
            }
            timingCandidates = urls.length;
          }
          final segments = observed['segments'];
          if (segments is List && segments.length <= 64) {
            for (final value in segments.whereType<String>()) {
              final uri = Uri.tryParse(value);
              if (uri != null && allowedAudio(uri)) _segmentWitnesses.add(uri);
            }
          }
          if (boundSource == null) {
            final current = await _action('current-audio-source', id: track.id);
            final value = current['source'];
            if (current['matched'] == true && value is String) {
              final user = current['userId'];
              boundSource = decodeAudioSource(
                value,
                user is num ? user.toInt() : 0,
              );
              boundEvidence = 'native_player';
            }
          }
          // Timing/segments can belong to a prefetched NEXT recording. They
          // remain counts for diagnosis and can never establish track identity.
          eligible = {?boundSource};
          matchedCount = eligible.length;
          if (sourceWatch.elapsed >= nextReport) {
            diagnostic?.call({
              'stage': 'waiting_source',
              'controls':
                  (await _action('probe-playback', id: track.id))['counts']
                      as Map,
              'requests': _captureRequests,
              'approved': _captureApproved,
              'cdp_audio_requests': _cdpRequests,
              'candidates': _candidates.length,
              'timing_candidates': timingCandidates,
              'matched_candidates': matchedCount,
              'request_kinds': Map<String, int>.from(_requestKinds),
              'network_kinds': Map<String, int>.from(_networkKinds),
            });
            nextReport = sourceWatch.elapsed + const Duration(seconds: 1);
          }
          if (eligible.length == 1 && !preparedCandidate) {
            preparedCandidate = true;
            // Memory only until the final ambiguity/identity check passes.
            prepareCandidate?.call(eligible.single, userAgent);
          }
          if (boundSource != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final uri = selectSource(
          eligible,
          requireBinding: true,
          boundSource: boundSource,
        );
        captured = true;
        diagnostic?.call({
          'stage': 'source_captured',
          'identity_bound': true,
          'identity_evidence': boundEvidence,
          'requests': _captureRequests,
          'approved': _captureApproved,
          'candidates': _candidates.length,
          'timing_candidates': timingCandidates,
          'hidden': await _isHidden(),
        });
        return ResolvedAudio(
          uri,
          userAgent,
          recordingId: track.id,
          evidence: boundEvidence,
        );
      } finally {
        diagnostic?.call({
          'stage': 'source_finished',
          'captured': captured,
          'hidden': await _isHidden(),
          'requests': _captureRequests,
          'approved': _captureApproved,
          'candidates': _candidates.length,
          'timing_candidates': timingCandidates,
        });
        _capturing = false;
        _candidates.clear();
        // resolve's outer finally destroys this natively muted page. Avoid
        // waiting for renderer JavaScript again while unwinding a failure.
      }
    });
  }

  Future<void> _resolutionGuard(bool Function()? cancelled) async {
    if (cancelled?.call() == true) {
      throw const ProofFailure('cancelled');
    }
    _guard();
  }

  Uri? _selectedSource(Map<String, dynamic> data, String id) {
    final raw = (data['tracks'] as List).whereType<Map>().where(
      (row) => row['id'] == id,
    );
    final sources = <Uri>{};
    for (final row in raw) {
      final value = row['url'];
      final userId = data['userId'];
      final uri = value is String
          ? decodeAudioSource(value, userId is num ? userId.toInt() : 0)
          : null;
      if (uri != null) sources.add(uri);
    }
    return sources.isEmpty ? null : selectSource(sources);
  }

  Future<void> _tap(String id, double x, double y) async {
    _guard();
    await _action('verify-my-music');
    final viewport = decodeMap(
      await _evaluate('JSON.stringify({w:innerWidth,h:innerHeight})'),
    );
    if (x < 0 ||
        y < 0 ||
        x >= (viewport['w'] as num) ||
        y >= (viewport['h'] as num)) {
      throw const ProofFailure('play_control_outside_viewport');
    }
    await dispatchGuardedTap(
      x: x,
      y: y,
      guard: () async {
        _guard();
        final personal = await _action('verify-my-music');
        if (personal['personal'] != true) {
          throw const ProofFailure('personal_music_unconfirmed');
        }
        await _action('verify-play-hit', id: id, x: x, y: y);
      },
      refreshAfterHover: () async {
        // The trusted hover can reveal a real button in a different place.
        // Recompute before pressing; the per-event hit guard uses this point.
        final fresh = await _action('play-position', id: id);
        final point = fresh['position'] as Map;
        x = (point['x'] as num).toDouble();
        y = (point['y'] as num).toDouble();
        return (x: x, y: y);
      },
      dispatch: (parameters) async {
        _guard();
        await _browser!
            .pointer(parameters)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw const ProofFailure('music_input_timeout'),
            );
      },
    );
  }

  @override
  Future<Map<String, dynamic>> inspectMetadata(
    Track track, {
    bool force = false,
    bool includeLyrics = true,
    bool Function()? cancelled,
  }) {
    if (_privateSignInActive) {
      return Future.error(const ProofFailure('private_signin_in_progress'));
    }
    final known = observedMetadata(track.id);
    if (!force &&
        known.isNotEmpty &&
        (!includeLyrics ||
            known['lyrics'] != null ||
            known['lyricsAvailable'] != true)) {
      return Future.value(known);
    }
    final requestKey = '${track.id}/${includeLyrics ? 1 : 0}';
    return _metadataRequests.putIfAbsent(requestKey, () {
      final task = _metadataLane.then((_) async {
        _requireBackgroundAccess();
        if (_closed || cancelled?.call() == true) {
          throw const ProofFailure('cancelled');
        }
        if (!browserFactory.prepared) await connect();
        _requireBackgroundAccess();
        final page = _detailsPage = _newPlaybackPage();
        try {
          await page.connect();
          await page._ensurePersonal(cancelled: cancelled);
          await page._resolutionGuard(cancelled);
          await page._install();
          await page._browser?.hide();
          try {
            await page._read(targetId: track.id, includeLyrics: includeLyrics);
          } on ProofFailure catch (e) {
            if (e.category != 'music_adapter_unsupported') rethrow;
          }
          if (!page._metadata.containsKey(track.id)) {
            await page._action(
              'search-track',
              musicQuery: '${track.artist} ${track.title}',
            );
            final watch = Stopwatch()..start();
            while (watch.elapsed < const Duration(seconds: 10)) {
              if (_closed || page._closed || cancelled?.call() == true) {
                throw const ProofFailure('cancelled');
              }
              try {
                await page._read(
                  targetId: track.id,
                  includeLyrics: includeLyrics,
                );
              } on ProofFailure catch (e) {
                if (e.category != 'music_adapter_unsupported') rethrow;
              }
              if (page._metadata.containsKey(track.id)) break;
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
          }
          if (!page._metadata.containsKey(track.id)) {
            throw const ProofFailure('track_not_in_search_results');
          }
          await page._resolutionGuard(cancelled);
          final observed = page.observedMetadata(track.id);
          if (includeLyrics &&
              observed['lyrics'] == null &&
              (observed['lyricsAvailable'] == true ||
                  observed['lyricsId'] is int)) {
            try {
              final lyrics = await page._inspectLyricsControl(track.id);
              if (lyrics != null) page._metadata[track.id]!['lyrics'] = lyrics;
            } catch (e) {
              diagnostic?.call({
                'stage': 'lyrics_control',
                'category': categoryOf(e),
                'retrieved': false,
              });
            }
          }
          await page._resolutionGuard(cancelled);
          _metadata[track.id] = {
            ...?_metadata[track.id],
            ...page.observedMetadata(track.id),
          };
          final result = observedMetadata(track.id);
          diagnostic?.call({
            'stage': 'metadata_details',
            'matched': true,
            'artwork': result['artworkURL'] != null,
            'lyrics_inline': result['lyrics'] != null,
            'lyrics_hint': result['lyricsAvailable'] == true,
          });
          return result;
        } finally {
          if (identical(_detailsPage, page)) _detailsPage = null;
          await page.disconnect();
        }
      });
      _metadataLane = task.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      task.then<void>(
        (_) => _metadataRequests.remove(requestKey),
        onError: (Object _, StackTrace _) {
          _metadataRequests.remove(requestKey);
        },
      );
      return task;
    });
  }

  Future<Map<String, dynamic>?> _inspectLyricsControl(String id) async {
    await _browser!.activate();
    final hover = await _action('lyrics-hover-position', id: id);
    final point = hover['position'];
    if (point is Map) {
      final x = (point['x'] as num).toDouble(),
          y = (point['y'] as num).toDouble();
      await _action('verify-lyrics-hover', id: id, x: x, y: y);
      await _browser!.pointer(BrowserPointer(PointerPhase.move, x, y));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final control = await _action('lyrics-position', id: id);
    final position = control['position'];
    if (position is! Map) {
      diagnostic?.call({
        'stage': 'lyrics_control',
        'retrieved': false,
        'control_present': false,
      });
      return null;
    }
    final x = (position['x'] as num).toDouble(),
        y = (position['y'] as num).toDouble();
    await dispatchGuardedTap(
      x: x,
      y: y,
      guard: () async {
        await _action('verify-lyrics-hit', id: id, x: x, y: y);
      },
      dispatch: (parameters) async {
        await _browser!.pointer(parameters);
      },
    );
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 5)) {
      final result = await _action('read-lyrics', id: id);
      final lyrics = sanitizeLyrics(
        result['lyrics'] is Map ? result['lyrics'] as Map : null,
      );
      if (lyrics != null) {
        diagnostic?.call({
          'stage': 'lyrics_control',
          'retrieved': true,
          'control_present': true,
        });
        return lyrics;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    diagnostic?.call({
      'stage': 'lyrics_control',
      'retrieved': false,
      'control_present': true,
    });
    return null;
  }

  @override
  Future<void> disconnect() async {
    ++_privateSignInGeneration;
    _privateSignInActive = false;
    ++_connectionGeneration;
    _navigation.observe(null);
    _networkListening = false;
    _sourceMemory.clear();
    _musicReferences.clear();
    _knownUnavailable.clear();
    _libraryPositions.clear();
    _musicAgeBuckets.clear();
    _metadata.clear();
    _closed = true;
    if (!_terminated.isCompleted) _terminated.complete();
    _yieldScan = true;
    connected = false;
    _capturing = false;
    if (!_playbackOnly) await _standby.discard();
    await _playback?.disconnect();
    await _detailsPage?.disconnect();
    _detailsPage = null;
    _playback = null;
    await _closeBrowser();
    _browser = null;
    try {
      await _scan;
    } catch (_) {
      /* Cancellation preserves merged rows. */
    }
    changed();
  }
}

class _OperationLock {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
