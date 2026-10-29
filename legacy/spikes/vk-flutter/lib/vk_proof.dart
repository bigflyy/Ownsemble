import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'audio_cache.dart';
import 'proof_core.dart';
import 'proof_player.dart';
import 'proof_store.dart';
import 'self_test.dart';
import 'progress_budget.dart';

class VkProof {
  final ProofStore store;
  final ReadScript evaluate;
  final TapPoint tap;
  final bool Function() isMusic;
  final void Function(String) update;
  final Future<void> Function() stopBrowser, restartOffline;
  final candidates = <Uri>{};
  bool cancelled = false, capturing = false;
  int captureRequests = 0, captureApprovedRequests = 0;
  VkProof(
    this.store,
    this.evaluate,
    this.tap,
    this.isMusic,
    this.update,
    this.stopBrowser,
    this.restartOffline,
  );
  void pageChanged() {
    capturing = false;
  }

  void observe(Uri uri) {
    if (!capturing) return;
    captureRequests++;
    if (allowedAudio(uri)) captureApprovedRequests++;
    if (audioCandidate(uri)) candidates.add(uri);
  }

  void guard() {
    if (cancelled) throw const ProofFailure('cancelled');
    if (!isMusic()) throw const ProofFailure('private_signin_required');
  }

  Future<Map<String, dynamic>> action(
    String name, {
    String id = '',
    int waitMs = 0,
  }) async {
    guard();
    return decodeMap(
      await evaluate(
        '''(async()=>JSON.stringify(await window.ownsembleMusic.action(
      ${jsonEncode(name)},${jsonEncode(id)},{waitMs:$waitMs})))()''',
      ),
    );
  }

  Future<Map<String, dynamic>> read() async {
    guard();
    return decodeMap(
      await evaluate(
        '(async()=>JSON.stringify(await window.ownsembleMusic.read({})))()',
      ),
    );
  }

  Future<Map<String, dynamic>> readiness({bool requirePersonal = true}) async {
    guard();
    return decodeMap(
      await evaluate('''(async()=>{
      const witness=await window.ownsembleMusic.action('verify-my-music','',{});
      if(witness.error) return JSON.stringify(witness);
      if(!witness.personal&&$requirePersonal) return JSON.stringify({error:'Music view changed'});
      const media=[...document.querySelectorAll('audio')];
      return JSON.stringify({
        loading:document.readyState!=='complete'||Boolean(document.querySelector('[aria-busy="true"]')),
        mediaLoading:media.some(a=>a.networkState===2&&a.readyState<3),
        ready:media.reduce((n,a)=>n+a.readyState,0),
        playing:media.filter(a=>!a.paused&&!a.ended).length,
        count:document.querySelectorAll('[data-audio-id], [data-audio]').length
      });
    })()'''),
    );
  }

  Future<Map<String, dynamic>> readWhenReady({
    Duration hardLimit = const Duration(seconds: 120),
  }) async {
    final watch = Stopwatch()..start();
    final budget = ProgressBudget(
      quietLimit: const Duration(seconds: 45),
      hardLimit: hardLimit,
    );
    var delayMs = 500;
    while (true) {
      guard();
      try {
        final data = await read();
        tracksFrom(data);
        return data;
      } on ProofFailure catch (error) {
        if (error.category != 'music_adapter_unsupported') rethrow;
      }
      final state = await readiness();
      if (budget.expired(
        watch.elapsed,
        progress: state['count'],
        loading: state['loading'] == true,
      )) {
        throw const ProofFailure('music_rows_not_ready');
      }
      update('Waiting for music rows; the page is still settling');
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      delayMs = (delayMs * 2).clamp(500, 4000);
    }
  }

  Future<void> waitForSource() async {
    final watch = Stopwatch()..start();
    final budget = ProgressBudget(
      quietLimit: const Duration(seconds: 30),
      hardLimit: const Duration(seconds: 90),
    );
    var count = 0;
    Duration? lastCandidate;
    while (true) {
      guard();
      final state = await readiness();
      if (candidates.isNotEmpty) {
        if (candidates.length != count) {
          count = candidates.length;
          lastCandidate = watch.elapsed;
        }
        // Allow competing/preloaded sources to surface before association.
        if (watch.elapsed - lastCandidate! >= const Duration(seconds: 2)) {
          return;
        }
      }
      if (budget.expired(
        watch.elapsed,
        progress: (captureApprovedRequests, state['ready'], state['playing']),
        loading: state['loading'] == true || state['mediaLoading'] == true,
      )) {
        throw ProofFailure(
          state['playing'] is num && state['playing'] > 0
              ? 'audio_playing_source_unobserved'
              : 'audio_source_timeout',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
  }

  List<Track> tracksFrom(Map<String, dynamic> data) {
    final list = data['tracks'];
    if (list is! List || list.isEmpty || list.length > 50000) {
      throw const ProofFailure('music_adapter_unsupported');
    }
    return list
        .map((v) => Track.fromJson(Map<String, dynamic>.from(v)))
        .toList();
  }

  Future<void> run() async {
    cancelled = false;
    guard();
    update('Checking My music in the Flutter browser');
    store.status('personal_music_navigation');
    await evaluate(
      '(async()=>{${await rootBundle.loadString('assets/vk_adapter.js')} return true;})()',
    );
    var clicked = false, navigationDelayMs = 500;
    final navigationWatch = Stopwatch()..start();
    final navigationBudget = ProgressBudget(
      quietLimit: const Duration(seconds: 30),
      hardLimit: const Duration(seconds: 90),
    );
    while (true) {
      Map<String, dynamic> result;
      try {
        result = await action(clicked ? 'verify-my-music' : 'open-my-music');
      } on ProofFailure catch (error) {
        if (error.category != 'music_adapter_unsupported') rethrow;
        result = {};
      }
      if (result['personal'] == true) {
        break;
      }
      clicked = clicked || result['navigationAttempted'] == true;
      final state = await readiness(requirePersonal: false);
      if (navigationBudget.expired(
        navigationWatch.elapsed,
        progress: (state['count'], jsonEncode(result['counts'])),
        loading: state['loading'] == true,
      )) {
        throw const ProofFailure('personal_music_unconfirmed');
      }
      await Future<void>.delayed(Duration(milliseconds: navigationDelayMs));
      navigationDelayMs = (navigationDelayMs * 2).clamp(500, 4000);
    }
    // Navigation can replace the document. Reinstall the same guarded readers.
    await evaluate(
      '(async()=>{${await rootBundle.loadString('assets/vk_adapter.js')} return true;})()',
    );
    store.record('flutter_personal_music_confirmed', {'passed': true});
    final found = <String, Track>{};
    store.status('music_loading');
    var data = await readWhenReady();
    final first = tracksFrom(data);
    final userAgent = data['userAgent'] is String
        ? data['userAgent'] as String
        : 'OwnsembleFlutterProof/0.1';
    final scanWatch = Stopwatch()..start();
    final scanBudget = ProgressBudget(
      quietLimit: const Duration(seconds: 45),
      hardLimit: const Duration(minutes: 3),
    );
    var idle = 0;
    var providerLoading = false;
    var stopReason = 'page_budget';
    store.status('music_metadata');
    for (var page = 0; page < 40; page++) {
      guard();
      final before = found.length;
      for (final track in tracksFrom(data)) {
        found[track.id] = track;
      }
      idle = before == found.length ? idle + 1 : 0;
      store.merge(found.values.toList());
      update(
        'Flutter music probe: ${found.length} tracks; metadata sample only',
      );
      if (found.length >= 250) {
        stopReason = 'sample_budget';
        break;
      }
      if (scanBudget.expired(
        scanWatch.elapsed,
        progress: found.length,
        loading: providerLoading,
      )) {
        stopReason = scanWatch.elapsed >= const Duration(minutes: 3)
            ? 'time_budget'
            : 'no_new_rows';
        break;
      }
      final advanced = await action(
        idle > 0 ? 'retry-pagination' : 'advance',
        waitMs: (4000 * (1 << idle.clamp(0, 3))).clamp(
          1,
          (const Duration(minutes: 3) - scanWatch.elapsed).inMilliseconds.clamp(
            1,
            30000,
          ),
        ),
      );
      providerLoading = advanced['loading'] == true;
      final remaining = const Duration(minutes: 3) - scanWatch.elapsed;
      if (remaining <= Duration.zero) {
        stopReason = 'time_budget';
        break;
      }
      try {
        data = await readWhenReady(hardLimit: remaining);
      } on ProofFailure catch (error) {
        if (error.category != 'music_rows_not_ready') rethrow;
        stopReason = 'page_loading_timeout';
        break;
      }
    }
    store.record('flutter_music_imported', {
      'count': found.length,
      'complete': false,
      'stage': stopReason,
    });
    await action('reset');
    await action('pause');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final cache = AudioCache(
      Directory('${store.directory.path}/vk-cache'),
      decodeLocalAudio,
      onTransport: (kind) =>
          store.record('flutter_hls_transport', {'codec': kind}),
    );
    ProofFailure? lastCaptureFailure;
    for (final track in first.take(2)) {
      guard();
      try {
        final existing = store
            .assets()
            .where((a) => a.id == track.id)
            .firstOrNull;
        CachedAudio asset;
        if (existing != null) await cache.verify(existing);
        // A cached sample must not skip proof of the new browser host bindings.
        update('Testing native VK activation in the Flutter host');
        store.status('native_audio_capture');
        await action('pause');
        final position = (await action(
          'play-position',
          id: track.id,
        ))['position'];
        if (position is! Map) {
          throw const ProofFailure('play_control_unsupported');
        }
        await action('verify-my-music');
        candidates.clear();
        captureRequests = 0;
        captureApprovedRequests = 0;
        capturing = true;
        await tap(
          (position['x'] as num).toDouble(),
          (position['y'] as num).toDouble(),
        );
        await waitForSource();
        guard();
        capturing = false;
        final uri = selectSource(candidates);
        store.record('flutter_native_source_captured', {
          'candidates': candidates.length,
        });
        await stopBrowser();
        if (existing != null) {
          asset = existing;
        } else {
          store.status('portable_audio_download');
          asset = await cache.save(track, uri, userAgent: userAgent);
          store.saveAsset(asset);
        }
        await checkLocalPlayer(asset.entry);
        store.record('flutter_real_audio_checked', {
          'bytes': asset.bytes,
          'duration': asset.duration,
          'passed': true,
        });
        await File('${store.directory.path}/resume.json').writeAsString(
          jsonEncode({'phase': 'offline_pending', 'id': asset.id}),
        );
        store.status('offline_restart_pending');
        await restartOffline();
        return;
      } catch (error) {
        capturing = false;
        store.record('flutter_vk_attempt_failed', {
          'category': categoryOf(error),
        });
        if (error is ProofFailure &&
            [
              'audio_source_timeout',
              'audio_playing_source_unobserved',
            ].contains(error.category)) {
          lastCaptureFailure = error;
          continue;
        }
        rethrow;
      } finally {
        capturing = false;
        store.record('flutter_source_observation', {
          'requests': captureRequests,
          'count': captureApprovedRequests,
          'candidates': candidates.length,
        });
        if (isMusic() && !cancelled) {
          try {
            await action('pause');
          } catch (_) {
            // Navigation/sign-in may have changed; do not force an interaction.
          }
        }
      }
    }
    throw lastCaptureFailure ?? const ProofFailure('audio_source_unavailable');
  }
}
