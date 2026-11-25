import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:developer' show Timeline;
import 'dart:io' show File, ProcessInfo;
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, KeyDownEvent, KeyUpEvent, KeyRepeatEvent;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

import '../library/artist_index.dart' show Artist;
import '../library/play_period.dart';
import '../library/search_text.dart';
import '../library/song_filter.dart';
import '../library/track.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_fitter.dart';
import '../lyrics/lyrics_hearer.dart';
import '../lyrics/recording_fit.dart' show canFitLines;
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../playback/stream_proxy.dart' show ProxyRequestLog;
import '../platform/process_memory.dart';
import '../storage/cover_store.dart';
import '../ui/artist_page.dart' show vkRefOf;
import '../ui/artists.dart';
import '../ui/catalog_search.dart';
import '../ui/collections_controller.dart';
import '../ui/cover_tile.dart';
import '../ui/for_you.dart';
import '../ui/library_controller.dart';
import '../ui/song_filters.dart';
import '../ui/song_remover.dart';
import '../vk/vk_client.dart';
import 'edit_live.dart';
import 'key_state.dart';

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
    this.forYou,
    this.catalog,
    this.remover,
    this.artists,
    this.resultFile,
    this.volume = 100,
    this.lyrics,
    this.fitter,
    this.fitKeys = const [],
    this.hearer,
    this.hearKeys = const [],
    this.hearThreads = 0,
    this.editKeys = const [],
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

  /// The For you place (plan 07), for the forYou part; null when not needed.
  final ForYou? forYou;

  /// Search on VK and Remove from library (plan 06), for the catalog parts.
  final CatalogSearch? catalog;
  final SongRemover? remover;

  /// The Artists place (plan 09), for the artists part; null when not needed.
  final LibraryArtists? artists;

  /// The Lyrics place and its fitter, for the fitLive part (plan 10 G4).
  final LyricsController? lyrics;
  final LyricsFitter? fitter;

  /// The library songs ("ownerId_audioId") the fitLive part fits.
  final List<String> fitKeys;

  /// "Hear the words" and the hearLive part's songs (plan 10 I2f): a
  /// Russian song, a song in another language, an instrumental; and the
  /// CPU threads the models use.
  final LyricsHearer? hearer;
  final List<String> hearKeys;
  final int hearThreads;

  /// The editLive parts' songs (plan 10 I2g4): one with found timed lyrics,
  /// one with heard words; see [EditLiveBench].
  final List<String> editKeys;

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
  /// The same goes for playToClose and savedSong, see [_playToClose], for
  /// keysProbe, see [_keysProbe], and for playEachSource, see
  /// [_playEachSource].
  Future<Map<String, Object?>> run({List<String>? parts}) async {
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle();
    final display = WidgetsBinding.instance.platformDispatcher.displays.first;
    final benches = <String, Future<Map<String, Object?>> Function()>{
      'search': _searchBench,
      'searchFiltered': _filteredSearchBench,
      'stats': () async {
        // A failed step loses only this part, not the whole run.
        try {
          return await _statsBench();
        } on Object catch (error) {
          return {'error': '$error'};
        }
      },
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
    if (parts?.contains('playEachSource') ?? false) {
      result['playEachSource'] = await _playEachSource();
    }
    if (parts?.contains('forYou') ?? false) {
      result['forYou'] = await _forYouBench();
    }
    if (parts?.contains('forYouMix') ?? false) {
      result['forYouMix'] = await _forYouMixCheck();
    }
    if (parts?.contains('catalogKeys') ?? false) {
      result['catalogKeys'] = await _catalogKeysBench();
    }
    if (parts?.contains('catalogAdd') ?? false) {
      result['catalogAdd'] = await _catalogAddBench();
    }
    if (parts?.contains('artists') ?? false) {
      result['artists'] = await _artistsBench();
    }
    if (parts?.contains('fitLive') ?? false) {
      result['fitLive'] = await _fitLiveBench();
    }
    if (parts?.contains('hearLive') ?? false) {
      result['hearLive'] = await _hearLiveBench();
    }
    for (final part in const ['editLive', 'editLiveAfter']) {
      if (!(parts?.contains(part) ?? false)) continue;
      final bench = EditLiveBench(
        library: library,
        player: player,
        playback: playback,
        lyrics: lyrics!,
        keys: editKeys,
        resultFile: resultFile!,
      );
      result[part] = part == 'editLive'
          ? await bench.before()
          : await bench.after();
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
  /// resumes it, letters jump to a song, and the mouse's side buttons go to
  /// the previous and next place. The letters are Cyrillic, taken from the
  /// library: the jump reads them from Windows' text, and only real messages
  /// have that. The result file's ".ready" holds them.
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
    // The volume is saved, and Up raises it each run: from the top it could
    // not rise, and the check failed with every key received. Start halfway.
    await playback.setVolume(50);
    final volumeBefore = playback.volume;
    final cyrillic = RegExp('^[а-яА-Я]{3}');
    final jumpTrack = list.firstWhere((t) => cyrillic.hasMatch(t.title));
    final jumpText = jumpTrack.title.substring(0, 3);
    // A place to go back to.
    library.showView(const LibraryView(ViewKind.history));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    library.showView(LibraryView.songs);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // What reached the app, for a failure: each key event with the keys
    // Flutter believed held at that moment, and Windows' own modifier state.
    final keyStateAtReady = windowsKeyState();
    final keysReceived = <String>[];
    bool recordKey(KeyEvent event) {
      final kind = switch (event) {
        KeyDownEvent() => 'down',
        KeyUpEvent() => 'up',
        KeyRepeatEvent() => 'repeat',
        _ => '?',
      };
      final held = HardwareKeyboard.instance.logicalKeysPressed
          .map((key) => key.keyLabel)
          .join('+');
      final text = event.character == null ? '' : ' "${event.character}"';
      // A synthesized event is the engine matching Windows' key state; say
      // where Windows had that key down, to tell the user's keyboard apart.
      final windows = event.synthesized ? ' windows ${windowsKeyState()}' : '';
      keysReceived.add(
        '$kind ${event.logicalKey.keyLabel}$text'
        '${event.synthesized ? ' synthesized' : ''} held [$held]$windows',
      );
      return false;
    }

    HardwareKeyboard.instance.addHandler(recordKey);
    File('${resultFile!}.ready').writeAsStringSync(jumpText);
    final clock = Stopwatch()..start();
    // The text is forgotten after 2 s, sooner than the song gets 4 s on.
    Track? jumpedTo;
    // Every text the jump held, so that a lost letter shows as itself.
    final jumpTextsSeen = <String>{};
    var wentBack = false;
    var wentForward = false;
    bool done() =>
        player.playing.value &&
        player.position >= position + const Duration(seconds: 4) &&
        playback.volume != volumeBefore &&
        jumpedTo != null &&
        wentForward;
    while (!done() && clock.elapsed < const Duration(seconds: 15)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final row = library.jump.row;
      if (library.jump.text.isNotEmpty) jumpTextsSeen.add(library.jump.text);
      if (library.jump.text == jumpText && row != null) {
        jumpedTo = list[row];
      }
      if (library.view.kind == ViewKind.history) wentBack = true;
      if (wentBack && library.view == LibraryView.songs) wentForward = true;
    }
    HardwareKeyboard.instance.removeHandler(recordKey);
    final wanted = normalizeForSearch(jumpText);
    return {
      'ok':
          done() &&
          (normalizeForSearch(jumpedTo!.title).startsWith(wanted) ||
              normalizeForSearch(jumpedTo.artist).startsWith(wanted)),
      'jumpText': jumpText,
      'jumpTextsSeen': jumpTextsSeen.toList(),
      'jumpedToTitle': jumpedTo?.title,
      'jumpedToArtist': jumpedTo?.artist,
      'mouseBack': wentBack,
      'mouseForward': wentForward,
      'positionBeforeMs': position.inMilliseconds,
      'positionAfterMs': player.position.inMilliseconds,
      'volumeBefore': volumeBefore,
      'volumeAfter': playback.volume,
      'playing': player.playing.value,
      'tookMs': clock.elapsedMilliseconds,
      'keysReceived': keysReceived,
      'windowsKeysAtReady': keyStateAtReady,
      'windowsKeysAtEnd': windowsKeyState(),
      'focus':
          FocusManager.instance.primaryFocus?.debugLabel ??
          '${FocusManager.instance.primaryFocus?.runtimeType}',
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

  /// The song list with chips, a period and a sort (plan 04, C2): how long
  /// reading the play numbers, changing the period, adding a Plays chip and
  /// sorting by plays take, then the search keystrokes of [_searchBench]
  /// with all of that on. What the data folder had shown is put back.
  Future<Map<String, Object?>> _filteredSearchBench() async {
    final filters = library.filters;
    if (filters == null) return {'skipped': 'no filters'};
    final keptFilter = filters.filter;
    final keptPeriod = filters.period;
    final keptSort = (filters.sort, filters.descending);
    final keptView = filters.view?.id;
    library.showView(LibraryView.songs);
    await _settle();

    double timed(void Function() change) {
      final watch = Stopwatch()..start();
      change();
      return watch.elapsedMicroseconds / 1000;
    }

    final loadMs = timed(filters.reload);
    final steps = <String, double>{
      'clear': timed(filters.showAllSongs),
      'periodMonth': timed(() => filters.setPeriod(const PlayPeriod.month())),
      'periodYear': timed(() => filters.setPeriod(const PlayPeriod.year())),
      'periodAll': timed(() => filters.setPeriod(const PlayPeriod.all())),
      'periodLastYear': timed(
        () => filters.setPeriod(const PlayPeriod.year(offset: -1)),
      ),
      'playsChip': timed(
        () =>
            filters.setRule(const FilterRule(FilterField.plays, values: {'1'})),
      ),
      'sortByPlays': timed(() => filters.setSort(SongSort.plays)),
      'lastPlayedChip': timed(
        () => filters.setRule(
          FilterRule(FilterField.lastPlayed, values: const {'month+'}),
        ),
      ),
    };
    await _settle();
    final shown = library.visible.length;
    final typed = await _typeQueries(const [
      'кино',
      'ёлка',
      'metallica',
      'night city',
      'the',
      'love remix',
    ]);
    final playOneMs = timed(
      () => filters.playsChanged(library.visible.firstOrNull?.id),
    );

    filters
      ..setFilter(keptFilter)
      ..setPeriod(keptPeriod)
      ..setSort(keptSort.$1, descending: keptSort.$2);
    if (keptView != null) filters.openView(keptView);
    await _settle();
    return {
      'readNumbersMs': loadMs,
      'changeMs': steps,
      'songsShownFiltered': shown,
      'playEndedUpdateMs': playOneMs,
      ...typed,
    };
  }

  /// Stats (plan 04, D4): how long Stats, its Calendar tab and a whole
  /// year's report take to show, each from the change to the frame on
  /// screen, three times each. Uses last year, a full one. What the data
  /// folder had shown is put back.
  Future<Map<String, Object?>> _statsBench() async {
    final filters = library.filters;
    if (filters == null) return {'skipped': 'no filters'};
    final keptPeriod = filters.period;
    final keptView = library.view;
    final lastYear = filters.now.year - 1;
    final steps = <({String name, int startUs, int uiDoneUs})>[];

    Future<void> step(String name, void Function() change) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final startUs = Timeline.now;
      change();
      await WidgetsBinding.instance.endOfFrame;
      steps.add((name: name, startUs: startUs, uiDoneUs: Timeline.now));
    }

    for (var round = 0; round < 3; round++) {
      library.showView(LibraryView.songs);
      filters.setPeriod(const PlayPeriod.year(offset: -1));
      await _settle();
      await step(
        'stats',
        () => library.showView(const LibraryView(ViewKind.stats)),
      );
      await step('calendar', () => _tapKey('stats-tab-calendar'));
      await step('yearReport', () => library.openYearReport(lastYear));
      await step('back', library.goBack);
      // The next round opens Stats on its usual tab.
      _tapKey('stats-tab-songs');
    }
    await _settle();
    final result = <String, Object?>{'year': lastYear};
    for (final name in const ['stats', 'calendar', 'yearReport', 'back']) {
      final mine = steps.where((s) => s.name == name).toList();
      final toRaster = <double>[];
      for (final s in mine) {
        final frame = _firstFrameStartingAfter(s.startUs);
        if (frame == null) continue;
        toRaster.add(
          (frame.timestampInMicroseconds(FramePhase.rasterFinish) - s.startUs) /
              1000,
        );
      }
      result[name] = {
        'toRasterMs': toRaster,
        'uiDoneMs': [for (final s in mine) (s.uiDoneUs - s.startUs) / 1000],
      };
    }
    library.showView(keptView);
    filters.setPeriod(keptPeriod);
    await _settle();
    return result;
  }

  /// Calls the tap handler under the widget keyed [key], as a click would.
  void _tapKey(String key) {
    void Function()? onTap;
    void find(Element element) {
      if (onTap != null) return;
      final widget = element.widget;
      if (widget.key == ValueKey(key)) {
        void inner(Element e) {
          if (onTap != null) return;
          final w = e.widget;
          if (w is GestureDetector && w.onTap != null) {
            onTap = w.onTap;
            return;
          }
          e.visitChildElements(inner);
        }

        inner(element);
        return;
      }
      element.visitChildElements(find);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(find);
    final tap = onTap;
    if (tap == null) throw StateError('nothing to tap at $key');
    tap();
  }

  /// Types [queries] one character at a time and measures each keystroke
  /// until the frame showing its results is rasterized.
  Future<Map<String, Object?>> _typeQueries(List<String> queries) async {
    final keystrokes = <({int startUs, int uiDoneUs, int queryUs})>[];
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
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      library.searchText.clear();
      await WidgetsBinding.instance.endOfFrame;
    }
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
      'keystrokeToUiDoneMs': _stats([
        for (final k in keystrokes) (k.uiDoneUs - k.startUs) / 1000,
      ]),
      'searchMs': _stats([for (final k in keystrokes) k.queryUs / 1000]),
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
  /// The Artists place (plan 09, R13), best run with no stored photos: the
  /// first usable grid and the first photo timed apart, fast scrolling and
  /// search keystrokes while photos arrive, then 32 artist pages with VK's
  /// part and the memory after going back to Songs.
  Future<Map<String, Object?>> _artistsBench() async {
    final artists = this.artists;
    if (artists == null) return {'skipped': 'no artists'};
    library.searchText.clear();
    final indexBuiltBefore = artists.builtIndex != null;
    final rssBeforeMB = ProcessInfo.currentRss / (1024 * 1024);
    final open = Stopwatch()..start();
    library.showView(const LibraryView(ViewKind.artists));
    await WidgetsBinding.instance.endOfFrame;
    final gridMs = open.elapsedMilliseconds;
    final shown = artists.shown('');
    final withId = shown.where((a) => !a.nameOnly).toList();
    bool hasPhoto(Artist a) => artists.photoOf(a)?.large != null;
    int asked() => withId.where((a) => artists.photoOf(a) != null).length;
    final photosAtOpen = asked();
    const gridKey = ValueKey('artists-grid');
    // The first photo VK names (any artist), and the first one the grid
    // draws (decoded, in sight), apart.
    int? firstPhotoMs, firstShownMs;
    while (open.elapsed < const Duration(seconds: 30)) {
      if (firstPhotoMs == null && withId.any(hasPhoto)) {
        firstPhotoMs = open.elapsedMilliseconds;
      }
      if (_imagesShownUnder(gridKey) > 0) {
        firstShownMs = open.elapsedMilliseconds;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final shownAtFirst = _imagesShownUnder(gridKey);

    // Fast scrolling at once, while the photos keep coming (each request
    // asks the tiles from the first one in sight on): coversDecoded says
    // how many photos were decoded during each run.
    final grid = _scrollPositionUnder(gridKey);
    final scroll = <String, Object?>{};
    if (grid != null) {
      for (final pixelsPerSecond in [6000, 20000]) {
        scroll['${pixelsPerSecond}pxPerSec'] = await _scrollRun(
          pixelsPerSecond,
          seconds: 4,
          positionOf: () => _scrollPositionUnder(gridKey) ?? grid,
        );
      }
      _scrollPositionUnder(gridKey)?.jumpTo(0);
    }
    final photosBeforeSearch = asked();
    final search = await _typeQueries(const [
      'дайте',
      'кино',
      'the',
      'arctic',
      'ёлка',
    ]);
    final photosAfterSearch = asked();

    // 32 artist pages: VK's part of each, as a visit asks it. The test
    // account's own artists first (real VK ids), then generated ones.
    final real = [
      for (final a in withId)
        if (a.songs.any((t) => t.source == TrackSource.vk)) a,
    ];
    final picks = [
      ...real,
      ...withId.where((a) => !real.contains(a)),
    ].take(32).toList();
    final pages = <Map<String, Object?>>[];
    for (final artist in picks) {
      final ref = vkRefOf(artist.key, artist)!;
      final clock = Stopwatch()..start();
      library.openArtist(artist.key);
      await WidgetsBinding.instance.endOfFrame;
      final frameMs = clock.elapsedMilliseconds;
      while (artists.vkOf(ref).load == ArtistVkLoad.loading &&
          clock.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final vk = artists.vkOf(ref);
      pages.add({
        'real': real.contains(artist),
        'songs': artist.songs.length,
        'toFrameMs': frameMs,
        'vkMs': clock.elapsedMilliseconds,
        'load': vk.load.name,
        'popular': vk.page?.popular.songs.length,
        'releases': vk.page?.releases.length,
      });
    }
    final rssAfterPagesMB = ProcessInfo.currentRss / (1024 * 1024);
    library.showView(LibraryView.songs);
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(seconds: 10));
    await _settle();
    final loaded = [
      for (final page in pages)
        if (page['load'] == 'loaded') (page['vkMs']! as int).toDouble(),
    ];
    return {
      'artists': shown.length,
      'withId': withId.length,
      'indexBuiltBeforeOpen': indexBuiltBefore,
      'gridToFrameMs': gridMs,
      'firstPhotoMs': firstPhotoMs,
      'firstPhotoShownMs': firstShownMs,
      'photosShownAtFirst': shownAtFirst,
      'photosStoredAtOpen': photosAtOpen,
      'scroll': grid == null ? {'error': 'no grid'} : scroll,
      'photosAskedBeforeSearch': photosBeforeSearch,
      'search': search,
      'photosAskedAfterSearch': photosAfterSearch,
      'photosFound': withId.where(hasPhoto).length,
      'pages': pages.length,
      'pagesLoaded': loaded.length,
      'pageVkMs': _stats(loaded),
      'pageToFrameMs': _stats([
        for (final page in pages) (page['toFrameMs']! as int).toDouble(),
      ]),
      'pageLoads': {
        for (final load in ArtistVkLoad.values)
          load.name: pages.where((p) => p['load'] == load.name).length,
      },
      'rssMB': {
        'before': rssBeforeMB.round(),
        'after32Pages': rssAfterPagesMB.round(),
        'backOnSongs10s': (ProcessInfo.currentRss / (1024 * 1024)).round(),
      },
    };
  }

  /// How many decoded images are drawn inside the widget keyed [key].
  int _imagesShownUnder(Key key) {
    var count = 0;
    void inside(Element element) {
      final widget = element.widget;
      if (widget is RawImage && widget.image != null) count++;
      element.visitChildren(inside);
    }

    void visit(Element element) {
      if (element.widget.key == key) {
        inside(element);
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return count;
  }

  /// The scroll position of the scrollable inside the widget keyed [key].
  ScrollPosition? _scrollPositionUnder(Key key) {
    ScrollPosition? found;
    void inside(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        found = (element.state as ScrollableState).position;
        return;
      }
      element.visitChildren(inside);
    }

    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        inside(element);
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

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
    ScrollPosition Function()? positionOf,
  }) async {
    final scrolled = positionOf ?? () => library.scroll.position;
    scrolled().jumpTo(0);
    await _settle();
    _frames.clear();
    final decodesBefore = CoverFileImage.decodeCount;
    final startUs = Timeline.now;
    final done = Completer<void>();
    void onFrame(Duration _) {
      final elapsed = (Timeline.now - startUs) / 1e6;
      final position = scrolled();
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

  /// Plan 10 I2f: "Hear the words" in the real app, the way the Lyrics
  /// place runs it, on [hearKeys] = a Russian song, a song in another
  /// language and an instrumental (library keys; no lyrics anywhere). Each
  /// heard row and kept vocals of them are removed first. Steps: the
  /// Russian song stopped during separation (time to stop), then heard to
  /// the end while the list is scrolled during separation; the other song
  /// heard while another song plays and is shown (the run goes on for its
  /// own), Whisper fetched when first needed, scrolled and stopped during
  /// Whisper (time to stop), then heard again from its kept vocals to the
  /// end; the instrumental to "No singing found". Muted playback is checked
  /// to decode throughout; memory (working set and private) is sampled.
  /// Numbers and outcomes only, no words.
  Future<Map<String, Object?>> _hearLiveBench() async {
    final lyrics = this.lyrics!;
    final hearer = this.hearer!;
    final result = <String, Object?>{'threads': hearThreads};
    if (hearKeys.length != 3) return {'error': 'give 3 keys'};
    Track? songOf(String key) =>
        library.all.where((t) => t.sourceKey == key && t.inLibrary).firstOrNull;
    final songs = [for (final key in hearKeys) songOf(key)];
    if (songs.contains(null)) return {'error': 'a key is not in the library'};
    final russian = songs[0]!;
    final other = songs[1]!;
    final instrumental = songs[2]!;
    for (final song in songs) {
      final key = lyrics.routeKeyOf(song!)!;
      hearer.forget(key);
      for (final path in [
        hearer.vocalsPathOf(key),
        '${hearer.vocalsPathOf(key)}.from',
      ]) {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      }
    }

    // Memory: the process's working set and private bytes, sampled.
    int mb(int bytes) => bytes ~/ (1 << 20);
    Map<String, int> memoryNow() {
      final now = processMemory();
      return {
        'workingSetMB': mb(ProcessInfo.currentRss),
        'privateMB': now == null ? -1 : mb(now.private),
      };
    }

    var peakWorking = 0;
    var peakPrivate = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = memoryNow();
      peakWorking = max(peakWorking, now['workingSetMB']!);
      peakPrivate = max(peakPrivate, now['privateMB']!);
    });
    final idle = memoryNow();
    result['memoryBefore'] = idle;

    Future<Map<String, Object?>> play(Track song) async {
      final timing = await playback.playFrom([song], 0);
      return {
        'ok': timing?.ok,
        'sampleRate': timing?.sampleRate,
        'stillPlayingAfter1s': await _keepsPlaying(),
      };
    }

    /// Waits until [condition] or [limit]; false on the limit.
    Future<bool> until(bool Function() condition, Duration limit) async {
      final clock = Stopwatch()..start();
      while (!condition()) {
        if (clock.elapsed > limit) return false;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return true;
    }

    HearStage? stageOf(Track song) => hearer.stageOf(lyrics.routeKeyOf(song));
    bool inStep(Track song, String step, {bool started = false}) {
      final stage = stageOf(song);
      return stage is HearRunning &&
          stage.step == step &&
          (!started || (stage.share ?? 0) > 0);
    }

    /// The steps a run went through, in order; the previous run's listener
    /// goes, so each list holds its own run only.
    VoidCallback? noting;
    List<String> stepsOf(LyricsHearer hearer, List<String> into) {
      if (noting != null) hearer.removeListener(noting!);
      void note() {
        final stage = hearer.job?.stage;
        final name = switch (stage) {
          HearRunning(:final step) => step,
          HearDownloading(:final whisper) =>
            whisper ? 'download-whisper' : 'download',
          HearSaving() => 'save',
          HearStopping() => 'stopping',
          null => null,
        };
        if (name != null && (into.isEmpty || into.last != name)) {
          into.add(name);
        }
      }

      hearer.addListener(noting = note);
      return into;
    }

    Map<String, Object?> outcomeOf(HearOutcome outcome) => switch (outcome) {
      HearDone(:final heard) => {
        'outcome': 'done',
        'heard': heard.outcome.name,
        'model': heard.model?.name,
        'language': heard.language,
        'rough': heard.rough,
        'words': heard.wordCount,
        'lines': heard.lines.length,
        'confidence': heard.confidence,
        'russianConfidence': heard.russianConfidence,
      },
      HearStopped(:final download) => {
        'outcome': 'stopped',
        'download': download,
      },
      HearFailed(:final message) => {'outcome': 'failed', 'message': message},
    };

    try {
      // 1. The Russian song, stopped during separation.
      final r = <String, Object?>{'seconds': russian.durationSec};
      result['russian'] = r;
      r['play'] = await play(russian);
      lyrics.show(russian);
      await until(
        () => lyrics.state is LyricsMissing,
        const Duration(seconds: 40),
      );
      r['before'] = '${lyrics.state.runtimeType}';
      var steps = <String>[];
      stepsOf(hearer, steps);
      var clock = Stopwatch()..start();
      var running = hearer.hearShown();
      final separating = await until(
        () => inStep(russian, 'separate', started: true),
        const Duration(minutes: 3),
      );
      final stopClock = Stopwatch()..start();
      hearer.stop();
      var outcome = await running;
      r['stopDuringSeparation'] = {
        'reachedSeparation': separating,
        'afterMs': clock.elapsedMilliseconds - stopClock.elapsedMilliseconds,
        'stopMs': stopClock.elapsedMilliseconds,
        ...outcomeOf(outcome),
        'steps': steps,
        'heardKept': lyrics.heard != null,
        'vocalsLeft': File(hearer.vocalsPathOf(lyrics.routeKeyOf(russian)!))
            .existsSync(),
        'state': '${lyrics.state.runtimeType}',
      };

      // 2. Heard to the end; the list scrolled during separation.
      steps = [];
      stepsOf(hearer, steps);
      peakWorking = 0;
      peakPrivate = 0;
      clock = Stopwatch()..start();
      running = hearer.hearShown();
      await until(
        () => inStep(russian, 'separate', started: true),
        const Duration(minutes: 3),
      );
      final scrollSeparating = {
        '1500pxPerSec': await _scrollRun(1500, seconds: 4),
        '6000pxPerSec': await _scrollRun(6000, seconds: 4),
      };
      library.scroll.jumpTo(0);
      outcome = await running;
      final shown = lyrics.state;
      r['full'] = {
        ...outcomeOf(outcome),
        'ms': clock.elapsedMilliseconds,
        'steps': steps,
        'scrollWhileSeparating': scrollSeparating,
        'peakWorkingSetMB': peakWorking,
        'peakPrivateMB': peakPrivate,
        'shownSource': shown is LyricsShown ? shown.lyrics.source : null,
        'stillPlaying': player.player.state.playing,
      };

      // 3. The other song: heard while the Russian one plays and shows.
      final w = <String, Object?>{'seconds': other.durationSec};
      result['other'] = w;
      w['play'] = await play(other);
      lyrics.show(other);
      await until(
        () => lyrics.state is LyricsMissing,
        const Duration(seconds: 40),
      );
      steps = [];
      stepsOf(hearer, steps);
      peakWorking = 0;
      peakPrivate = 0;
      clock = Stopwatch()..start();
      running = hearer.hearShown();
      await until(
        () => inStep(other, 'separate', started: true),
        const Duration(minutes: 3),
      );
      w['switchPlay'] = await play(russian);
      lyrics.show(russian);
      await Future<void>.delayed(const Duration(seconds: 3));
      final switched = lyrics.state;
      w['whileOtherShown'] = {
        'otherStillHeard': stageOf(other) != null,
        'stageForShownSong': stageOf(russian)?.runtimeType.toString(),
        'shownSource': switched is LyricsShown ? switched.lyrics.source : null,
      };
      lyrics.show(other);
      // Whisper: fetched when first needed (the bundle may be there).
      final reachedWhisper = await until(
        () => inStep(other, 'whisper') || hearer.job == null,
        const Duration(minutes: 60),
      );
      w['whisperDownloadSeen'] = steps.contains('download-whisper');
      w['msToWhisper'] = clock.elapsedMilliseconds;
      if (reachedWhisper && hearer.job != null) {
        // A few seconds into the first chunk's encoder pass.
        await Future<void>.delayed(const Duration(seconds: 5));
        final scrollWhisper = {
          '1500pxPerSec': await _scrollRun(1500, seconds: 4),
          '6000pxPerSec': await _scrollRun(6000, seconds: 4),
        };
        // Again later in the same chunk: the first scroll meets the model's
        // load (hear-55a: 18 frames over there, 1 in the next scroll).
        await Future<void>.delayed(const Duration(seconds: 8));
        scrollWhisper['1500pxPerSecLater'] = await _scrollRun(1500, seconds: 4);
        library.scroll.jumpTo(0);
        final memoryWhisper = memoryNow();
        final stageAtStop = stageOf(other);
        final stopWhisper = Stopwatch()..start();
        hearer.stop();
        outcome = await running;
        w['stopDuringWhisper'] = {
          ...outcomeOf(outcome),
          'stopMs': stopWhisper.elapsedMilliseconds,
          'stageAtStop': stageAtStop == null
              ? null
              : hearStageText(stageAtStop),
          'scrollWhileWhisper': scrollWhisper,
          'memoryWhileWhisper': memoryWhisper,
          'peakWorkingSetMB': peakWorking,
          'peakPrivateMB': peakPrivate,
          'steps': steps,
          'vocalsLeft': File(hearer.vocalsPathOf(lyrics.routeKeyOf(other)!))
              .existsSync(),
          'heardKept': lyrics.heard != null,
        };
      } else {
        w['noWhisper'] = outcomeOf(await running);
      }

      // 4. Again, from the kept vocals, to the end.
      steps = [];
      stepsOf(hearer, steps);
      clock = Stopwatch()..start();
      outcome = await hearer.hearShown();
      final againShown = lyrics.state;
      w['again'] = {
        ...outcomeOf(outcome),
        'ms': clock.elapsedMilliseconds,
        'steps': steps,
        'shownSource': againShown is LyricsShown
            ? againShown.lyrics.source
            : null,
      };

      // 5. The instrumental.
      final i = <String, Object?>{'seconds': instrumental.durationSec};
      result['instrumental'] = i;
      i['play'] = await play(instrumental);
      lyrics.show(instrumental);
      await until(
        () => lyrics.state is LyricsMissing,
        const Duration(seconds: 40),
      );
      steps = [];
      stepsOf(hearer, steps);
      clock = Stopwatch()..start();
      outcome = await hearer.hearShown();
      final missing = lyrics.state;
      i['run'] = {
        ...outcomeOf(outcome),
        'ms': clock.elapsedMilliseconds,
        'steps': steps,
        'state': '${missing.runtimeType}',
        'stateHeard': missing is LyricsMissing
            ? missing.heard?.outcome.name
            : null,
      };
      i['stillPlaying'] = player.player.state.playing;
    } on Object catch (error) {
      result['error'] = '$error';
    } finally {
      sampler.cancel();
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    result['memoryAfter'] = memoryNow();
    return result;
  }

  /// Plan 10 G4: fits the lyrics of each of [fitKeys] to its recording the
  /// way Fit to recording does, with the model already there. Per song: it
  /// plays (muted) and decodes; the Lyrics place shows timed lyrics; the fit
  /// saves the song and runs; meanwhile the list is scrolled to see whether
  /// the fit costs frames; time, memory before / peak / after, the outcome,
  /// and every timed source's score afterwards (G3, from the cached model
  /// output). Line starts are numbers only, no words.
  Future<Map<String, Object?>> _fitLiveBench() async {
    final lyrics = this.lyrics!;
    final fitter = this.fitter!;
    final songs = <Map<String, Object?>>[];
    for (final key in fitKeys) {
      final track = library.all
          .where((t) => t.sourceKey == key && t.inLibrary)
          .firstOrNull;
      if (track == null) {
        songs.add({'key': key, 'error': 'not in the library'});
        continue;
      }
      final row = <String, Object?>{'key': key, 'seconds': track.durationSec};
      songs.add(row);
      try {
        final timing = await playback.playFrom([track], 0);
        row['play'] = {
          'ok': timing?.ok,
          'toSoundMs': timing?.toSoundMs,
          'sampleRate': timing?.sampleRate,
          'stillPlayingAfter1s': await _keepsPlaying(),
        };
        lyrics.show(track);
        final asked = Stopwatch()..start();
        while (!(lyrics.state is LyricsShown &&
                !(lyrics.state as LyricsShown).refreshing) &&
            asked.elapsed < const Duration(seconds: 40)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final state = lyrics.state;
        // Plain words are fitted too (H2); only lyrics the fit cannot read
        // are skipped.
        if (state is! LyricsShown || !canFitLines(state.lyrics.lines)) {
          row['lyrics'] = state is LyricsShown ? 'cannot be fitted' : '$state';
          continue;
        }
        final shown = state.lyrics;
        row['lyrics'] = {
          'source': shown.source,
          'timed': shown.timed,
          'lines': shown.lines.length,
          'gaps': shown.lines.where((l) => l.isGap).length,
          'shownAfterMs': asked.elapsedMilliseconds,
        };

        // The same scroll without a fit, as the baseline of this run.
        final baseline = await _scrollRun(1500, seconds: 4);
        library.scroll.jumpTo(0);
        final before = ProcessInfo.currentRss ~/ (1 << 20);
        var peak = before;
        final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
          final now = ProcessInfo.currentRss ~/ (1 << 20);
          if (now > peak) peak = now;
        });
        final clock = Stopwatch()..start();
        var savedMs = -1;
        void noteStage() {
          final job = fitter.job;
          if (savedMs < 0 && job != null && job.stage is FitRunning) {
            savedMs = clock.elapsedMilliseconds;
          }
        }

        fitter.addListener(noteStage);
        final fitting = fitter.fitShown();
        // Scroll while the model runs: does the fit cost the UI frames?
        while (savedMs < 0 && fitter.job != null) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final scrolls = <String, Object?>{};
        if (fitter.job != null) {
          scrolls['1500pxPerSec'] = await _scrollRun(1500, seconds: 4);
          scrolls['6000pxPerSec'] = await _scrollRun(6000, seconds: 4);
          library.scroll.jumpTo(0);
        }
        final outcome = await fitting;
        final fitMs = clock.elapsedMilliseconds;
        sampler.cancel();
        fitter.removeListener(noteStage);
        await Future<void>.delayed(const Duration(seconds: 3));
        row['fit'] = {
          'outcome': outcome.runtimeType.toString(),
          if (outcome case FitDone(:final sureShare)) 'sure': sureShare,
          if (outcome case FitNoMatch(:final sureShare)) 'sure': sureShare,
          if (outcome case FitFailed(:final message)) 'message': message,
          'ms': fitMs,
          'savedAfterMs': savedMs,
          'scrollBeforeFit1500pxPerSec': baseline,
          'scrollWhileFitting': scrolls,
          'memoryMB': {
            'before': before,
            'peak': peak,
            'after': ProcessInfo.currentRss ~/ (1 << 20),
          },
        };
        final fit = lyrics.fitFor(shown);
        if (fit?.starts case final starts?) {
          // Moves only where the source has times of its own (plain words
          // have none: Codex review of H2).
          final moves = [
            for (var i = 0; i < shown.lines.length; i++)
              if (!shown.lines[i].isGap && shown.lines[i].startMs != null)
                starts[i] - shown.lines[i].startMs!,
          ]..sort();
          if (moves.isNotEmpty) {
            row['moves'] = {
              'medianMs': moves[moves.length ~/ 2],
              'minMs': moves.first,
              'maxMs': moves.last,
            };
          }
          row['starts'] = {
            'source': [for (final l in shown.lines) l.startMs],
            'fitted': starts,
            'gap': [for (final l in shown.lines) l.isGap],
          };
        }

        // G3: every timed source's score from the cached model output.
        final ranked = Stopwatch()..start();
        await lyrics.askAll();
        await fitter.rankChoices();
        row['ranked'] = {
          'ms': ranked.elapsedMilliseconds,
          for (final choice in lyrics.choices)
            if (choice.lyrics?.timed ?? false)
              choice.source: fitter.scoreOf(choice.lyrics!),
        };
      } on Object catch (error) {
        row['error'] = '$error';
      } finally {
        await player.stop();
      }
    }
    return {'songs': songs};
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
        // Stage K: this play found the song's VK file swapped and switched.
        if (timing.versionNews != null) 'foundSwapped': true,
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
        // Stage K: this play found the song's VK file swapped and switched.
        if (timing.versionNews != null) 'foundSwapped': true,
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

  /// Streams, muted, up to [perSource] songs that only one VK account has,
  /// for every VK source, so each stream can only go through that account.
  /// The restart check of two accounts reads which source each one used.
  /// Row and source ids only: a second account's titles stay out of the file.
  Future<Map<String, Object?>> _playEachSource({int perSource = 3}) async {
    final bySource = <int, List<Track>>{};
    for (final track in library.all) {
      if (track.source != TrackSource.vk) continue;
      if (track.isCached || track.isGone || track.copies.isNotEmpty) continue;
      bySource.putIfAbsent(track.sourceId, () => []).add(track);
    }
    final result = <String, Object?>{};
    for (final MapEntry(key: sourceId, value: tracks) in bySource.entries) {
      tracks.shuffle(Random(11));
      final samples = <Map<String, Object?>>[];
      var ok = 0;
      // A few spare tries: VK withholds some songs from streaming.
      for (final track in tracks.take(perSource + 3)) {
        final timing = await player.play(track);
        final playing = timing.ok && await _keepsPlaying();
        samples.add({
          'row': track.id,
          'ok': timing.ok,
          'sourceId': timing.sourceId,
          'skippedAccounts': timing.skippedAccounts,
          'sampleRate': timing.sampleRate,
          'toSoundMs': timing.toSoundMs,
          // Stage K: this play found the song's VK file swapped and switched.
          if (timing.versionNews != null) 'foundSwapped': true,
          'stillPlayingAfter1s': playing,
          if (timing.error != null) 'error': timing.error,
        });
        await player.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (timing.ok && playing && ++ok == perSource) break;
      }
      result['$sourceId'] = {
        'onlyHere': tracks.length,
        'played': ok,
        'samples': samples,
      };
    }
    return result;
  }

  /// Plan 07 C4: the For you place as the user opens it. Shows the place
  /// (the lists come from <data>/for-you.json when an earlier run saved
  /// them, else from VK), opens each list the way a card's click does and
  /// times it to its first frame, then streams up to six recommended songs
  /// the library does not have, as a row's click does. Times and counts
  /// only: no names, links or keys.
  Future<Map<String, Object?>> _forYouBench() async {
    final forYou = this.forYou;
    if (forYou == null || forYou.account == null) {
      return {'skipped': 'no VK account'};
    }
    final page = Stopwatch()..start();
    library.showView(const LibraryView(ViewKind.forYou));
    await WidgetsBinding.instance.endOfFrame;
    final pageMs = page.elapsedMilliseconds;
    final fromCache = forYou.hasLists;
    int? refreshMs;
    if (!fromCache) {
      final clock = Stopwatch()..start();
      await forYou.refresh();
      refreshMs = clock.elapsedMilliseconds;
    }
    if (!forYou.hasLists) return {'error': 'no lists: ${forYou.error}'};
    final opens = <Map<String, Object?>>[];
    for (final list in forYou.lists) {
      library.showView(const LibraryView(ViewKind.forYou));
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final clock = Stopwatch()..start();
      library.openList(forYou.refOf(list));
      await WidgetsBinding.instance.endOfFrame;
      opens.add({
        'kind': list.kind.name,
        'rows': library.visible.length,
        'toFrameMs': clock.elapsedMilliseconds,
      });
    }
    // Songs the library does not have, from every list, in a fixed order.
    final seen = <String>{};
    final picks = <Track>[];
    for (final list in forYou.lists) {
      for (final song in forYou.songsOf(list.key)) {
        if (!song.playable || song.song.durationSec < 60) continue;
        if (!seen.add(song.key)) continue;
        final track = forYou.trackOf(song);
        if (forYou.libraryCopyOf((track: track, vkTrackId: null)) != null) {
          continue;
        }
        picks.add(track);
      }
    }
    picks.shuffle(Random(17));
    final samples = <Map<String, Object?>>[];
    for (final track in picks.take(6)) {
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
      'pageToFrameMs': pageMs,
      'listsFromCache': fromCache,
      'refreshMs': ?refreshMs,
      'lists': forYou.lists.length,
      'listOpens': opens,
      'listToFrameMs': _stats([
        for (final o in opens) (o['toFrameMs'] as int).toDouble(),
      ]),
      'outsideSongs': picks.length,
      'samples': samples,
      'toSoundMs': _stats(values('toSoundMs')),
      'networkFirstChunkMs': _stats(values('networkFirstChunkMs')),
      'overheadMs': _stats(values('overheadMs')),
    };
  }

  /// Plan 07: VK Mix keeps adding songs while it plays. Starts the mix as
  /// its card's Play does (VK gives 2-3 songs a call), then presses Next
  /// [steps] times through the real queue, so the app's own listener (in
  /// main.dart) has to ask VK for more before the list runs out. Each step
  /// waits up to 8 s for the list to grow past the playing song, and
  /// records the list's length and whether the song played. Counts only.
  Future<Map<String, Object?>> _forYouMixCheck({int steps = 8}) async {
    final forYou = this.forYou;
    if (forYou == null || forYou.account == null) {
      return {'skipped': 'no VK account'};
    }
    forYou.open();
    if (!forYou.hasLists) await forYou.refresh();
    if (!forYou.hasMix) return {'skipped': 'no VK Mix'};
    final first = await forYou.moreMix();
    if (first.isEmpty) return {'error': 'VK Mix gave no songs'};
    final firstTiming = await playback.playFrom(first, 0);
    final keys = <String>{?player.current?.sourceKey};
    final stepsOut = <Map<String, Object?>>[
      {
        'listLength': playback.queue.context.length,
        'ok': firstTiming?.ok,
        'sampleRate': firstTiming?.sampleRate,
      },
    ];
    var wrapped = false;
    for (var i = 0; i < steps; i++) {
      final at = playback.queue.context.indexWhere(
        (t) => t.id == player.current?.id,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (playback.queue.context.length <= at + 1 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final timing = await playback.next();
      final key = player.current?.sourceKey;
      final index = playback.queue.context.indexWhere(
        (t) => t.id == player.current?.id,
      );
      if (index <= at) wrapped = true;
      stepsOut.add({
        'listLength': playback.queue.context.length,
        'index': index,
        'newSong': key != null && keys.add(key),
        'ok': timing?.ok,
        'sampleRate': timing?.sampleRate,
        'stillPlayingAfter1s': (timing?.ok ?? false) && await _keepsPlaying(),
        if (timing?.error != null) 'error': timing!.error,
      });
    }
    await player.stop();
    return {
      'firstSongs': first.length,
      'finalListLength': playback.queue.context.length,
      'distinctSongsPlayed': keys.length,
      'stillMixList': forYou.isMixList(playback.queue.context),
      'wrappedToStart': wrapped,
      'steps': stepsOut,
    };
  }

  /// Plan 06 C6: search keystrokes with the On VK part on. Types each
  /// query as [_searchBench] does, waits for VK's songs under the own
  /// results (the time from the last keystroke includes the 0.5 s pause
  /// before VK is asked), then deletes and retypes the last letter, so two
  /// more keystrokes land while the part shows (loading, then VK's songs
  /// at once from the answer kept). One VK search per query. Times only.
  Future<Map<String, Object?>> _catalogKeysBench() async {
    final catalog = this.catalog;
    if (catalog == null || catalog.accounts.isEmpty) {
      return {'skipped': 'no VK account'};
    }
    library.showView(LibraryView.songs);
    await WidgetsBinding.instance.endOfFrame;
    const queries = ['кино', 'metallica', 'наутилус', 'love'];
    final typing = <int>[];
    final withPart = <int>[];
    final uiDoneMs = <double>[];
    final toPartMs = <int>[];
    final vkSongs = <int>[];
    Future<void> key(String text, List<int> into) async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final startUs = Timeline.now;
      library.searchText.text = text;
      await WidgetsBinding.instance.endOfFrame;
      uiDoneMs.add((Timeline.now - startUs) / 1000);
      into.add(startUs);
    }

    for (final query in queries) {
      for (var length = 1; length <= query.length; length++) {
        await key(query.substring(0, length), typing);
      }
      final clock = Stopwatch()..start();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while ((catalog.searching || catalog.songs.isEmpty) &&
          catalog.error == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await WidgetsBinding.instance.endOfFrame;
      toPartMs.add(clock.elapsedMilliseconds);
      vkSongs.add(catalog.songs.length);
      await key(query.substring(0, query.length - 1), withPart);
      await key(query, withPart);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      library.searchText.clear();
      await WidgetsBinding.instance.endOfFrame;
    }
    await _settle();
    List<double> toRaster(List<int> starts) => [
      for (final startUs in starts)
        if (_firstFrameStartingAfter(startUs) case final frame?)
          (frame.timestampInMicroseconds(FramePhase.rasterFinish) - startUs) /
              1000,
    ];
    return {
      'songs': library.all.length,
      'typingToRasterMs': _stats(toRaster(typing)),
      'withVkPartToRasterMs': _stats(toRaster(withPart)),
      'keystrokeToUiDoneMs': _stats(uiDoneMs),
      'lastKeyToVkSongsMs': _stats([for (final ms in toPartMs) ms.toDouble()]),
      'vkSongsShown': vkSongs,
      'vkError': catalog.error,
    };
  }

  /// Plan 06 C6: + on a found song, then Remove from library, its Undo, and
  /// Remove again, so the TEST account ends with the songs it had. Times
  /// what the user waits for: VK's yes and the library listing the song;
  /// the remove's VK call and the row's slide; Undo until the row is back.
  /// Run it only on a copy of the test account's data. Counts and times
  /// only: no names, links or keys.
  Future<Map<String, Object?>> _catalogAddBench() async {
    final catalog = this.catalog;
    final remover = this.remover;
    final vk = this.vk;
    if (catalog == null || remover == null || vk == null) {
      return {'skipped': 'no VK account'};
    }
    Future<int> vkCount() async {
      final reply = await vk.call('audio.get', {
        'owner_id': '${vk.userId}',
        'count': '1',
      }) as Map<String, dynamic>;
      return reply['count'] as int;
    }

    Future<bool> waitFor(bool Function() done, {int seconds = 15}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return done();
    }

    final vkBefore = await vkCount();
    final listedBefore = library.all.length;
    library.showView(LibraryView.songs);
    library.searchText.text = 'наутилус';
    await waitFor(() => !catalog.searching && catalog.songs.isNotEmpty);
    final pick = catalog.songs
        .where(
          (f) =>
              catalog.stateOf(f) == FoundState.addable &&
              f.song.durationSec >= 60,
        )
        .firstOrNull;
    if (pick == null) return {'error': 'no found song to add'};
    final result = <String, Object?>{'vkBefore': vkBefore};
    var clock = Stopwatch()..start();
    final note = catalog.add(pick);
    final added = await waitFor(
      () => catalog.stateOf(pick) == FoundState.inLibrary,
    );
    result['addToCheckMs'] = clock.elapsedMilliseconds;
    await note;
    final listed = await waitFor(
      () => library.all.length == listedBefore + 1,
      seconds: 10,
    );
    result['addToListedMs'] = clock.elapsedMilliseconds;
    result['added'] = added && listed;
    final copy = catalog.libraryCopyOfSong(pick.song);
    if (copy == null) return {...result, 'error': 'no library copy'};
    library.searchText.clear();
    await WidgetsBinding.instance.endOfFrame;
    result['vkAfterAdd'] = await vkCount();

    clock = Stopwatch()..start();
    final removed = await remover.remove(copy);
    result['removeMs'] = clock.elapsedMilliseconds;
    result['removed'] = removed.canUndo;
    await WidgetsBinding.instance.endOfFrame;
    result['vkAfterRemove'] = await vkCount();

    clock = Stopwatch()..start();
    final undoNote = await remover.undo(removed);
    await waitFor(() => library.all.any((t) => t.id == copy.id), seconds: 10);
    await WidgetsBinding.instance.endOfFrame;
    result['undoMs'] = clock.elapsedMilliseconds;
    result['undone'] = undoNote == null;
    result['sameRowBack'] = library.all.any((t) => t.id == copy.id);
    result['vkAfterUndo'] = await vkCount();

    // Back to how the account was.
    final again = library.byId(copy.id) ?? copy;
    clock = Stopwatch()..start();
    final last = await remover.remove(again);
    result['removeAgainMs'] = clock.elapsedMilliseconds;
    result['removedAgain'] = last.canUndo;
    final vkAfter = await vkCount();
    result['vkAfter'] = vkAfter;
    result['accountAsBefore'] = vkAfter == vkBefore;
    result['listedAfter'] = library.all.length;
    return result;
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
