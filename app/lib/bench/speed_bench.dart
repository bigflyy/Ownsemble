import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:developer' show Timeline;
import 'dart:io' show File, ProcessInfo;
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

import '../library/search_text.dart';
import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../playback/stream_proxy.dart' show ProxyRequestLog;
import '../storage/cover_store.dart';
import '../ui/collections_controller.dart';
import '../ui/cover_tile.dart';
import '../ui/library_controller.dart';
import '../vk/vk_client.dart';

/// Measures the speed targets inside the running release app, driving the
/// same controller and player the UI uses. Playback must be muted.
///
/// Timestamps use [Timeline.now], which on Windows reads the same monotonic
/// clock as the engine's frame timings; [run] checks that and reports the skew.
class SpeedBench {
  SpeedBench({
    required this.library,
    required this.player,
    required this.playback,
    required this.vk,
    required this.covers,
    this.collections,
    this.resultFile,
    this.volume = 100,
  });

  /// Where the speed gate seeks to before it closes the window.
  static const savedSongProbe = Duration(seconds: 40);

  /// Volume the speed gate saves in one run and expects back in the next.
  static const savedVolumeProbe = 37.0;

  final LibraryController library;
  final PlayerService player;
  final PlaybackController playback;
  final VkClient? vk;
  final CoverStore covers;

  /// History, for the restart check; null when not needed.
  final CollectionsController? collections;

  /// The result file; the restart check writes it while the app stays open.
  final String? resultFile;

  /// mpv volume while measuring, always under mute. Set for each run and not
  /// saved, so results do not depend on what the data folder last saved.
  final double volume;

  final _frames = <FrameTiming>[];

  /// Runs the benchmark [parts] (all when null) and returns the results.
  /// Two parts run only when named, since they are not speed measurements:
  /// saveVolume saves [savedVolumeProbe] the way the volume slider does, and
  /// savedVolume reports what mpv holds before any sound in a later run.
  /// The same goes for playToClose and savedSong, see [_playToClose], and
  /// for keysProbe, see [_keysProbe].
  Future<Map<String, Object?>> run({List<String>? parts}) async {
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle();
    final display = WidgetsBinding.instance.platformDispatcher.displays.first;
    final benches = <String, Future<Map<String, Object?>> Function()>{
      'search': _searchBench,
      'typeJump': _typeJumpBench,
      'scroll': _scrollBench,
      'scrollCovers': _scrollCoversBench,
      'playCached': _cachedPlayBench,
      'playStream': _streamPlayBench,
      'seekStream': _streamSeekBench,
    };
    final result = <String, Object?>{
      'displayRefreshHz': display.refreshRate,
      'songs': library.all.length,
    };
    if (parts?.contains('saveVolume') ?? false) {
      await playback.setVolume(savedVolumeProbe);
      playback.saveVolume();
      result['saveVolume'] = {'volume': savedVolumeProbe};
    }
    if (parts?.contains('savedVolume') ?? false) {
      final mpv = player.player.platform as NativePlayer;
      result['savedVolume'] = {
        'mpvVolume': double.parse(await mpv.getProperty('volume')),
        'mutedByUser': playback.mutedByUser,
      };
    }
    if (parts?.contains('playToCloseCached') ?? false) {
      await _playToClose(cached: true);
    }
    if (parts?.contains('playToCloseStream') ?? false) {
      await _playToClose(cached: false);
    }
    if (parts?.contains('savedSong') ?? false) {
      result['savedSong'] = await _goOnFromSavedSong();
    }
    if (parts?.contains('keysProbe') ?? false) {
      result['keysProbe'] = await _keysProbe();
    }
    await player.setVolume(volume);
    result['volume'] = volume;
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

  /// Plays a cached or a streamed VK song the way a click does, moves to
  /// [savedSongProbe], writes where it is and keeps playing: the speed gate
  /// then closes the window, as the user does. Only the close can save this
  /// place, since the periodic save has not come round yet. Never returns.
  Future<void> _playToClose({required bool cached}) async {
    final list = library.visible;
    final index = list.indexWhere(
      (t) =>
          t.source == TrackSource.vk &&
          t.isCached == cached &&
          t.durationSec >= savedSongProbe.inSeconds + 30,
    );
    await playback.playFrom(list, index);
    await playback.seek(savedSongProbe);
    await player.positions
        .firstWhere((at) => at > savedSongProbe)
        .timeout(const Duration(seconds: 30));
    File(resultFile!).writeAsStringSync(
      jsonEncode({
        'ok': player.currentLoaded,
        'trackId': list[index].id,
        'lengthS': list[index].durationSec,
        'listSongs': list.length,
        'librarySongs': library.all.length,
        'positionMs': player.position.inMilliseconds,
      }),
    );
    await Completer<void>().future;
  }

  /// Pauses a cached song at [savedSongProbe] and says so in the result file;
  /// the speed gate then posts real Windows key messages to this window, and
  /// this reports what they did: Right moves the song, Up the volume, Space
  /// resumes it, and letters jump to a song. The letters are Cyrillic, taken
  /// from the library: the jump reads them from Windows' text, and only real
  /// messages have that. The result file's ".ready" holds them.
  Future<Map<String, Object?>> _keysProbe() async {
    final list = library.visible;
    final index = list.indexWhere(
      (t) =>
          t.source == TrackSource.vk &&
          t.isCached &&
          t.durationSec >= savedSongProbe.inSeconds + 30,
    );
    await playback.playFrom(list, index);
    await playback.seek(savedSongProbe);
    await player.positions
        .firstWhere((at) => at > savedSongProbe)
        .timeout(const Duration(seconds: 30));
    await playback.playOrPause();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final position = player.position;
    final volumeBefore = playback.volume;
    final cyrillic = RegExp('^[а-яА-Я]{3}');
    final jumpTrack = list.firstWhere((t) => cyrillic.hasMatch(t.title));
    final jumpText = jumpTrack.title.substring(0, 3);
    File('${resultFile!}.ready').writeAsStringSync(jumpText);
    final clock = Stopwatch()..start();
    // The text is forgotten after 2 s, sooner than the song gets 4 s on.
    Track? jumpedTo;
    bool done() =>
        player.playing.value &&
        player.position >= position + const Duration(seconds: 4) &&
        playback.volume != volumeBefore &&
        jumpedTo != null;
    while (!done() && clock.elapsed < const Duration(seconds: 15)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final row = library.jump.row;
      if (library.jump.text == jumpText && row != null) {
        jumpedTo = list[row];
      }
    }
    final wanted = normalizeForSearch(jumpText);
    return {
      'ok':
          done() &&
          (normalizeForSearch(jumpedTo!.title).startsWith(wanted) ||
              normalizeForSearch(jumpedTo.artist).startsWith(wanted)),
      'jumpText': jumpText,
      'jumpedToTitle': jumpedTo?.title,
      'jumpedToArtist': jumpedTo?.artist,
      'positionBeforeMs': position.inMilliseconds,
      'positionAfterMs': player.position.inMilliseconds,
      'volumeBefore': volumeBefore,
      'volumeAfter': playback.volume,
      'playing': player.playing.value,
      'tookMs': clock.elapsedMilliseconds,
    };
  }

  /// What a new run shows for the saved song before Play (nothing may be
  /// loaded in mpv), then Play and the sound that follows.
  Future<Map<String, Object?>> _goOnFromSavedSong() async {
    final mpv = player.player.platform as NativePlayer;
    final historyBefore = collections?.history().length;
    final before = <String, Object?>{
      'trackId': player.current?.id,
      'positionMs': player.position.inMilliseconds,
      'playing': player.playing.value,
      'mpvPath': await mpv.getProperty('path'),
      'listSongs': playback.queue.context.length,
      'librarySongs': library.all.length,
    };
    final clock = Stopwatch()..start();
    await playback.playOrPause();
    final toSoundMs = clock.elapsedMilliseconds;
    final soundAt = player.position;
    await Future<void>.delayed(const Duration(seconds: 2));
    return {
      'before': before,
      'toSoundMs': toSoundMs,
      'loaded': player.currentLoaded,
      'soundAtMs': soundAt.inMilliseconds,
      'twoSecondsLaterMs': player.position.inMilliseconds,
      'playing': player.playing.value,
      'sampleRate': player.player.state.audioParams.sampleRate,
      'historyAdded': collections == null
          ? null
          : collections!.history().length - historyBefore!,
    };
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
      'searchMs': _stats([for (final k in keystrokes) k.queryUs / 1000]),
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

  /// Types on the list one character at a time, as a user would, and
  /// measures each key until the frame showing the jump is rasterized. Each
  /// key scans every row, and a far row also scrolls the list. The last text
  /// finds nothing, which is the full scan through all three checks.
  Future<Map<String, Object?>> _typeJumpBench() async {
    const texts = ['кино', 'ёлка', 'metallica', 'night city', 'the', 'ъъъъ'];
    final jump = library.jump;
    final keystrokes = <({int startUs, int scanUs, int uiDoneUs})>[];
    for (final text in texts) {
      for (final character in text.split('')) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final startUs = Timeline.now;
        jump.type(character);
        final scanUs = Timeline.now - startUs;
        await WidgetsBinding.instance.endOfFrame;
        keystrokes.add((
          startUs: startUs,
          scanUs: scanUs,
          uiDoneUs: Timeline.now,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      jump.clear();
      await WidgetsBinding.instance.endOfFrame;
    }
    library.scroll.jumpTo(0);
    await _settle();
    final toRasterMs = <double>[];
    for (final keystroke in keystrokes) {
      final frame = _firstFrameStartingAfter(keystroke.startUs);
      if (frame == null) continue;
      final rasterDone = frame.timestampInMicroseconds(FramePhase.rasterFinish);
      toRasterMs.add((rasterDone - keystroke.startUs) / 1000);
    }
    return {
      'keystrokes': keystrokes.length,
      'matchedFrames': toRasterMs.length,
      'keystrokeToRasterMs': _stats(toRasterMs),
      'scanMs': _stats([for (final k in keystrokes) k.scanUs / 1000]),
    };
  }

  /// Scrolls the full list at constant speeds, one jump per frame, and
  /// collects the engine's frame timings for each speed.
  Future<Map<String, Object?>> _scrollBench() async {
    library.searchText.clear();
    final results = <String, Object?>{};
    for (final pixelsPerSecond in [1500, 6000, 20000]) {
      results['${pixelsPerSecond}pxPerSec'] = await _scrollRun(
        pixelsPerSecond,
        seconds: 4,
      );
    }
    library.scroll.jumpTo(0);
    return results;
  }

  /// The hard case for covers: a speed at which every row stays long enough
  /// to be decoded, for long enough to turn over the whole image cache. At
  /// 20000 px/s rows leave before their covers load, so that speed says
  /// nothing about decoding.
  Future<Map<String, Object?>> _scrollCoversBench() async {
    library.searchText.clear();
    final imageCache = PaintingBinding.instance.imageCache;
    final run = await _scrollRun(4000, seconds: 20);
    library.scroll.jumpTo(library.scroll.position.maxScrollExtent / 2);
    await Future<void>.delayed(const Duration(seconds: 1));
    await _settle();
    final shown = _coversOnScreen();
    library.scroll.jumpTo(0);
    return {
      'at4000pxPerSec': run,
      'coversOnDisk': covers.storedCount,
      'coversShownAtRest': shown,
      'imageCacheCount': imageCache.currentSize,
      'imageCacheMB': imageCache.currentSizeBytes / (1024 * 1024),
      'peakWorkingSetMB': ProcessInfo.maxRss / (1024 * 1024),
    };
  }

  /// How many images are on screen and decoded.
  int _coversOnScreen() {
    var count = 0;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is RawImage && widget.image != null) count++;
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return count;
  }

  /// Scrolls at [pixelsPerSecond] for [seconds] and reports the frames and
  /// how many covers were decoded meanwhile.
  Future<Map<String, Object?>> _scrollRun(
    int pixelsPerSecond, {
    required int seconds,
  }) async {
    library.scroll.jumpTo(0);
    await _settle();
    _frames.clear();
    final decodesBefore = CoverFileImage.decodeCount;
    final startUs = Timeline.now;
    final done = Completer<void>();
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
    final decoded = CoverFileImage.decodeCount - decodesBefore;
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
    return {
      'seconds': (endUs - startUs) / 1e6,
      'frames': frames.length,
      'fps': frames.length / ((endUs - startUs) / 1e6),
      'coversDecoded': decoded,
      'buildMs': _stats(buildMs),
      'rasterMs': _stats(rasterMs),
      'framesOver60fpsBudget': [
        for (var i = 0; i < frames.length; i++)
          if (buildMs[i] > budgetMs || rasterMs[i] > budgetMs) i,
      ].length,
    };
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

  /// Seeks streamed songs to three quarters as soon as their sound starts,
  /// and times the seek until the position moves on from the new place.
  /// Each sample lists the proxy's requests, so a slow seek shows whether
  /// the audio server or the app took the time.
  Future<Map<String, Object?>> _streamSeekBench() async {
    if (vk == null) return {'skipped': 'no VK session'};
    final candidates =
        library.all
            .where(
              (t) =>
                  t.source == TrackSource.vk &&
                  !t.isCached &&
                  t.durationSec >= 60,
            )
            .toList()
          ..shuffle(Random(11));
    final samples = <Map<String, Object?>>[];
    for (final track in candidates.take(6)) {
      final timing = await player.play(track);
      if (!timing.ok) {
        samples.add({'ok': false, 'error': timing.error});
        continue;
      }
      // Seek at once, to three quarters of the song: on a fast line mpv has
      // the whole song buffered after a few seconds and would seek in
      // memory, so this makes it ask the audio server for a range.
      final target = Duration(seconds: track.durationSec * 3 ~/ 4);
      final before = player.position;
      // The proxy's requests from the seek on (the hung-up whole-file
      // request and the ranged one), to tell the audio server's time from
      // the app's.
      final requests = <ProxyRequestLog>[];
      final listening = player.proxyRequests.listen(requests.add);
      final clock = Stopwatch()..start();
      await player.seek(target);
      // Done when playback runs again away from where it was: the first
      // position more than 5 s from the old one, then 300 ms further on.
      Duration? landed;
      var ok = true;
      try {
        await player.player.stream.position
            .firstWhere((at) {
              if (landed == null) {
                if ((at - before).abs() > const Duration(seconds: 5)) {
                  landed = at;
                }
                return false;
              }
              return at > landed! + const Duration(milliseconds: 300);
            })
            .timeout(const Duration(seconds: 40));
      } on TimeoutException {
        ok = false;
      }
      samples.add({
        'ok': ok,
        'seekToSoundMs': clock.elapsedMilliseconds,
        'targetS': target.inSeconds,
        'landedS': landed?.inMilliseconds == null
            ? null
            : landed!.inMilliseconds / 1000,
        'lengthS': track.durationSec,
        'mpvLengthS': player.duration.inMilliseconds / 1000,
      });
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await listening.cancel();
      samples.last['ranged'] = requests.any((r) => r.fromByte != null);
      samples.last['proxyRequests'] = [for (final r in requests) r.toJson()];
    }
    return {
      'samples': samples,
      'seekToSoundMs': _stats([
        for (final s in samples)
          if (s['ok'] == true) (s['seekToSoundMs'] as int).toDouble(),
      ]),
      'rangedSeeks': samples.where((s) => s['ranged'] == true).length,
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
