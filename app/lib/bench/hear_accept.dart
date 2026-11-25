/// Plan 10 I2h: the acceptance of Hear the words in the release app, on
/// real songs of the test account, muted, with the audio decoded.
///
/// Part hearAccept: each song of [HearAcceptBench.keys] in turn is played
/// (muted; the decoder's sample rate and a second of position are checked),
/// shown in the Lyrics place, its heard words and kept vocals forgotten,
/// and then heard the way the Hear button does it, to the end. Per song:
/// what the place showed before (a found source or nothing), the steps the
/// run went through with the time each began, the whole time, the peak
/// memory of the process, the outcome (route, language, rough, counts,
/// confidences) and what the place shows afterwards (heard words when no
/// source has lyrics, the found lyrics otherwise, with the heard words
/// kept for the chooser).
///
/// The heard words themselves stay in the data folder's library.db
/// (heard_lyrics); experiments/f2-timing/stt_accept.py scores them against
/// the research transcripts and the lyrics. Results hold numbers, sources
/// and yes/no only, never words.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../library/track.dart';
import '../lyrics/heard_lyrics.dart' show heardSource;
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_hearer.dart';
import '../platform/process_memory.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../ui/library_controller.dart';

class HearAcceptBench {
  HearAcceptBench({
    required this.library,
    required this.player,
    required this.playback,
    required this.lyrics,
    required this.hearer,
    required this.keys,
    required this.threads,
  });

  final LibraryController library;
  final PlayerService player;
  final PlaybackController playback;
  final LyricsController lyrics;
  final LyricsHearer hearer;

  /// The songs' library keys, heard in this order.
  final List<String> keys;

  /// The CPU threads the hearer uses (the stt.threads setting).
  final int threads;

  /// Waits until [condition] or [limit]; false on the limit.
  Future<bool> _until(bool Function() condition, Duration limit) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > limit) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  /// The place has its answer: lyrics with every source asked, or none.
  bool get _settled => switch (lyrics.state) {
    LyricsShown(:final refreshing) => !refreshing,
    LyricsMissing() || LyricsFailed() => true,
    LyricsLoading() => false,
  };

  /// What the place shows: the source of the lyrics, 'missing' (with the
  /// heard outcome when it is one), or the state's name.
  String _shows() => switch (lyrics.state) {
    LyricsShown(:final lyrics) => lyrics.source,
    LyricsMissing(:final heard) =>
      heard == null ? 'missing' : 'missing:${heard.outcome.name}',
    LyricsFailed() => 'failed',
    LyricsLoading() => 'loading',
  };

  static int _mb(int bytes) => bytes ~/ (1 << 20);

  Map<String, int> _memoryNow() {
    final now = processMemory();
    return {
      'workingSetMB': _mb(ProcessInfo.currentRss),
      'privateMB': now == null ? -1 : _mb(now.private),
    };
  }

  /// True when the position reaches one second within five seconds: mpv
  /// decodes real audio.
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

  Map<String, Object?> _outcomeOf(HearOutcome outcome) => switch (outcome) {
    HearDone(:final heard) => {
      'outcome': 'done',
      'heard': heard.outcome.name,
      'model': heard.model?.name,
      'language': heard.language,
      'rough': heard.rough,
      'words': heard.wordCount,
      'lines': heard.lines.length,
      'gaps': heard.lines.where((line) => line.isGap).length,
      'confidence': heard.confidence,
      'russianConfidence': heard.russianConfidence,
      'loudSeconds': heard.loudSeconds,
    },
    HearStopped(:final download) => {
      'outcome': 'stopped',
      'download': download,
    },
    HearFailed(:final message) => {'outcome': 'failed', 'message': message},
  };

  Future<Map<String, Object?>> run() async {
    final result = <String, Object?>{
      'threads': threads,
      'memoryBefore': _memoryNow(),
    };
    final songs = <Map<String, Object?>>[];
    result['songs'] = songs;
    var peakWorking = 0;
    var peakPrivate = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = _memoryNow();
      peakWorking = max(peakWorking, now['workingSetMB']!);
      peakPrivate = max(peakPrivate, now['privateMB']!);
    });
    try {
      for (final key in keys) {
        final row = <String, Object?>{'key': key};
        songs.add(row);
        final Track? song = library.all
            .where((t) => t.sourceKey == key && t.inLibrary)
            .firstOrNull;
        if (song == null) {
          row['error'] = 'not in the library';
          continue;
        }
        row['seconds'] = song.durationSec;
        try {
          await _hearOne(song, row, () {
            peakWorking = 0;
            peakPrivate = 0;
          }, () => {'workingSetMB': peakWorking, 'privateMB': peakPrivate});
        } on Object catch (error) {
          row['error'] = '$error';
          if (hearer.job != null) {
            hearer.stop();
            await _until(() => hearer.job == null, const Duration(minutes: 2));
          }
        }
      }
    } finally {
      sampler.cancel();
    }
    await player.stop();
    await Future<void>.delayed(const Duration(seconds: 5));
    result['memoryAfter'] = _memoryNow();
    return result;
  }

  Future<void> _hearOne(
    Track song,
    Map<String, Object?> row,
    void Function() resetPeak,
    Map<String, int> Function() peak,
  ) async {
    final timing = await playback.playFrom([song], 0);
    row['play'] = {
      'ok': timing?.ok,
      'sampleRate': timing?.sampleRate,
      'stillPlayingAfter1s': (timing?.ok ?? false) && await _keepsPlaying(),
    };
    lyrics.show(song);
    final key = lyrics.routeKeyOf(song);
    if (key == null) {
      row['error'] = 'no upload key';
      return;
    }
    // A clean start: no heard words, no kept vocals of this upload.
    await _until(() => _settled, const Duration(seconds: 40));
    if (lyrics.heard != null) {
      hearer.forget(key);
      await _until(() => _settled, const Duration(seconds: 40));
    }
    for (final path in [
      hearer.vocalsPathOf(key),
      '${hearer.vocalsPathOf(key)}.from',
    ]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
    final found = lyrics.state is LyricsShown
        ? (lyrics.state as LyricsShown).lyrics.source
        : null;
    row['before'] = _shows();

    // The steps of this run, each with the time it began.
    final steps = <Map<String, Object?>>[];
    final clock = Stopwatch()..start();
    void note() {
      final name = switch (hearer.job?.stage) {
        HearRunning(:final step) => step,
        HearDownloading(:final whisper) =>
          whisper ? 'download-whisper' : 'download',
        HearSaving() => 'save',
        HearStopping() => 'stopping',
        null => null,
      };
      if (name != null && (steps.isEmpty || steps.last['step'] != name)) {
        steps.add({'step': name, 'atMs': clock.elapsedMilliseconds});
      }
    }

    hearer.addListener(note);
    resetPeak();
    final startPosition = player.player.state.position;
    final HearOutcome outcome;
    try {
      outcome = await hearer.hearShown(forKey: key);
    } finally {
      hearer.removeListener(note);
    }
    row['ms'] = clock.elapsedMilliseconds;
    row['steps'] = steps;
    row['peak'] = peak();
    row.addAll(_outcomeOf(outcome));
    // Playback went on during the run (or the song ended meanwhile).
    row['playbackMovedSeconds'] =
        (player.player.state.position - startPosition).inMilliseconds / 1000;
    row['playingAtEnd'] = player.playing.value;
    await _until(() => _settled, const Duration(seconds: 40));
    row['after'] = _shows();
    row['heardKept'] = lyrics.heard != null;
    // What the place should show: the found lyrics stay first; without any,
    // the heard words (or the No singing found message).
    final shows = _shows();
    row['placeAsExpected'] = switch (outcome) {
      HearDone() when found != null => shows == found && lyrics.heard != null,
      HearDone(:final heard) when heard.lines.isNotEmpty =>
        shows == heardSource,
      HearDone() => shows.startsWith('missing:'),
      _ => false,
    };
  }
}
