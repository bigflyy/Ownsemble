/// Export a song as karaoke videos (plan 11 D1): the steps of one export
/// and how far they are, for the status bar.
///
/// The steps: the video maker is downloaded when missing (after the user
/// agreed, in the dialog); the song is saved when it only streams (the
/// step "Hear the words" uses); the version is checked again, since the
/// saved file must be the recording the lyrics were timed to; the song is
/// decoded to 44.1 kHz stereo floats and brought to one level; for each
/// chosen shape the background and the lines are written and ffmpeg makes
/// the video; each finished video is moved to Videos\Ownsemble whole.
///
/// One export at a time. Stop: a download or ffmpeg stops at once; saving
/// and decoding finish by themselves (seconds) and nothing after them runs.
/// Videos finished before the stop stay. The job folder goes in any case.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/track.dart';
import '../lyrics/audio_decode.dart' show DecodeError;
import '../lyrics/fit_model.dart' show DownloadStop, DownloadStopped;
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_fitter.dart' show FitAudioError;
import '../lyrics/stt_worker.dart' show WorkerJobError;
import 'karaoke_audio.dart';
import 'karaoke_files.dart';
import 'karaoke_render.dart';
import 'karaoke_script.dart';

/// With the song's voice, or with the voice taken out.
enum KaraokeVoice { withVoice, withoutVoice }

/// What to export: one song, its lines as the Lyrics page shows them, and
/// the chosen shapes and voices.
class KaraokeRequest {
  const KaraokeRequest({
    required this.track,
    required this.key,
    required this.lines,
    required this.shiftMs,
    required this.shapes,
    required this.voices,
    this.cover,
  });

  final Track track;

  /// The upload (route key) the lines were timed to.
  final String key;

  /// The lines with their word times where known.
  final List<LyricLine> lines;

  /// Moves every time (KaraokeLines.of): the user's offset for these
  /// lyrics minus the Lyrics page's lead.
  final int shiftMs;

  final List<KaraokeShape> shapes;
  final List<KaraokeVoice> voices;

  /// The cover file's bytes, any format; null for a plain background.
  final Uint8List? cover;

  int get videos => shapes.length * voices.length;
}

/// How far an export is.
sealed class KaraokeStage {
  const KaraokeStage();
}

/// The video maker, or with [separator] the voice remover's model, is
/// being downloaded: [bytes] of [total].
class KaraokeDownloading extends KaraokeStage {
  const KaraokeDownloading(this.bytes, this.total, {this.separator = false});
  final int bytes;
  final int total;
  final bool separator;
}

/// The song is being saved, [share] of it.
class KaraokeSaving extends KaraokeStage {
  const KaraokeSaving(this.share);
  final double share;
}

/// The song is being decoded.
class KaraokeDecoding extends KaraokeStage {
  const KaraokeDecoding();
}

/// The voice is being taken out, [share] of it (null while it starts).
class KaraokeSeparating extends KaraokeStage {
  const KaraokeSeparating(this.share);
  final double? share;
}

/// Video [index] (from 1) of [count] is being made, [share] of it.
class KaraokeRendering extends KaraokeStage {
  const KaraokeRendering(
    this.index,
    this.count,
    this.share, {
    required this.shape,
    required this.voice,
  });
  final int index;
  final int count;
  final double share;
  final KaraokeShape shape;
  final KaraokeVoice voice;
}

/// Stop was pressed; a step that cannot stop at once is finishing.
class KaraokeStopping extends KaraokeStage {
  const KaraokeStopping();
}

/// What an export came to.
sealed class KaraokeOutcome {
  const KaraokeOutcome();
}

/// Every video was made; [files] in the order made.
class KaraokeDone extends KaraokeOutcome {
  const KaraokeDone(this.files);
  final List<File> files;
}

/// The user stopped; [files] were finished before the stop and stay.
class KaraokeStoppedOutcome extends KaraokeOutcome {
  const KaraokeStoppedOutcome(this.files);
  final List<File> files;
}

/// The export did not finish; [message] says why, [files] were finished
/// before it failed and stay.
class KaraokeFailed extends KaraokeOutcome {
  const KaraokeFailed(this.message, {this.files = const [], this.retry = true});
  final String message;
  final List<File> files;
  final bool retry;
}

/// The export going on: which song, and how far.
class KaraokeJob {
  KaraokeJob(this.request, this.stage);
  final KaraokeRequest request;
  KaraokeStage stage;
}

/// Decodes the song at [audioPath] to 44.1 kHz stereo raw floats at
/// [outPath] (mpv on a background isolate in the app).
typedef KaraokeDecode = Future<void> Function(String audioPath, String outPath);

/// Writes the song at [audioPath] without its voice to [outPath] (44.1 kHz
/// stereo raw floats at the song's level: InstrumentalJob in the hear
/// helper in the app). [onProgress] hears the share done; after [stop] it
/// throws [KaraokeStopped] as soon as the helper has let go of the files.
typedef KaraokeSeparate = Future<void> Function(
  String audioPath,
  String outPath,
  void Function(double share) onProgress,
  KaraokeStop stop,
);

/// Room an export needs on the drive for a song of [seconds]: the decoded
/// audio (44.1 kHz stereo floats, 353 KB a second) twice (one voice being
/// made while the other waits), the videos (a few MB a minute), the song's
/// file when it is saved first, and a margin.
int karaokeWorkingBytes(int seconds) =>
    seconds * (2 * 352800 + 40000) + 200 * 1000 * 1000;

class KaraokeExporter extends ChangeNotifier {
  KaraokeExporter({
    required this.toolReady,
    required this.downloadTool,
    required this.ffmpegPath,
    required this.audioOf,
    required this.routeKeyOf,
    required this.decode,
    required this.background,
    required this.measure,
    required this.scratchRoot,
    required this.outputFolder,
    this.threads = 2,
    this.separatorReady,
    this.downloadSeparator,
    this.separate,
    this.startProcess,
    this.freeBytes,
    this.log,
  });

  /// Whether the video maker is downloaded.
  final bool Function() toolReady;

  /// Downloads the video maker (resumable).
  final Future<void> Function(
    void Function(int bytes, int total) onProgress,
    DownloadStop stop,
  )
  downloadTool;

  /// ffmpeg.exe in the downloaded bundle.
  final String Function() ffmpegPath;

  /// The path of [track]'s stored audio, saving it first when it only
  /// streams; throws [FitAudioError].
  final Future<String> Function(
    Track track,
    void Function(double share) onProgress,
  )
  audioOf;

  /// The upload the app would play for [track] now (its chosen version).
  final String? Function(Track track) routeKeyOf;

  final KaraokeDecode decode;

  /// The PNG background for a shape (karaokeBackground in the app).
  final Future<Uint8List> Function(Uint8List? cover, KaraokeShape shape)
  background;

  /// Text widths for breaking lines into rows (KaraokeMeasure in the app).
  final TextWidth measure;

  /// Where each export gets its job folder (removed after it).
  final Directory Function() scratchRoot;

  /// Where finished videos go (karaokeVideosFolder in the app).
  final Directory Function() outputFolder;

  /// ffmpeg's threads for decoding, filters and x264 each.
  final int threads;

  /// Whether the voice remover's model is downloaded; null: exports
  /// without the voice are not offered.
  final bool Function()? separatorReady;

  /// Downloads the voice remover's model (resumable).
  final Future<void> Function(
    void Function(int bytes, int total) onProgress,
    DownloadStop stop,
  )?
  downloadSeparator;

  final KaraokeSeparate? separate;

  /// Whether exports without the voice can be made.
  bool get canRemoveVoice =>
      separate != null && separatorReady != null && downloadSeparator != null;

  /// Starts ffmpeg; null for Process.start (tests give a fake).
  final StartProcess? startProcess;

  /// Free bytes on the drive of [scratchRoot], null when unknown.
  final int? Function()? freeBytes;

  /// One line to perf.log: steps, times and outcomes, never names.
  final void Function(String line)? log;

  void _log(String line) {
    try {
      log?.call(line);
    } on Object {
      // Lost line.
    }
  }

  KaraokeJob? _job;
  KaraokeStop? _stop;
  DownloadStop? _downloadStop;

  /// The export going on now, null when none.
  KaraokeJob? get job => _job;

  bool get _stopping => _stop?.stopped ?? false;

  void _move(KaraokeJob job, KaraokeStage stage) {
    if (_stopping && stage is! KaraokeStopping) return;
    final shows = karaokeStageText(job.stage) != karaokeStageText(stage);
    job.stage = stage;
    if (shows) notifyListeners();
  }

  /// Stops the export: a download or ffmpeg at once, saving or decoding
  /// when they finish.
  void stop() {
    final job = _job;
    final stop = _stop;
    if (job == null || stop == null || stop.stopped) return;
    stop.stop();
    _downloadStop?.stop();
    job.stage = const KaraokeStopping();
    notifyListeners();
  }

  /// [future], or [KaraokeStopped] as soon as Stop is pressed (saving and
  /// decoding go on by themselves and their result is dropped).
  Future<T> _untilStopped<T>(Future<T> future) {
    final stopped = _stop!.future.then<T>((_) => throw const KaraokeStopped());
    return Future.any([future, stopped]);
  }

  /// Makes the videos of [request]. Returns at once with [KaraokeFailed]
  /// when an export goes on already or there is nothing to make.
  Future<KaraokeOutcome> export(KaraokeRequest request) async {
    if (_job != null) {
      return const KaraokeFailed(
        'Another karaoke video is being made; wait for it or stop it.',
        retry: false,
      );
    }
    if (request.videos == 0) {
      return const KaraokeFailed('Choose a shape and a voice.', retry: false);
    }
    final withoutVoice = request.voices.contains(KaraokeVoice.withoutVoice);
    if (withoutVoice && !canRemoveVoice) {
      return const KaraokeFailed(
        'Karaoke without the voice cannot be made in this build.',
        retry: false,
      );
    }
    final lines = KaraokeLines.of(request.lines, shiftMs: request.shiftMs);
    if (lines.isEmpty) {
      return const KaraokeFailed(
        'These lyrics have no timed lines to show in a video.',
        retry: false,
      );
    }
    final track = request.track;
    if (!track.inLibrary) {
      return const KaraokeFailed(
        'Add the song to your library first: the export needs it saved.',
        retry: false,
      );
    }
    final job = _job = KaraokeJob(request, const KaraokeSaving(0));
    final stop = _stop = KaraokeStop();
    notifyListeners();
    final clock = Stopwatch()..start();
    final made = <File>[];
    Directory? folder;
    Future<void>? decoded;
    var phase = 'download';
    try {
      if (!toolReady()) {
        _move(job, const KaraokeDownloading(0, 0));
        final downloadStop = _downloadStop = DownloadStop();
        try {
          await downloadTool(
            (bytes, total) => _move(job, KaraokeDownloading(bytes, total)),
            downloadStop,
          );
        } finally {
          _downloadStop = null;
        }
        if (!toolReady()) {
          return const KaraokeFailed('The video maker did not download.');
        }
      }
      if (withoutVoice && !separatorReady!()) {
        if (stop.stopped) throw const KaraokeStopped();
        _move(job, const KaraokeDownloading(0, 0, separator: true));
        final downloadStop = _downloadStop = DownloadStop();
        try {
          await downloadSeparator!(
            (bytes, total) =>
                _move(job, KaraokeDownloading(bytes, total, separator: true)),
            downloadStop,
          );
        } finally {
          _downloadStop = null;
        }
        if (!separatorReady!()) {
          return const KaraokeFailed('The voice remover did not download.');
        }
      }
      if (stop.stopped) throw const KaraokeStopped();
      phase = 'save';
      final free = freeBytes?.call();
      final needed = karaokeWorkingBytes(track.durationSec.ceil());
      if (free != null && free < needed) {
        String gb(int bytes) => (bytes / 1e9).toStringAsFixed(1);
        return KaraokeFailed(
          'Not enough free space: this export needs ${gb(needed)} GB free, '
          'the drive has ${gb(free)} GB.',
        );
      }
      _move(job, const KaraokeSaving(0));
      final audioPath = await _untilStopped(
        audioOf(track, (share) => _move(job, KaraokeSaving(share))),
      );
      // Another version chosen meanwhile: the saved file is that version's
      // recording, not the one the lines were timed to.
      if (routeKeyOf(track) != request.key) {
        return const KaraokeFailed(
          "The song's version changed while it was saved; export it again.",
        );
      }
      if (stop.stopped) throw const KaraokeStopped();

      phase = 'decode';
      folder = Directory(
        p.join(scratchRoot().path, '${DateTime.now().microsecondsSinceEpoch}'),
      )..createSync(recursive: true);
      _move(job, const KaraokeDecoding());
      final mix = p.join(folder.path, 'mix.f32');
      // Kept: after a Stop the decode goes on writing into the job folder,
      // which can only be removed once it has finished (review finding).
      final decoding = decoded = decode(audioPath, mix);
      await _untilStopped(decoding);
      decoded = null;
      final mixFile = File(mix);
      final frames = mixFile.existsSync() ? mixFile.lengthSync() ~/ 8 : 0;
      if (frames == 0) {
        return const KaraokeFailed("Could not read the song's audio.");
      }
      // Off the UI isolate: a long song is hundreds of MB of floats.
      final (peak, gain) = await levelFloatFile(mix);
      final decodeMs = clock.elapsedMilliseconds;
      _log(
        'karaoke decoded ${frames ~/ renderSampleRate} s, peak '
        '${peak.toStringAsFixed(2)}, gain ${gain.toStringAsFixed(2)}, '
        '$decodeMs ms',
      );

      final inst = p.join(folder.path, 'inst.f32');
      if (withoutVoice) {
        phase = 'separate';
        if (stop.stopped) throw const KaraokeStopped();
        final separateClock = Stopwatch()..start();
        _move(job, const KaraokeSeparating(null));
        // Not cut short by a Stop: the helper must let go of the files in
        // the job folder before it is removed; it stops at its next chunk.
        await separate!(
          audioPath,
          inst,
          (share) => _move(job, KaraokeSeparating(share)),
          stop,
        );
        if (stop.stopped) throw const KaraokeStopped();
        final instFile = File(inst);
        if (!instFile.existsSync() || instFile.lengthSync() ~/ 8 == 0) {
          return const KaraokeFailed('Taking the voice out gave no sound.');
        }
        final (instPeak, instGain) = await levelFloatFile(inst);
        _log(
          'karaoke voice removed ${separateClock.elapsedMilliseconds} ms, '
          'peak ${instPeak.toStringAsFixed(2)}, '
          'gain ${instGain.toStringAsFixed(2)}',
        );
      }

      phase = 'render';
      final durationMs = frames * 1000 ~/ renderSampleRate;
      final scripts = <KaraokeShape, String>{};
      final backgrounds = <KaraokeShape, Uint8List>{};
      final count = request.videos;
      var index = 0;
      final audioFile = File(p.join(folder.path, renderAudioName));
      for (final voice in request.voices) {
        // The duration and the lines are the mix's; the instrumental has
        // the same length (the separator writes every frame of the mix).
        if (audioFile.existsSync()) audioFile.deleteSync();
        File(voice == KaraokeVoice.withVoice ? mix : inst)
            .renameSync(audioFile.path);
        for (final shape in request.shapes) {
          if (stop.stopped) throw const KaraokeStopped();
          index++;
          final videoIndex = index;
          _move(
            job,
            KaraokeRendering(videoIndex, count, 0, shape: shape, voice: voice),
          );
          final script = scripts[shape] ??= karaokeScript(
            lines: lines,
            shape: shape,
            title: track.title,
            artist: track.artist,
            durationMs: durationMs,
            measure: measure,
          );
          File(p.join(folder.path, renderScriptName))
              .writeAsStringSync(script, flush: true);
          final png = backgrounds[shape] ??= await background(
            request.cover,
            shape,
          );
          File(p.join(folder.path, renderBackgroundName))
              .writeAsBytesSync(png, flush: true);
          final renderClock = Stopwatch()..start();
          await renderKaraoke(
            ffmpegPath: ffmpegPath(),
            job: folder,
            samples: frames,
            threads: threads,
            stop: stop,
            start: startProcess ?? _processStart,
            onProgress: (share) => _move(
              job,
              KaraokeRendering(
                videoIndex,
                count,
                share,
                shape: shape,
                voice: voice,
              ),
            ),
          );
          final placed = moveIntoPlace(
            File(p.join(folder.path, renderOutName)),
            outputFolder(),
            karaokeFileName(
              artist: track.artist,
              title: track.title,
              withVoice: voice == KaraokeVoice.withVoice,
              shape: shape,
            ),
          );
          made.add(placed);
          _log(
            'karaoke video ${shape.name} ${voice.name} '
            '${renderClock.elapsedMilliseconds} ms',
          );
        }
      }
      _log(
        'karaoke done ${made.length} videos ${clock.elapsedMilliseconds} ms',
      );
      return KaraokeDone(List.unmodifiable(made));
    } on DownloadStopped {
      _log('karaoke download stopped');
      return KaraokeStoppedOutcome(List.unmodifiable(made));
    } on KaraokeStopped {
      _log('karaoke stopped in $phase ${clock.elapsedMilliseconds} ms');
      return KaraokeStoppedOutcome(List.unmodifiable(made));
    } on Object catch (error) {
      if (_stopping) return KaraokeStoppedOutcome(List.unmodifiable(made));
      _log(
        'karaoke failed in $phase ${error.runtimeType} '
        '${clock.elapsedMilliseconds} ms',
      );
      return karaokeFailureOf(error, List.unmodifiable(made));
    } finally {
      _job = null;
      _stop = null;
      _downloadStop = null;
      final scratch = folder;
      if (scratch != null) {
        final stillDecoding = decoded;
        if (stillDecoding == null) {
          _removeFolder(scratch);
        } else {
          // A decode left running by a Stop: its file is open in the
          // folder until it ends, so the folder goes then.
          unawaited(
            stillDecoding
                .then<void>((_) {}, onError: (Object _) {})
                .whenComplete(() => _removeFolder(scratch)),
          );
        }
      }
      notifyListeners();
    }
  }
}

/// Removes an export's job folder; one still held (a killed ffmpeg a
/// moment longer) is left for removeOldKaraokeJobs at the next start.
void _removeFolder(Directory folder) {
  try {
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  } on FileSystemException {
    // Left for the next start.
  }
}

/// Removes every job folder under [scratchRoot]: what exports of an
/// earlier start left (a window closed mid-export ends the process at
/// once). Call before any export can start.
void removeOldKaraokeJobs(Directory scratchRoot) {
  try {
    if (scratchRoot.existsSync()) scratchRoot.deleteSync(recursive: true);
  } on FileSystemException {
    // Still held by something; tried again next start.
  }
}

Future<Process> _processStart(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.start(executable, arguments, workingDirectory: workingDirectory);

/// A short reason to show for an export that failed.
KaraokeFailed karaokeFailureOf(Object error, List<File> files) =>
    switch (error) {
      KaraokeRenderError(:final message) => KaraokeFailed(
        message,
        files: files,
      ),
      DecodeError() => KaraokeFailed(
        "Could not read the song's audio.",
        files: files,
      ),
      WorkerJobError() => KaraokeFailed(
        'Taking the voice out failed. Try again; if it fails again, the '
        'voice remover file may be damaged.',
        files: files,
      ),
      FitAudioError(:final message) => KaraokeFailed(
        'Could not save the song: $message',
        files: files,
      ),
      FileSystemException() => KaraokeFailed(
        'Could not write the video. Check the free space and the Videos '
        'folder, and try again.',
        files: files,
      ),
      _ => KaraokeFailed('The export failed. Try again.', files: files),
    };

/// What a stage shows, so listeners hear only changes that show.
String karaokeStageText(KaraokeStage stage) => switch (stage) {
  KaraokeDownloading(:final bytes, :final total, :final separator) =>
    'downloading ${separator ? 'the voice remover' : 'the video maker'}, '
        '${total == 0 ? 0 : bytes * 100 ~/ total}% of '
        '${(total / 1e6).toStringAsFixed(1)} MB',
  KaraokeSaving(:final share) => 'saving the song, ${(share * 100).floor()}%',
  KaraokeDecoding() => 'reading the song',
  KaraokeSeparating(:final share) =>
    'taking the voice out${share == null ? '' : ', ${(share * 100).floor()}%'}',
  KaraokeRendering(:final index, :final count, :final share) =>
    'making the video${count > 1 ? ' $index of $count' : ''}, '
        '${(share * 100).floor()}%',
  KaraokeStopping() => 'stopping',
};
