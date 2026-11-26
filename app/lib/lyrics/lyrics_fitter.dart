/// "Fit to this recording" on the Lyrics place (plan 10 G2): the steps of
/// one fit and how far they are.
///
/// One fit at a time (a fit takes up to 1.4 GB and 4 CPU threads): the
/// model is downloaded on the first use the user agreed to, the song is
/// saved when it only streams, then the shown lyrics are fitted to that
/// file in a background isolate. What the click saw (the upload, the
/// source, its lyrics) is what is fitted and kept, also when the user moves
/// on to another song meanwhile.
///
/// The chooser's ranking (G3): with the model there and the song stored,
/// every source's timed lyrics get a score, the share of their lines placed
/// with confidence in this recording ([scoreOf]). Once a recording's model
/// output is cached (after its first fit or check) this takes a moment per
/// source; the first check runs the model (about 20 s). Scores stay for
/// this run only and move no line.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/track.dart';
import 'audio_decode.dart' show DecodeError;
import 'fit_model.dart';
import 'fitted_lines.dart';
import 'lyrics.dart';
import 'lyrics_controller.dart';
import 'onnx_runtime.dart' show OnnxError;
import 'recording_fit.dart';

/// How far a fit is.
sealed class FitStage {
  const FitStage();
}

/// The model is being downloaded: [bytes] of [total].
class FitDownloading extends FitStage {
  const FitDownloading(this.bytes, this.total);
  final int bytes;
  final int total;
}

/// The song is being saved, [share] of it (0 to 1; 0 while it starts).
class FitSaving extends FitStage {
  const FitSaving(this.share);
  final double share;
}

/// The model runs over the song, [share] of it done.
class FitRunning extends FitStage {
  const FitRunning(this.share);
  final double share;
}

/// What a fit came to.
sealed class FitOutcome {
  const FitOutcome();
}

/// The lines were moved; [sureShare] of them were placed with confidence.
class FitDone extends FitOutcome {
  const FitDone(this.sureShare);
  final double sureShare;
}

/// Fewer than half the lines could be placed with confidence: the lyrics
/// probably belong to another recording. Nothing moved. For [plain] words
/// the words also had to beat their own shuffled order; [undecided] when
/// they repeat too few different lines to tell.
class FitNoMatch extends FitOutcome {
  const FitNoMatch(
    this.sureShare, {
    this.plain = false,
    this.undecided = false,
  });
  final double sureShare;
  final bool plain;
  final bool undecided;
}

/// The fit did not finish; [message] says why, [retry] whether trying
/// again may help.
class FitFailed extends FitOutcome {
  const FitFailed(this.message, {this.retry = true});
  final String message;
  final bool retry;
}

/// The user stopped the model's download.
class FitStopped extends FitOutcome {
  const FitStopped();
}

/// Why a song's audio file could not be had.
class FitAudioError implements Exception {
  const FitAudioError(this.message);
  final String message;
}

/// The fit being made: which upload and source, and how far.
class FitJob {
  FitJob(this.key, this.source, this.stage);
  final String key;
  final String source;
  FitStage stage;
}

class LyricsFitter extends ChangeNotifier {
  LyricsFitter({
    required this.lyrics,
    required this.modelFile,
    required this.downloadModelTo,
    required this.audioOf,
    required this.fit,
    this.storedAudioOf,
    this.hasCachedOutput,
    this.model,
    this.log,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LyricsController lyrics;

  /// Where the model is kept (DATA/models/...).
  final File modelFile;

  /// What the model must be; [alignerModel] when null.
  final ModelFile? model;

  /// Downloads the model into [modelFile] (fit_model.downloadModel).
  final Future<void> Function(
    void Function(int bytes, int total) onProgress,
    DownloadStop stop,
  )
  downloadModelTo;

  /// The path of [track]'s stored audio, saving it first when it is not
  /// stored; [onProgress] hears how much is saved. Throws [FitAudioError].
  final Future<String> Function(
    Track track,
    void Function(double share) onProgress,
  )
  audioOf;

  /// Fits [lines] to the file at [audioPath] (recording_fit.fitToRecording
  /// with the app's tools and the upload's emission cache).
  final Future<RecordingFit> Function(
    String key,
    String audioPath,
    List<LyricLine> lines,
    void Function(int done, int total) onProgress,
  )
  fit;

  /// The path of [track]'s stored audio file, null when it is not stored
  /// (the ranking never saves a song).
  final String? Function(Track track)? storedAudioOf;

  /// Whether the model's output for the upload [key] is cached, so scoring
  /// needs no model run.
  final bool Function(String key)? hasCachedOutput;

  /// One line to perf.log: times and outcomes only.
  final void Function(String line)? log;

  /// Why another heavy job ("Hear the words") keeps a fit or a fit check
  /// from starting now; null when none runs (one heavy lyrics job at a
  /// time, plan 10 I2f).
  String? Function()? busyElsewhere;

  /// Scores by "upload key|source": for which lyrics and file, and the
  /// share of sure lines.
  final _scores = <String, ({String hash, int bytes, double sure})>{};

  final int Function() _now;

  ModelFile get _model => model ?? alignerModel;

  bool _modelKnown = false;

  /// Whether the model is downloaded (its size is checked once it is).
  bool get modelReady {
    if (_modelKnown) return true;
    return _modelKnown = hasModel(modelFile, _model);
  }

  /// The model's size in MB, for the question before the download.
  int get modelMegabytes => _model.megabytes;

  FitJob? _job;
  DownloadStop? _stop;

  /// The fit running now, null when none.
  FitJob? get job => _job;

  /// How far the fit of [source]'s lines for the upload [key] is; null
  /// when it is not running.
  FitStage? stageOf(String? key, String source) {
    final job = _job;
    if (job == null || key == null) return null;
    return job.key == key && job.source == source ? job.stage : null;
  }

  void _move(FitJob job, FitStage stage) {
    final shows = fitStageText(job.stage) != fitStageText(stage);
    job.stage = stage;
    if (shows) notifyListeners();
  }

  /// The source name a ranking job runs under.
  static const rankJob = '*ranking*';

  /// The share of [candidate]'s lines placed with confidence in the
  /// recording of the song shown; null when not scored (or scored for
  /// other lyrics or another file).
  double? scoreOf(Lyrics candidate) {
    final key = lyrics.shownKey;
    final track = lyrics.track;
    if (key == null || track == null || !candidate.timed) return null;
    final score = _scores['$key|${candidate.source}'];
    if (score == null || score.hash != lyricsHashOf(candidate)) return null;
    final path = storedAudioOf?.call(track);
    if (path != null && File(path).lengthSync() != score.bytes) return null;
    return score.sure;
  }

  /// Whether the chooser can offer a check: the model is there, the song
  /// is in the library and stored, and some timed lyrics are not scored.
  bool get canRank {
    final track = lyrics.track;
    if (track == null || !track.inLibrary || !modelReady) return false;
    if (storedAudioOf?.call(track) == null) return false;
    return lyrics.choices.any(
      (choice) =>
          (choice.lyrics?.timed ?? false) && scoreOf(choice.lyrics!) == null,
    );
  }

  /// Whether ranking the song shown needs no model run.
  bool get rankIsQuick {
    final key = lyrics.shownKey;
    return key != null && (hasCachedOutput?.call(key) ?? false);
  }

  /// Scores every timed source's lyrics for the song shown that is not
  /// scored yet. Without [runModel] only when the model's output is cached
  /// (a moment); with it, the model runs first when needed (about 20 s).
  Future<void> rankChoices({bool runModel = false}) async {
    if (_job != null || !canRank || busyElsewhere?.call() != null) return;
    if (!runModel && !rankIsQuick) return;
    final track = lyrics.track!;
    final key = lyrics.shownKey!;
    final path = storedAudioOf!(track)!;
    final bytes = File(path).lengthSync();
    final wanted = [
      for (final choice in lyrics.choices)
        if ((choice.lyrics?.timed ?? false) && scoreOf(choice.lyrics!) == null)
          choice.lyrics!,
    ];
    final job = _job = FitJob(key, rankJob, const FitRunning(0));
    notifyListeners();
    final clock = Stopwatch()..start();
    try {
      for (final (i, candidate) in wanted.indexed) {
        double sure;
        try {
          final result = await fit(key, path, candidate.lines, (done, total) {
            final share = total == 0 ? 0 : done / total;
            _move(job, FitRunning((i + share) / wanted.length));
          });
          sure = result.sureShare;
        } on FitError {
          sure = 0; // Lyrics the aligner cannot read do not fit.
        }
        _scores['$key|${candidate.source}'] = (
          hash: lyricsHashOf(candidate),
          bytes: bytes,
          sure: sure,
        );
        _move(job, FitRunning((i + 1) / wanted.length));
      }
      log?.call(
        'lyrics rank ${wanted.length} sources ${clock.elapsedMilliseconds} ms',
      );
    } on Object catch (error) {
      log?.call(
        'lyrics rank failed ${error.runtimeType} ${clock.elapsedMilliseconds} ms',
      );
    } finally {
      _job = null;
      notifyListeners();
    }
  }

  /// Stops the model's download; what came stays for the next try.
  void stopDownload() => _stop?.stop();

  /// Fits the lyrics the place shows to the song's recording. Returns at
  /// once with [FitFailed] when a fit runs already or nothing timed shows,
  /// or when [forKey] is given and the place shows another upload now (the
  /// question before the download was answered after the song moved on).
  Future<FitOutcome> fitShown({String? forKey}) async {
    final track = lyrics.track;
    final key = lyrics.shownKey;
    final state = lyrics.state;
    if (_job != null) {
      return const FitFailed('Another fit is running; wait for it.');
    }
    final busy = busyElsewhere?.call();
    if (busy != null) return FitFailed(busy, retry: false);
    if (track == null || key == null || state is! LyricsShown) {
      return const FitFailed('No lyrics to fit.', retry: false);
    }
    if (forKey != null && forKey != key) {
      return const FitFailed(
        'Another song plays now; fit it from its own lyrics.',
        retry: false,
      );
    }
    if (!track.inLibrary) {
      return const FitFailed(
        'Add the song to your library to fit its lyrics: fitting needs the '
        'song saved.',
        retry: false,
      );
    }
    final shown = state.lyrics;
    if (!canFitLines(shown.lines)) {
      return const FitFailed(
        'These lyrics cannot be fitted: too few lines in letters the fit '
        'can read.',
        retry: false,
      );
    }
    final job = _job = FitJob(key, shown.source, const FitSaving(0));
    final clock = Stopwatch()..start();
    var modelMs = 0;
    var audioMs = 0;
    try {
      if (!modelReady) {
        job.stage = FitDownloading(0, _model.bytes);
        notifyListeners();
        final stop = _stop = DownloadStop();
        await downloadModelTo(
          (bytes, total) => _move(job, FitDownloading(bytes, total)),
          stop,
        );
        _stop = null;
        _modelKnown = false;
        if (!modelReady) {
          return const FitFailed('The model did not download.');
        }
        modelMs = clock.elapsedMilliseconds;
      }
      job.stage = const FitSaving(0);
      notifyListeners();
      final path = await audioOf(
        track,
        (share) => _move(job, FitSaving(share)),
      );
      audioMs = clock.elapsedMilliseconds - modelMs;
      // Another version chosen meanwhile: the saved file is that version's
      // recording, not the one these lyrics were asked for (Codex review).
      if (lyrics.routeKeyOf(track) != key) {
        return const FitFailed(
          "The song's version changed while it was saved; fit again.",
        );
      }
      // Measured before the fit reads it: the size names the recording.
      final audioBytes = File(path).lengthSync();
      job.stage = const FitRunning(0);
      notifyListeners();
      final result = await fit(
        key,
        path,
        shown.lines,
        (done, total) => _move(job, FitRunning(total == 0 ? 0 : done / total)),
      );
      final fits = result.fits;
      // A fit made again (to time the words) keeps the hand offset the
      // user gave the fit it replaces.
      final replaced = lyrics.fitFor(shown)?.fits ?? false;
      lyrics.keepFit(
        key,
        shown.source,
        StoredFit(
          lyricsHash: lyricsHashOf(shown),
          audioBytes: audioBytes,
          starts: !fits
              ? null
              : result.plain
              ? plainLineStarts(
                  shown.lines,
                  result.lines,
                  lengthMs: (result.audioSeconds * 1000).round(),
                )
              : fittedLineStarts(
                  shown.lines,
                  result.lines,
                  lengthMs: (result.audioSeconds * 1000).round(),
                ),
          sureShare: result.sureShare,
          fittedAtMs: _now(),
          words: !fits
              ? null
              : [
                  for (var i = 0; i < shown.lines.length; i++)
                    result.lines[i]?.words,
                ],
        ),
        keepOffset: replaced && fits,
      );
      log?.call(
        'lyrics fit ${shown.source}${result.plain ? ' words' : ''} '
        '${fits ? 'fits' : 'no match'} sure '
        '${result.sureShare.toStringAsFixed(2)} '
        '${result.plain ? 'gain ${result.shuffleGain?.toStringAsFixed(3) ?? 'none'} ' : ''}'
        '${clock.elapsedMilliseconds} ms (model $modelMs, audio $audioMs, '
        'fit ${result.elapsedMs})',
      );
      return fits
          ? FitDone(result.sureShare)
          : FitNoMatch(
              result.sureShare,
              plain: result.plain,
              undecided: result.undecided,
            );
    } on DownloadStopped {
      log?.call('lyrics fit model download stopped');
      return const FitStopped();
    } on Object catch (error) {
      log?.call(
        'lyrics fit ${shown.source} failed ${error.runtimeType} '
        '${clock.elapsedMilliseconds} ms',
      );
      // The model file has the right size but may have the wrong bytes: it
      // is checked, and a damaged one is deleted so the next fit downloads
      // it again (Codex review).
      if (error is OnnxError && !await modelIntact(modelFile, _model)) {
        _modelKnown = false;
        try {
          modelFile.deleteSync();
        } on FileSystemException {
          // Still open somewhere; the size check finds it next time.
        }
        log?.call('lyrics fit model damaged, deleted');
        return const FitFailed(
          'The fit model was damaged and was deleted; the next fit downloads '
          'it again.',
        );
      }
      return failureOf(error);
    } finally {
      _stop = null;
      _job = null;
      notifyListeners();
    }
  }
}

/// What a stage shows, so listeners hear only changes that show: the
/// download reports every few kilobytes.
String fitStageText(FitStage stage) => switch (stage) {
  FitDownloading(:final bytes, :final total) =>
    'downloading the fit model, '
        '${total == 0 ? 0 : bytes * 100 ~/ total}% of ${total ~/ 1000000} MB',
  FitSaving(:final share) => 'saving the song, ${(share * 100).floor()}%',
  FitRunning(:final share) =>
    'fitting to this recording, ${(share * 100).floor()}%',
};

/// A short reason to show for a fit that failed.
FitFailed failureOf(Object error) => switch (error) {
  ModelDownloadError(:final message, :final retry) => FitFailed(
    message,
    retry: retry,
  ),
  FitAudioError(:final message) => FitFailed(
    'Could not save the song: $message',
  ),
  FitError(:final message) => FitFailed(
    'These lyrics cannot be fitted: $message.',
    retry: false,
  ),
  DecodeError() => const FitFailed("Could not read the song's audio."),
  OnnxError() => const FitFailed(
    'The fit model could not run. Try again; if it fails again, the model '
    'file may be damaged.',
  ),
  _ => const FitFailed('Fitting failed. Try again.'),
};
