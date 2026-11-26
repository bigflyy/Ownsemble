/// Plan 10 J8: word sync in the release app, on real songs of the test
/// account, muted, with the audio decoded.
///
/// Each song is given with what it should show: `heard` (words the app heard
/// before, kept in the data folder), `lrc` (LRCLIB lyrics with word stamps)
/// or `fit` (timed lyrics fitted to the recording here, with the real
/// aligner: the fit model must be in the data folder). For each: the song
/// plays the way a click plays it; the Lyrics place opens; the lyrics shown
/// are checked for word times (how many lines and words, in order, inside
/// their lines); the song moves into a word-timed line and the place is
/// checked for the word-lit line; the player's position reports are timed;
/// frames are timed while the words fill; then the song is paused and the
/// frames drawn while paused are counted (none are wanted).
///
/// Results hold numbers, sources and yes/no only, never words or names.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_fitter.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../ui/library_controller.dart';

class WordsLiveBench {
  WordsLiveBench({
    required this.library,
    required this.player,
    required this.playback,
    required this.lyrics,
    required this.fitter,
    required this.keys,
  });

  final LibraryController library;
  final PlayerService player;
  final PlaybackController playback;
  final LyricsController lyrics;
  final LyricsFitter? fitter;

  /// "kind=ownerId_audioId", kind one of heard, lrc, fit.
  final List<String> keys;

  Future<Map<String, Object?>> run() async {
    final songs = <Map<String, Object?>>[];
    for (final entry in keys) {
      final cut = entry.indexOf('=');
      if (cut < 0) {
        songs.add({'error': 'give kind=key'});
        continue;
      }
      final kind = entry.substring(0, cut);
      final key = entry.substring(cut + 1);
      final row = <String, Object?>{'kind': kind};
      songs.add(row);
      try {
        await _song(kind, key, row);
      } on Object catch (error) {
        row['error'] = '${error.runtimeType}: ${_short('$error')}';
      } finally {
        await player.stop();
      }
    }
    return {'songs': songs, 'memoryMB': ProcessInfo.currentRss ~/ (1 << 20)};
  }

  Future<void> _song(String kind, String key, Map<String, Object?> row) async {
    final track = library.all
        .where((t) => t.sourceKey == key && t.inLibrary)
        .firstOrNull;
    if (track == null) {
      row['error'] = 'not in the library';
      return;
    }
    final timing = await playback.playFrom([track], 0);
    row['play'] = {
      'ok': timing?.ok,
      'toSoundMs': timing?.toSoundMs,
      'sampleRate': timing?.sampleRate,
    };
    if (library.view.kind != ViewKind.lyrics) library.toggleLyrics();
    lyrics.show(track);
    final asked = Stopwatch()..start();
    while (!(lyrics.state is LyricsShown &&
            !(lyrics.state as LyricsShown).refreshing) &&
        asked.elapsed < const Duration(seconds: 40)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final state = lyrics.state;
    if (state is! LyricsShown) {
      row['lyrics'] = '${state.runtimeType}';
      return;
    }
    if (kind == 'fit') {
      row['fit'] = await _fit(state.lyrics);
    }
    final shown = lyrics.timedOf((lyrics.state as LyricsShown).lyrics);
    row['lyrics'] = _wordFacts(shown, (lyrics.state as LyricsShown).lyrics);
    row['fitted'] = lyrics.isFitted((lyrics.state as LyricsShown).lyrics);

    // Into a word-timed line: the middle of its second timed word.
    final index = shown.lines.indexWhere(
      (line) => (line.words?.whereType<WordTime>().length ?? 0) >= 3,
    );
    if (index < 0) {
      row['lit'] = 'no line with 3 timed words';
      return;
    }
    final word = shown.lines[index].words!.whereType<WordTime>().elementAt(1);
    final offset = lyrics.offsetOf((lyrics.state as LyricsShown).lyrics.source);
    final at = word.startMs + (word.endMs - word.startMs) ~/ 2 + offset;
    await playback.seek(Duration(milliseconds: at));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    row['lit'] = {
      'line': index,
      'wordLitLineShown': _sungClips() == 1,
      'stillPlaying': player.playing.value,
    };

    // The player's position reports while playing.
    final reports = <int>[];
    final clock = Stopwatch()..start();
    final listening = player.positions.listen(
      (_) => reports.add(clock.elapsedMilliseconds),
    );
    final frames = <FrameTiming>[];
    void onTimings(List<FrameTiming> timings) => frames.addAll(timings);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    await Future<void>.delayed(const Duration(seconds: 3));
    await listening.cancel();
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    final gaps = [
      for (var i = 1; i < reports.length; i++) reports[i] - reports[i - 1],
    ]..sort();
    row['positionReports'] = {
      'in3s': reports.length,
      'medianGapMs': gaps.isEmpty ? null : gaps[gaps.length ~/ 2],
      'maxGapMs': gaps.isEmpty ? null : gaps.last,
    };
    row['framesWhileLit'] = _frameFacts(frames, 3);

    // Paused: no frames wanted once the clock has stopped.
    await playback.playOrPause();
    await Future<void>.delayed(const Duration(seconds: 1));
    final paused = <FrameTiming>[];
    void onPaused(List<FrameTiming> timings) => paused.addAll(timings);
    SchedulerBinding.instance.addTimingsCallback(onPaused);
    await Future<void>.delayed(const Duration(seconds: 2));
    SchedulerBinding.instance.removeTimingsCallback(onPaused);
    row['paused'] = {
      'playing': player.playing.value,
      'framesIn2s': paused.length,
      'wordLitLineShown': _sungClips() == 1,
    };
    row['memoryMB'] = ProcessInfo.currentRss ~/ (1 << 20);
  }

  /// Fits [shown] to the recording with the real aligner.
  Future<Map<String, Object?>> _fit(Lyrics shown) async {
    final fitter = this.fitter;
    if (fitter == null) return {'error': 'no fitter'};
    if (!fitter.modelReady) return {'error': 'no fit model in the data folder'};
    final clock = Stopwatch()..start();
    final outcome = await fitter.fitShown();
    final fit = lyrics.fitFor(shown);
    final words = fit?.words;
    final starts = fit?.starts;
    // How far each fitted line's first timed word is from its fitted start.
    final firstWordMs = <int>[];
    if (words != null && starts != null) {
      for (var i = 0; i < words.length && i < starts.length; i++) {
        final first = words[i]?.whereType<WordTime>().firstOrNull;
        if (first != null) firstWordMs.add((first.startMs - starts[i]).abs());
      }
    }
    firstWordMs.sort();
    return {
      'outcome': outcome.runtimeType.toString(),
      'ms': clock.elapsedMilliseconds,
      'sure': fit?.sureShare,
      'linesWithWords': words?.where((line) => line != null).length,
      'firstWordFromLineStartMs': firstWordMs.isEmpty
          ? null
          : {
              'median': firstWordMs[firstWordMs.length ~/ 2],
              'max': firstWordMs.last,
            },
    };
  }

  /// What the lyrics shown hold in word times.
  Map<String, Object?> _wordFacts(Lyrics shown, Lyrics source) {
    var linesWithWords = 0, words = 0, timedWords = 0, outOfOrder = 0;
    var outsideLine = 0;
    for (var i = 0; i < shown.lines.length; i++) {
      final line = shown.lines[i];
      final lineWords = line.words;
      if (lineWords == null) continue;
      linesWithWords++;
      words += lineWords.length;
      var previous = -1;
      final next = i + 1 < shown.lines.length
          ? shown.lines[i + 1].startMs
          : null;
      for (final word in lineWords.whereType<WordTime>()) {
        timedWords++;
        if (word.startMs < previous || word.endMs < word.startMs) outOfOrder++;
        previous = word.startMs;
        final start = line.startMs ?? 0;
        if (word.startMs < start - 1000 ||
            (next != null && word.startMs > next + 1000)) {
          outsideLine++;
        }
      }
    }
    return {
      'source': source.source,
      'timed': shown.timed,
      'lines': shown.lines.where((line) => !line.isGap).length,
      'linesWithWords': linesWithWords,
      'words': words,
      'timedWords': timedWords,
      'outOfOrder': outOfOrder,
      'outsideTheirLine': outsideLine,
    };
  }

  /// How many word-lit lines the window shows now.
  int _sungClips() {
    var count = 0;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is ClipPath &&
          '${widget.clipper.runtimeType}' == '_SungClip') {
        count++;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return count;
  }

  static Map<String, Object?> _frameFacts(List<FrameTiming> frames, int s) {
    if (frames.isEmpty) return {'frames': 0};
    final build = [for (final f in frames) f.buildDuration.inMicroseconds]
      ..sort();
    final raster = [for (final f in frames) f.rasterDuration.inMicroseconds]
      ..sort();
    int p95(List<int> sorted) =>
        sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    return {
      'frames': frames.length,
      'perSecond': frames.length / s,
      'buildP95Us': p95(build),
      'rasterP95Us': p95(raster),
      'over16ms': frames
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > 16667 ||
                f.rasterDuration.inMicroseconds > 16667,
          )
          .length,
    };
  }

  /// An error's text without links (stream links carry signatures).
  static String _short(String text) {
    final cut = text.replaceAll(RegExp(r'https?://\S+'), '<link>');
    return cut.length > 160 ? cut.substring(0, 160) : cut;
  }
}
