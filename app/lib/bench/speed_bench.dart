import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io' show ProcessInfo;
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../library/track.dart';
import '../playback/player_service.dart';
import '../ui/library_controller.dart';
import '../vk/vk_client.dart';

/// Measures the speed targets inside the running release app, driving the
/// same controller and player the UI uses. Playback must be muted.
///
/// Timestamps use [Timeline.now], which on Windows reads the same monotonic
/// clock as the engine's frame timings; [run] checks that and reports the skew.
class SpeedBench {
  SpeedBench({required this.library, required this.player, required this.vk});

  final LibraryController library;
  final PlayerService player;
  final VkClient? vk;

  final _frames = <FrameTiming>[];

  /// Runs the benchmark [parts] (all when null) and returns the results.
  Future<Map<String, Object?>> run({List<String>? parts}) async {
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle();
    final display = WidgetsBinding.instance.platformDispatcher.displays.first;
    final benches = <String, Future<Map<String, Object?>> Function()>{
      'search': _searchBench,
      'scroll': _scrollBench,
      'playCached': _cachedPlayBench,
      'playStream': _streamPlayBench,
    };
    final result = <String, Object?>{
      'displayRefreshHz': display.refreshRate,
      'songs': library.all.length,
    };
    for (final bench in benches.entries) {
      if (parts == null || parts.contains(bench.key)) {
        result[bench.key] = await bench.value();
      }
    }
    await player.stop();
    result['memoryAfterBenchMB'] = {
      'current': ProcessInfo.currentRss ~/ (1024 * 1024),
      'peak': ProcessInfo.maxRss ~/ (1024 * 1024),
    };
    return result;
  }

  /// Waits for pending frames and for the engine to report their timings
  /// (release builds report them about once a second).
  Future<void> _settle() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  FrameTiming? _firstFrameStartingAfter(int micros) {
    FrameTiming? best;
    for (final frame in _frames) {
      final start = frame.timestampInMicroseconds(FramePhase.buildStart);
      if (start >= micros &&
          (best == null ||
              start < best.timestampInMicroseconds(FramePhase.buildStart))) {
        best = frame;
      }
    }
    return best;
  }

  /// Types queries one character at a time, as a user would, and measures
  /// each keystroke until the frame showing its results is rasterized.
  Future<Map<String, Object?>> _searchBench() async {
    const queries = [
      'кино',
      'ёлка',
      'елка',
      'зелёный свет',
      'metallica',
      'night city',
      'the',
      'love remix',
    ];
    final keystrokes =
        <({int startUs, int uiDoneUs, int queryUs, int shown})>[];
    for (final query in queries) {
      for (var length = 1; length <= query.length; length++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final startUs = Timeline.now;
        library.searchText.text = query.substring(0, length);
        final queryUs = library.lastQueryTime.inMicroseconds;
        await WidgetsBinding.instance.endOfFrame;
        keystrokes.add((
          startUs: startUs,
          uiDoneUs: Timeline.now,
          queryUs: queryUs,
          shown: library.visible.length,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      library.searchText.clear();
      await WidgetsBinding.instance.endOfFrame;
    }
    await _settle();

    final toRasterMs = <double>[];
    final skewsMs = <double>[];
    for (final keystroke in keystrokes) {
      final frame = _firstFrameStartingAfter(keystroke.startUs);
      if (frame == null) continue;
      final rasterDone = frame.timestampInMicroseconds(FramePhase.rasterFinish);
      toRasterMs.add((rasterDone - keystroke.startUs) / 1000);
      // The UI thread finishes this frame right after the engine's build
      // finish mark; a small skew proves both clocks agree.
      skewsMs.add(
        (keystroke.uiDoneUs -
                frame.timestampInMicroseconds(FramePhase.buildFinish)) /
            1000,
      );
    }
    return {
      'keystrokes': keystrokes.length,
      'matchedFrames': toRasterMs.length,
      'keystrokeToRasterMs': _stats(toRasterMs),
      'keystrokeToUiDoneMs': _stats([
        for (final k in keystrokes) (k.uiDoneUs - k.startUs) / 1000,
      ]),
      'dbQueryMs': _stats([for (final k in keystrokes) k.queryUs / 1000]),
      'clockSkewMs': _stats(skewsMs),
      'resultsForFullQueries': {
        for (final query in queries)
          query: library.all.isEmpty ? 0 : _countMatches(query),
      },
    };
  }

  int _countMatches(String query) {
    library.searchText.text = query;
    final count = library.visible.length;
    library.searchText.clear();
    return count;
  }

  /// Scrolls the full list at constant speeds, one jump per frame, and
  /// collects the engine's frame timings for each speed.
  Future<Map<String, Object?>> _scrollBench() async {
    library.searchText.clear();
    final results = <String, Object?>{};
    for (final pixelsPerSecond in [1500, 6000, 20000]) {
      library.scroll.jumpTo(0);
      await _settle();
      _frames.clear();
      final startUs = Timeline.now;
      final done = Completer<void>();
      const seconds = 4;
      void onFrame(Duration _) {
        final elapsed = (Timeline.now - startUs) / 1e6;
        final position = library.scroll.position;
        final target = min(elapsed * pixelsPerSecond, position.maxScrollExtent);
        position.jumpTo(target);
        if (elapsed >= seconds || target >= position.maxScrollExtent) {
          done.complete();
        } else {
          SchedulerBinding.instance.scheduleFrameCallback(onFrame);
        }
      }

      SchedulerBinding.instance.scheduleFrameCallback(onFrame);
      SchedulerBinding.instance.scheduleFrame();
      await done.future;
      final endUs = Timeline.now;
      await _settle();
      final frames = [
        for (final frame in _frames)
          if (frame.timestampInMicroseconds(FramePhase.buildStart) >= startUs &&
              frame.timestampInMicroseconds(FramePhase.buildStart) <= endUs)
            frame,
      ];
      const budgetMs = 1000 / 60;
      final buildMs = [
        for (final f in frames) f.buildDuration.inMicroseconds / 1000,
      ];
      final rasterMs = [
        for (final f in frames) f.rasterDuration.inMicroseconds / 1000,
      ];
      results['${pixelsPerSecond}pxPerSec'] = {
        'seconds': (endUs - startUs) / 1e6,
        'frames': frames.length,
        'fps': frames.length / ((endUs - startUs) / 1e6),
        'buildMs': _stats(buildMs),
        'rasterMs': _stats(rasterMs),
        'framesOver60fpsBudget': [
          for (var i = 0; i < frames.length; i++)
            if (buildMs[i] > budgetMs || rasterMs[i] > budgetMs) i,
        ].length,
      };
    }
    library.scroll.jumpTo(0);
    return results;
  }

  /// Plays cached songs and confirms each one keeps decoding audio.
  Future<Map<String, Object?>> _cachedPlayBench() async {
    final cachedVk = library.all
        .where((t) => t.isCached && t.source == TrackSource.vk)
        .take(3);
    final cachedGenerated = library.all
        .where((t) => t.isCached && t.source == TrackSource.generated)
        .take(3);
    final samples = <Map<String, Object?>>[];
    for (final track in [...cachedVk, ...cachedGenerated]) {
      final timing = await player.play(track);
      samples.add({
        'source': track.source.name,
        'ok': timing.ok,
        'toSoundMs': timing.toSoundMs,
        'sampleRate': timing.sampleRate,
        'stillPlayingAfter1s': await _keepsPlaying(),
        if (timing.error != null) 'error': timing.error,
      });
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return {
      'samples': samples,
      'toSoundMs': _stats([
        for (final s in samples)
          if (s['ok'] == true) (s['toSoundMs'] as int).toDouble(),
      ]),
    };
  }

  /// Plays random uncached VK songs from a fresh link. The stream proxy
  /// times the network's first chunk on the same request mpv plays from.
  Future<Map<String, Object?>> _streamPlayBench() async {
    if (vk == null) return {'skipped': 'no VK session'};
    final candidates =
        library.all
            .where((t) => t.source == TrackSource.vk && !t.isCached)
            .toList()
          ..shuffle(Random(7));
    final samples = <Map<String, Object?>>[];
    for (final track in candidates.take(10)) {
      final timing = await player.play(track);
      samples.add({
        'ok': timing.ok,
        'resolveMs': timing.resolveMs,
        'toSoundMs': timing.toSoundMs,
        'networkFirstChunkMs': timing.networkFirstChunkMs,
        'overheadMs': timing.appOverheadMs,
        'sampleRate': timing.sampleRate,
        'stillPlayingAfter1s': timing.ok && await _keepsPlaying(),
        if (timing.error != null) 'error': timing.error,
      });
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    List<double> values(String key) => [
      for (final s in samples)
        if (s['ok'] == true && s[key] != null) (s[key] as num).toDouble(),
    ];
    return {
      'samples': samples,
      'toSoundMs': _stats(values('toSoundMs')),
      'resolveMs': _stats(values('resolveMs')),
      'networkFirstChunkMs': _stats(values('networkFirstChunkMs')),
      'overheadMs': _stats(values('overheadMs')),
    };
  }

  /// True when the position reaches one second within five seconds, which
  /// means mpv kept decoding real audio after the first sample.
  Future<bool> _keepsPlaying() async {
    try {
      await player.player.stream.position
          .firstWhere((position) => position >= const Duration(seconds: 1))
          .timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return player.player.state.position >= const Duration(seconds: 1);
    } on StateError {
      return false;
    }
  }
}

/// Count, median, 95th percentile and max of [values].
Map<String, Object?> _stats(List<double> values) {
  if (values.isEmpty) return {'n': 0};
  final sorted = [...values]..sort();
  double at(double q) =>
      sorted[min(sorted.length - 1, (q * (sorted.length - 1)).round())];
  double round(double v) => (v * 10).round() / 10;
  return {
    'n': sorted.length,
    'min': round(sorted.first),
    'p50': round(at(0.5)),
    'p95': round(at(0.95)),
    'max': round(sorted.last),
  };
}
