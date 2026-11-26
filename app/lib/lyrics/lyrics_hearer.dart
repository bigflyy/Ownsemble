/// "Hear the words" on the Lyrics place (plan 10 I2f): the steps of one
/// run for the song shown and how far they are.
///
/// One run at a time, and never beside a fit or a fit check (a run takes up
/// to 1.4 GB private memory and 8 CPU threads; Codex review). Before the
/// first run the user agrees to the models: the hear-words bundle (395 MB)
/// is fetched then, the Whisper bundle (585 MB) only when a song GigaAM is
/// not sure of first needs it, inside that run (the same question named
/// both). The song is saved first when it only streams, then [HearWords]
/// runs its stages on a worker. What the click saw (the upload) is what is
/// heard and kept, also when the user moves on to another song meanwhile.
///
/// Stop: a download stops at once and goes on next time; saving the song
/// is left to finish by itself; a run stops at its job's next check
/// (Whisper up to one encoder pass late, about 15 s), so the stage shows
/// "Stopping..." until the worker returns. Nothing is saved before the end
/// of a run; the vocals of a stopped or failed run are kept, so the next
/// run starts from GigaAM.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/track.dart';
import 'audio_decode.dart' show DecodeError;
import 'fit_model.dart';
import 'hear_languages.dart';
import 'hear_words.dart';
import 'heard_lyrics.dart';
import 'lyrics_controller.dart';
import 'lyrics_fitter.dart' show FitAudioError;
import 'stt_worker.dart';

/// How far a run is.
sealed class HearStage {
  const HearStage();
}

/// A model bundle is being downloaded: [bytes] of [total]; [whisper] for
/// the Whisper bundle, fetched in the middle of a run.
class HearDownloading extends HearStage {
  const HearDownloading(
    this.bytes,
    this.total, {
    this.whisper = false,
    this.gpu = false,
    this.picked = false,
  });
  final int bytes;
  final int total;
  final bool whisper;

  /// Whisper is needed for a language the user picked (plan 10 I2j), not
  /// because GigaAM was unsure.
  final bool picked;

  /// The GPU files (plan 10 I2i).
  final bool gpu;
}

/// The song is being saved, [share] of it (0 while it starts).
class HearSaving extends HearStage {
  const HearSaving(this.share);
  final double share;
}

/// A stage of [HearWords] runs: [step] is 'start' (before the first),
/// 'separate', 'gigaam', 'whisper' or 'whisper-ru'; [share] of its main part is done (null while it
/// starts or between parts).
class HearRunning extends HearStage {
  const HearRunning(this.step, this.share, {this.gpu = false});
  final String step;
  final double? share;

  /// Whether the step runs on the GPU.
  final bool gpu;
}

/// Stop was pressed; the worker has not returned yet.
class HearStopping extends HearStage {
  const HearStopping();
}

/// What a run came to.
sealed class HearOutcome {
  const HearOutcome();
}

/// The heard version was saved: words, no singing, or no words made out.
class HearDone extends HearOutcome {
  const HearDone(this.heard);
  final HeardLyrics heard;
}

/// The user stopped the download or the run. Nothing was saved.
class HearStopped extends HearOutcome {
  const HearStopped({this.download = false});

  /// Whether it was a models' download that stopped.
  final bool download;
}

/// The run did not finish; [message] says why, [retry] whether trying
/// again may help.
class HearFailed extends HearOutcome {
  const HearFailed(this.message, {this.retry = true});
  final String message;
  final bool retry;
}

/// The run being made: for which upload and song, and how far.
class HearJob {
  HearJob(this.key, this.track, this.stage);
  final String key;
  final Track track;
  HearStage stage;
}

/// The bundles a run may need: the models, Whisper (only for a song GigaAM
/// is not sure of) and the GPU files (while the GPU is on, plan 10 I2i).
enum HearBundle { hearWords, whisper, gpu }

/// Starts [HearWords] for one recording; the app's version opens a fresh
/// worker and a scratch folder and drops both when the run ends.
/// [beforeWhisper] goes to [HearWords.beforeWhisper], [language] (the
/// song's picked language, null for Automatic) to [HearWords.start].
typedef HearStart = HearRun Function({
  required String ref,
  required String audioPath,
  required String vocalsPath,
  required int audioBytes,
  required Future<void> Function(HearRun run) beforeWhisper,
  required String? language,
});

/// Room a run needs on the data drive for a song of [seconds], besides the
/// models: the decoded mix, the stereo vocals and their resampled copy at
/// once (44.1 kHz stereo floats, 353 KB a second each, 16 kHz mono vocals
/// 64 KB), the song's MP3 when it is saved first, and a margin.
int hearWorkingBytes(int seconds) =>
    seconds * (3 * 352800 + 64000 + 40000) + 200 * 1000 * 1000;

class LyricsHearer extends ChangeNotifier {
  LyricsHearer({
    required this.lyrics,
    required this.bundleReady,
    required this.bundleMegabytes,
    required this.download,
    required this.audioOf,
    required this.start,
    required this.vocalsPathOf,
    required this.forgetHeard,
    this.freeBytes,
    this.bundleIntact,
    this.busyElsewhere,
    this.log,
    this.useGpu,
    this.languageOf,
    this.saveLanguage,
  });

  final LyricsController lyrics;

  /// The language picked for hearing a song (LibraryStore.hearLanguageOf,
  /// plan 10 I2j): 'ru' or a Whisper language code; null for Automatic.
  final String? Function(String ref)? languageOf;

  /// Keeps a song's pick (LibraryStore.saveHearLanguage); null: Automatic.
  final void Function(String ref, String? language)? saveLanguage;

  /// The language picked for the upload [key], null for Automatic.
  /// A code this build does not know (a newer build's) counts as
  /// Automatic.
  String? languageFor(String? key) {
    final code = key == null ? null : languageOf?.call(key);
    return code != null && hearLanguageNames.containsKey(code) ? code : null;
  }

  /// Whether runs use the GPU now (the user's switch, and no GPU failure
  /// since the app started): the GPU files are then downloaded with the
  /// models. Null: never.
  final bool Function()? useGpu;

  bool get _gpu => useGpu?.call() ?? false;

  /// Whether a run would hear on the GPU now (for the time it takes).
  bool get onGpu => _gpu;

  /// Whether a bundle is downloaded (model_bundle.bundleReady).
  final bool Function(HearBundle bundle) bundleReady;

  /// A bundle's size, for the question before the download.
  final int Function(HearBundle bundle) bundleMegabytes;

  /// Downloads what is missing of a bundle (resumable).
  final Future<void> Function(
    HearBundle bundle,
    void Function(int bytes, int total) onProgress,
    DownloadStop stop,
  )
  download;

  /// The path of [track]'s stored audio, saving it first when it is not
  /// stored (the fitter's own); throws [FitAudioError].
  final Future<String> Function(
    Track track,
    void Function(double share) onProgress,
  )
  audioOf;

  final HearStart start;

  /// Where the vocals of the upload [key] are kept between runs.
  final String Function(String key) vocalsPathOf;

  /// Forgets the heard version of an upload (LibraryStore
  /// .saveHeardLyrics(ref, null)); the lyrics place is told by the hearer.
  final void Function(String ref) forgetHeard;

  /// Free bytes on the data drive, null when unknown.
  final int? Function()? freeBytes;

  /// Reads a bundle whole after a model would not load or run; false when
  /// a file was damaged (and deleted, so the next run downloads it again).
  final Future<bool> Function(HearBundle bundle)? bundleIntact;

  /// Why another heavy job (a fit, a fit check) keeps hearing from
  /// starting now; null when none runs.
  final String? Function()? busyElsewhere;

  /// One line to perf.log: times and outcomes only, never words or keys.
  final void Function(String line)? log;

  /// [log], never throwing: a line perf.log cannot take must not change
  /// what a run came to (its words may be saved already; Codex review).
  void _log(String line) {
    try {
      log?.call(line);
    } on Object {
      // Lost line.
    }
  }

  HearJob? _job;
  DownloadStop? _stop;
  HearRun? _run;
  Completer<void>? _stopped;

  /// The run going on now, null when none.
  HearJob? get job => _job;

  /// Whether the first question is still to be asked: the hear-words
  /// bundle is not there.
  bool get mustAsk => !bundleReady(HearBundle.hearWords);

  /// What the question names: the bundle fetched now and the one fetched
  /// later, in MB.
  int get nowMegabytes =>
      bundleMegabytes(HearBundle.hearWords) +
      (_gpu && !bundleReady(HearBundle.gpu)
          ? bundleMegabytes(HearBundle.gpu)
          : 0);
  int get laterMegabytes =>
      bundleReady(HearBundle.whisper) ? 0 : bundleMegabytes(HearBundle.whisper);

  /// How far the run for the upload [key] is; null when it is not heard.
  HearStage? stageOf(String? key) {
    final job = _job;
    if (job == null || key == null || job.key != key) return null;
    return job.stage;
  }

  bool get _stopping => _stopped?.isCompleted ?? false;

  void _move(HearJob job, HearStage stage) {
    if (_stopping && stage is! HearStopping) return;
    final shows = hearStageText(job.stage) != hearStageText(stage);
    job.stage = stage;
    if (shows) notifyListeners();
  }

  /// Stops the run: the download at once, a run at its next check.
  void stop() {
    final job = _job;
    final stopped = _stopped;
    if (job == null || stopped == null || stopped.isCompleted) return;
    stopped.complete();
    _stop?.stop();
    _run?.cancel();
    job.stage = const HearStopping();
    notifyListeners();
  }

  /// Forgets the heard version of the upload [key]: the place shows what
  /// the sources have, or the button again. Not while it is being heard.
  void forget(String key) {
    if (stageOf(key) != null) return;
    forgetHeard(key);
    lyrics.heardChanged(key);
    _log('hear words forgotten');
  }

  /// [future], or [HearStopped] as soon as Stop is pressed: saving the
  /// song has no stop of its own, so it finishes by itself.
  Future<T> _untilStopped<T>(Future<T> future) {
    final stopped = _stopped!.future.then<T>(
      (_) => throw const WorkerCancelled(),
    );
    return Future.any([future, stopped]);
  }

  /// Keeps [language] as the shown song's pick (null: Automatic) and hears
  /// it in that language (plan 10 I2j). Nothing is kept when the song
  /// cannot be heard now: another run, or [forKey] no longer shown.
  Future<HearOutcome> hearShownAs(String? language, {String? forKey}) {
    if (language != null && !hearLanguageNames.containsKey(language)) {
      return Future.value(
        HearFailed('No language "$language" to hear in.', retry: false),
      );
    }
    final key = lyrics.shownKey;
    if (_job == null &&
        key != null &&
        (lyrics.track?.inLibrary ?? false) &&
        (forKey == null || forKey == key) &&
        busyElsewhere?.call() == null) {
      saveLanguage?.call(key, language);
      _log('hear words asked ${language ?? 'auto'}');
      notifyListeners();
    }
    return hearShown(forKey: forKey);
  }

  /// Hears the recording of the song the place shows. Returns at once with
  /// [HearFailed] when a run or another heavy job goes on already, or when
  /// [forKey] is given and the place shows another upload now (a question
  /// or a message answered after the song moved on).
  Future<HearOutcome> hearShown({String? forKey}) async {
    final track = lyrics.track;
    final key = lyrics.shownKey;
    if (_job != null) {
      return const HearFailed(
        'Another song is being heard; wait for it or stop it.',
        retry: false,
      );
    }
    final busy = busyElsewhere?.call();
    if (busy != null) return HearFailed(busy, retry: false);
    if (track == null || key == null) {
      return const HearFailed('No song to hear.', retry: false);
    }
    if (forKey != null && forKey != key) {
      return const HearFailed(
        'Another song plays now; hear it from its own Lyrics place.',
        retry: false,
      );
    }
    if (!track.inLibrary) {
      return const HearFailed(
        'Add the song to your library to hear its words: hearing needs the '
        'song saved.',
        retry: false,
      );
    }
    final job = _job = HearJob(key, track, const HearSaving(0));
    _stopped = Completer<void>();
    notifyListeners();
    final clock = Stopwatch()..start();
    var phase = 'download';
    try {
      if (!bundleReady(HearBundle.hearWords)) {
        await _download(job, HearBundle.hearWords);
      }
      if (_gpu && !bundleReady(HearBundle.gpu)) {
        // The GPU only makes hearing faster: when its files do not come,
        // this run hears on the CPU (a stop is still a stop).
        try {
          await _download(job, HearBundle.gpu);
        } on DownloadStopped {
          rethrow;
        } on Object catch (error) {
          if (_stopping) rethrow;
          _log('hear words GPU files failed ${error.runtimeType}, CPU');
        }
      }
      // Stop during the last file's hash: the bundle may have finished;
      // no song is saved for a stopped run (Codex review).
      if (_stopping) throw const DownloadStopped();
      phase = 'save';
      final free = freeBytes?.call();
      final needed = hearWorkingBytes(track.durationSec.ceil());
      if (free != null && free < needed) {
        String gb(int bytes) => (bytes / 1e9).toStringAsFixed(1);
        return HearFailed(
          'Not enough free space: hearing this song needs ${gb(needed)} GB '
          'free, the drive has ${gb(free)} GB.',
        );
      }
      _move(job, const HearSaving(0));
      final path = await _untilStopped(
        audioOf(track, (share) => _move(job, HearSaving(share))),
      );
      // Another version chosen meanwhile: the saved file is that version's
      // recording, not the one the click asked for.
      if (lyrics.routeKeyOf(track) != key) {
        return const HearFailed(
          "The song's version changed while it was saved; hear it again.",
        );
      }
      if (_stopping) throw const WorkerCancelled();
      phase = 'run';
      final audioBytes = File(path).lengthSync();
      final vocalsPath = vocalsPathOf(key);
      Directory(p.dirname(vocalsPath)).createSync(recursive: true);
      // Until the pipeline names its first step: kept vocals skip the
      // separation, so it is not named here (seen in hear-55a).
      _move(job, const HearRunning('start', null));
      final run = _run = start(
        ref: key,
        audioPath: path,
        vocalsPath: vocalsPath,
        audioBytes: audioBytes,
        language: languageFor(key),
        beforeWhisper: (_) async {
          if (!bundleReady(HearBundle.whisper)) {
            phase = 'download whisper';
            await _download(job, HearBundle.whisper);
            phase = 'run';
          }
        },
      );
      final listening = run.progress.listen((unit) {
        // Only the long parts have a share worth showing: the separator's
        // chunks and the models' speech chunks.
        final main = unit.stage == 'separate' || unit.stage == 'hear';
        _move(
          job,
          HearRunning(
            unit.step,
            main && unit.total > 0 ? unit.done / unit.total : null,
            gpu: unit.gpu,
          ),
        );
      });
      try {
        final heard = await run.result;
        _log(
          'hear words ${heard.outcome.name} ${clock.elapsedMilliseconds} ms',
        );
        return HearDone(heard);
      } finally {
        await listening.cancel();
      }
    } on DownloadStopped {
      _log('hear words download stopped');
      return const HearStopped(download: true);
    } on WorkerCancelled {
      _log('hear words stopped in $phase ${clock.elapsedMilliseconds} ms');
      return HearStopped(download: phase.startsWith('download'));
    } on Object catch (error) {
      if (_stopping) return HearStopped(download: phase.startsWith('download'));
      _log(
        'hear words failed in $phase ${error.runtimeType} '
        '${clock.elapsedMilliseconds} ms',
      );
      // A model that would not load or run may be damaged on disk: that
      // bundle is read whole and damaged files deleted. Other failures (a
      // song that cannot be read, a full drive) never cost the hashing.
      final bundle = error is WorkerJobError
          ? damagedBundleOf(error.message)
          : null;
      if (bundle != null &&
          bundleIntact != null &&
          !await bundleIntact!(bundle)) {
        _log('hear words ${bundle.name} damaged, deleted');
        return const HearFailed(
          'A model file was damaged and was deleted; the next try downloads '
          'it again.',
        );
      }
      return hearFailureOf(error);
    } finally {
      _stop = null;
      _run = null;
      _job = null;
      _stopped = null;
      notifyListeners();
    }
  }

  Future<void> _download(HearJob job, HearBundle bundle) async {
    final whisper = bundle == HearBundle.whisper;
    final gpu = bundle == HearBundle.gpu;
    if (_stopping) throw const DownloadStopped();
    final picked = whisper && languageFor(job.key) != null;
    _move(
      job,
      HearDownloading(0, 0, whisper: whisper, gpu: gpu, picked: picked),
    );
    final stop = _stop = DownloadStop();
    try {
      await download(bundle, (bytes, total) {
        _move(
          job,
          HearDownloading(
            bytes,
            total,
            whisper: whisper,
            gpu: gpu,
            picked: picked,
          ),
        );
      }, stop);
    } finally {
      _stop = null;
    }
    if (!bundleReady(bundle)) {
      throw const ModelDownloadError('The models did not download.');
    }
  }
}

/// The bundle a worker error points at, when it is a model that would not
/// load or run (ONNX Runtime, whisper.cpp, GigaAM's head); null otherwise.
HearBundle? damagedBundleOf(String message) {
  if (message.contains('WhisperError')) return HearBundle.whisper;
  if (message.contains('OnnxError') ||
      message.contains('NpzFormatError') ||
      message.contains('FormatException')) {
    return HearBundle.hearWords;
  }
  return null;
}

/// What a stage shows, so listeners hear only changes that show (the
/// download reports every few kilobytes).
String hearStageText(HearStage stage) => switch (stage) {
  HearDownloading(
    :final bytes,
    :final total,
    :final whisper,
    :final gpu,
    :final picked,
  ) =>
    'downloading ${whisper && picked
            ? 'Whisper (for the language you picked)'
            : whisper
            ? 'Whisper (GigaAM was not sure of this song)'
            : gpu
            ? 'the GPU files'
            : 'the models'}, '
        '${total == 0 ? 0 : bytes * 100 ~/ total}% of ${total ~/ 1000000} MB',
  HearSaving(:final share) => 'saving the song, ${(share * 100).floor()}%',
  HearRunning(:final step, :final share, :final gpu) =>
    '${hearStepText(step)}${gpu ? ' on the GPU' : ''}'
        '${share == null ? '' : ', ${(share * 100).floor()}%'}',
  HearStopping() => 'stopping after the part being heard (up to about 15 s)',
};

/// A stage of the run in words.
String hearStepText(String step) => switch (step) {
  'start' => 'getting ready',
  'separate' => 'separating the voice from the music',
  'gigaam' => 'hearing the words',
  'whisper' => 'hearing the words with Whisper (GigaAM was not sure)',
  'whisper-asked' =>
    'hearing the words with Whisper, in the language you picked',
  'whisper-ru' => 'hearing some parts again as Russian',
  _ => 'hearing the words',
};

/// A short reason to show for a run that failed.
HearFailed hearFailureOf(Object error) => switch (error) {
  ModelDownloadError(:final message, :final retry) => HearFailed(
    message,
    retry: retry,
  ),
  FitAudioError(:final message) => HearFailed(
    'Could not save the song: $message',
  ),
  DecodeError() => const HearFailed("Could not read the song's audio."),
  FileSystemException() => const HearFailed(
    'Could not write the vocals file. Check the free space and try again.',
  ),
  WorkerJobError(:final message) when message.contains('Decode') =>
    const HearFailed("Could not read the song's audio."),
  WorkerJobError() => const HearFailed(
    'The models could not run. Try again; if it fails again, a model file '
    'may be damaged.',
  ),
  _ => const HearFailed('Hearing failed. Try again.'),
};

/// Removes kept vocals (and their markers) older than [maxAge] from
/// [folder], except [keep] (a run's own): runs that were stopped and never
/// tried again. Returns how many files went.
int removeOldVocals(
  Directory folder, {
  required DateTime now,
  Duration maxAge = const Duration(days: 14),
  Set<String> keep = const {},
}) {
  if (!folder.existsSync()) return 0;
  // Compared as normalized paths: a listing joins with the platform's
  // separator, a caller may not.
  final kept = {for (final path in keep) p.normalize(path)};
  var removed = 0;
  for (final entry in folder.listSync(followLinks: false)) {
    if (entry is! File) continue;
    final path = p.normalize(entry.path);
    if (kept.contains(path) ||
        kept.contains(path.replaceFirst(RegExp(r'\.from$'), ''))) {
      continue;
    }
    try {
      if (now.difference(entry.lastModifiedSync()) <= maxAge) continue;
      entry.deleteSync();
      removed++;
    } on FileSystemException {
      // In use by a run, or gone already.
    }
  }
  return removed;
}

/// The CPU threads every model of a run uses: fixed once per PC, since the
/// words depend on the count (plan 10 I2c). Half the logical cores, at most
/// 8, at least 1.
int sttThreadsFor(int logicalCores) => (logicalCores ~/ 2).clamp(1, 8);
