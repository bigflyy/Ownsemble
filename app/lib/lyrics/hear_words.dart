/// "Hear the words" from start to end (plan 10 I2e): the vocals, GigaAM,
/// Whisper when GigaAM is unsure, and the heard version saved.
///
/// Stages, each one worker job ([JobRunner]):
/// 1. The vocals (Kim Vocal 2), unless a whole vocals file from an earlier
///    run is there already (the file appears only whole: vocals_job.dart).
/// 2. GigaAM over Silero's chunks, and the vocals' loudness. A mean word
///    confidence of at least 0.80 says the song is Russian: GigaAM's words
///    are the song's.
/// 3. Otherwise Whisper over the same chunks, each chunk in the language
///    Whisper hears there. One language per song only for songs Whisper
///    hears as more than half Russian: their chunks in another language are
///    heard again as Russian, and that reading is taken. Why (session 54):
///    on the research's Kim Vocal 2 transcripts (experiments/f2-timing/
///    stt_flips.py) 18 of 39 Russian songs had chunks written in a script
///    their lyrics do not have (Whisper wrote English over Russian singing),
///    while the 14 songs in other languages had none: their few flips were
///    real changes of language in the lyrics, so forcing one language there
///    would only break mixed songs. On #13 forced through Whisper
///    (stt_force_ru.py against GigaAM's sure words) the 3 English chunks
///    were invented or transliterated text at confidence 0.81-0.93, the
///    Russian readings agreed with GigaAM as well or better (0.64 against
///    0.52; 0 and 0 where both failed) but were less confident: so the
///    confidence cannot choose, and the Russian reading is taken. Open for
///    I2h: a Russian song with a real English chorus.
/// 4. The words judged (heard_lyrics.dart judgeHeard) and saved under the
///    recording key taken when the run started, whatever the app shows by
///    then. Nothing is saved before the end, so a cancelled or failed run
///    leaves no partial result and no "No singing found". The vocals file is
///    removed after the save and kept otherwise, so a new run can start from
///    the second stage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gigaam.dart';
import 'gigaam_job.dart';
import 'heard_lyrics.dart';
import 'stt_worker.dart';
import 'vocals_job.dart';
import 'whisper.dart';
import 'whisper_job.dart';

/// Where the models and helpers of a run are.
class HearWordsPaths {
  const HearWordsPaths({
    required this.separatorModel,
    required this.silero,
    required this.gigaamFolder,
    required this.mpv,
    required this.tempDir,
    required this.whisperBridge,
    required this.whisperLibraries,
    required this.whisperModel,
    this.threads = 8,
    this.bundles = '',
  });

  /// Kim_Vocal_2.onnx, silero_vad_scan.onnx, the GigaAM folder.
  final String separatorModel;
  final String silero;
  final String gigaamFolder;

  /// libmpv-2.dll, and a folder for the decoded song while it is separated.
  final String mpv;
  final String tempDir;

  /// ownsemble_whisper.dll, the bundle's whisper.cpp folder, the ggml model.
  final String whisperBridge;
  final String whisperLibraries;
  final String whisperModel;

  /// CPU threads for every model: one fixed count, since the results
  /// depend on it (plan 10 I2c).
  final int threads;

  /// The bundles' "name-version" list, kept with the result.
  final String bundles;
}

/// Where a run is: [step] is 'separate', 'gigaam', 'whisper' or
/// 'whisper-ru' (Whisper again on chunks heard as another language), and
/// [stage], [done] of [total] the worker's units inside it.
typedef HearProgress = ({String step, String stage, int done, int total});

/// One run of "Hear the words" for one recording.
class HearRun {
  HearRun._(this.ref);

  /// The recording key the result is saved under, taken at the start.
  final String ref;

  final _result = Completer<HeardLyrics>();
  final _progress = StreamController<HearProgress>.broadcast(sync: true);
  RunningJob<Object?>? _job;
  var _cancelled = false;

  /// Set just before the save: from then on the run is done and a cancel
  /// is too late (Codex review: a listener of the save could cancel).
  var _committed = false;

  /// The heard version, once saved; throws [WorkerCancelled] after
  /// [cancel], or the stage's error.
  Future<HeardLyrics> get result => _result.future;

  Stream<HearProgress> get progress => _progress.stream;

  bool get cancelled => _cancelled;

  /// Stops the run: the job running stops at its next check (Whisper
  /// inside a chunk, up to one encoder pass late), and no later stage
  /// starts. Nothing is saved. Too late once the result is being saved.
  void cancel() {
    if (_result.isCompleted || _committed) return;
    _cancelled = true;
    _job?.cancel();
  }

  Future<R> _stage<R>(String step, JobRunner runner, WorkerJob<R> job) {
    if (_cancelled) throw const WorkerCancelled();
    final running = runner.run(job);
    _job = running;
    // The step shows from its start, before its first unit ends.
    _progress.add((step: step, stage: 'start', done: 0, total: 0));
    final listening = running.progress.listen(
      (unit) => _progress.add((
        step: step,
        stage: unit.stage,
        done: unit.done,
        total: unit.total,
      )),
    );
    return running.result.whenComplete(() {
      unawaited(listening.cancel());
      if (identical(_job, running)) _job = null;
    });
  }
}

/// Runs "Hear the words" stage by stage on [runner].
class HearWords {
  HearWords({
    required this.runner,
    required this.paths,
    required this.save,
    int Function()? now,
    this.log,
    this.russianAt = russianConfidence,
    this.beforeWhisper,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final JobRunner runner;
  final HearWordsPaths paths;

  /// GigaAM's mean confidence from which a song is Russian (0.80); checks
  /// set it above 1 to send a Russian song to Whisper.
  final double russianAt;

  /// Keeps the heard version of the recording [ref] (LibraryStore
  /// .saveHeardLyrics, and the lyrics place told).
  final void Function(String ref, HeardLyrics heard) save;

  /// One line to perf.log per run: the route, counts and times, never
  /// words or keys.
  final void Function(String line)? log;

  final int Function() _now;

  /// Runs before the first Whisper stage of a run, only for a song GigaAM
  /// is not sure of: the app downloads the Whisper bundle there, the first
  /// time one is needed (Codex review of I2f). Its error fails the run;
  /// the vocals stay for the next try.
  final Future<void> Function(HearRun run)? beforeWhisper;

  /// Hears [audioPath], the file of the recording [ref], into the heard
  /// version saved for [ref]. [vocalsPath] is where the vocals go between
  /// stages: when a whole file is there already, made from the same
  /// [audioPath] and [audioBytes] (its marker, [vocalsMarkerOf]), separation
  /// is skipped. One run at a time may use a [vocalsPath].
  HearRun start({
    required String ref,
    required String audioPath,
    required String vocalsPath,
    int? audioBytes,
  }) {
    final run = HearRun._(ref);
    unawaited(() async {
      // A turn later, so the caller listens before the first step starts.
      await Future<void>.value();
      try {
        final heard = await _hear(run, audioPath, vocalsPath, audioBytes);
        run._result.complete(heard);
      } on Object catch (error, stack) {
        run._result.completeError(
          run._cancelled ? const WorkerCancelled() : error,
          run._cancelled ? null : stack,
        );
      } finally {
        unawaited(run._progress.close());
      }
    }());
    return run;
  }

  Future<HeardLyrics> _hear(
    HearRun run,
    String audioPath,
    String vocalsPath,
    int? audioBytes,
  ) async {
    final clock = Stopwatch()..start();
    final marker = File(vocalsMarkerOf(vocalsPath));
    final from = vocalsMarkerText(
      audioPath: audioPath,
      audioBytes: audioBytes,
      separatorModel: paths.separatorModel,
    );
    final kept =
        File(vocalsPath).existsSync() &&
        marker.existsSync() &&
        marker.readAsStringSync() == from;
    if (!kept) {
      // Vocals of another file (VK swapped it, another version) are not
      // used; the marker goes first, so a separation that stops halfway
      // never leaves old vocals marked as these.
      if (marker.existsSync()) marker.deleteSync();
      // The old vocals go too: a vocals file found after this stage is
      // then always this run's (it appears only whole: vocals_job.dart).
      final old = File(vocalsPath);
      if (old.existsSync()) old.deleteSync();
      try {
        await run._stage(
          'separate',
          runner,
          VocalsJob(
            audioPath: audioPath,
            outPath: vocalsPath,
            modelPath: paths.separatorModel,
            mpvPath: paths.mpv,
            tempDir: paths.tempDir,
            threads: paths.threads,
          ),
        );
      } on WorkerCancelled {
        // Stopped after the separator wrote the whole file but before its
        // result came: the vocals are kept for the next run (Codex review).
        if (File(vocalsPath).existsSync()) {
          marker.writeAsStringSync(from, flush: true);
        }
        rethrow;
      }
      marker.writeAsStringSync(from, flush: true);
    }
    final separateMs = clock.elapsedMilliseconds;

    final gigaam = await run._stage(
      'gigaam',
      runner,
      GigaamJob(
        vocalsPath: vocalsPath,
        modelFolder: paths.gigaamFolder,
        sileroPath: paths.silero,
        threads: paths.threads,
      ),
    );
    final heardRu = gigaam.result;
    final songMs = (heardRu.samples / 16).round();
    final gigaamMs = clock.elapsedMilliseconds - separateMs;

    HeardModel? model;
    List<HeardWord> words;
    double confidence;
    String? language;
    var whisperChunks = 0;
    var reheard = 0;
    if (heardRu.chunks.isEmpty) {
      // No singing for the speech gate: Whisper would get the same nothing.
      words = const [];
      confidence = 0;
    } else if (heardRu.meanConfidence >= russianAt) {
      model = HeardModel.gigaam;
      words = heardRu.words;
      confidence = heardRu.meanConfidence;
      language = 'ru';
    } else {
      final ranges = [
        for (final chunk in heardRu.chunks)
          (chunk.range.start, chunk.range.end),
      ];
      if (beforeWhisper != null) {
        if (run._cancelled) throw const WorkerCancelled();
        await beforeWhisper!(run);
      }
      final first = await run._stage(
        'whisper',
        runner,
        _whisperJob(vocalsPath, ranges, heardRu.speechSeconds, null),
      );
      var heard = first.result;
      whisperChunks = heard.chunks.length;
      final again = chunksToHearAsRussian(heard);
      if (again.isNotEmpty) {
        final forced = await run._stage(
          'whisper-ru',
          runner,
          _whisperJob(
            vocalsPath,
            [
              for (final index in again)
                (
                  heard.chunks[index].range.start,
                  heard.chunks[index].range.end,
                ),
            ],
            heardRu.speechSeconds,
            'ru',
          ),
        );
        final merged = withChunksHeardAgain(heard, again, forced.result);
        reheard = merged.taken;
        heard = merged.result;
      }
      model = HeardModel.whisper;
      words = heard.words;
      confidence = heard.meanConfidence;
      language = songLanguage(heard);
    }
    if (run._cancelled) throw const WorkerCancelled();
    final heard = judgeHeard(
      model: model,
      words: words,
      confidence: confidence,
      russianConfidence: heardRu.meanConfidence,
      language: language,
      loud: gigaam.loudSeconds,
      songMs: songMs,
      heardAtMs: _now(),
      audioBytes: audioBytes,
      bundles: paths.bundles,
    );
    run._committed = true;
    save(run.ref, heard);
    // Saved: nothing after this may fail the run.
    for (final file in [File(vocalsPath), marker]) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // Left for the app's cleanup of the vocals folder.
      }
    }
    try {
      log?.call(
        'hear words: ${heard.outcome.name} by ${heard.model?.name ?? 'none'} '
        '${heard.language ?? '-'}, ${heard.wordCount} words, '
        '${heard.lines.length} lines, rough ${heard.rough}, GigaAM '
        '${heardRu.meanConfidence.toStringAsFixed(3)}, '
        'loud ${heard.loudSeconds.toStringAsFixed(1)} s, '
        'Whisper chunks $whisperChunks ($reheard heard again as ru); '
        '${kept ? 'vocals kept' : 'separate $separateMs ms'}, '
        'GigaAM $gigaamMs ms, '
        'total ${clock.elapsedMilliseconds} ms',
      );
    } on Object {
      // A log that cannot be written does not undo the saved result.
    }
    return heard;
  }

  WhisperJob _whisperJob(
    String vocalsPath,
    List<(int, int)> ranges,
    double speechSeconds,
    String? language,
  ) => WhisperJob(
    vocalsPath: vocalsPath,
    bridgePath: paths.whisperBridge,
    libraryFolder: paths.whisperLibraries,
    modelPath: paths.whisperModel,
    threads: paths.threads,
    ranges: ranges,
    speechSeconds: speechSeconds,
    language: language,
  );
}

/// The language Whisper heard in most of the song: the one whose chunks
/// hold the most samples (the earlier one on a tie); null without chunks.
String? songLanguage(WhisperResult heard) {
  final samples = <String, int>{};
  for (final chunk in heard.chunks) {
    samples[chunk.language] =
        (samples[chunk.language] ?? 0) + chunk.range.end - chunk.range.start;
  }
  String? best;
  for (final MapEntry(:key, :value) in samples.entries) {
    if (best == null || value > samples[best]!) best = key;
  }
  return best;
}

/// The vocals marker beside [vocalsPath]: the song file they were made
/// from, so vocals of another file are never reused.
String vocalsMarkerOf(String vocalsPath) => '$vocalsPath.from';

/// What the marker of vocals made from [audioPath] holds: the file, its
/// size and last change (a file replaced by another of the same size), and
/// the separator model (a new bundle version makes new vocals; Codex
/// review of I2f).
String vocalsMarkerText({
  required String audioPath,
  required int? audioBytes,
  required String separatorModel,
}) {
  int? modified;
  try {
    final file = File(audioPath);
    if (audioPath.isNotEmpty && file.existsSync()) {
      modified = file.lastModifiedSync().millisecondsSinceEpoch;
    }
  } on FileSystemException {
    modified = null;
  }
  return jsonEncode({
    'audio': audioPath,
    'bytes': audioBytes,
    'modified': modified,
    'separator': separatorModel,
  });
}

/// The chunks to hear again as Russian: those in another language, when
/// more than half the singing (by samples) is heard as Russian; a song
/// where Russian is only the largest part is taken as mixed (Codex
/// review). Indices into [heard]'s chunks.
List<int> chunksToHearAsRussian(WhisperResult heard) {
  var total = 0;
  var russian = 0;
  for (final chunk in heard.chunks) {
    final length = chunk.range.end - chunk.range.start;
    total += length;
    if (chunk.language == 'ru') russian += length;
  }
  if (russian * 2 <= total) return const [];
  return [
    for (final (index, chunk) in heard.chunks.indexed)
      if (chunk.language != 'ru') index,
  ];
}

/// [heard] with the chunks at [indices] replaced by [forced]'s (heard
/// again in one language, in the same order); [taken] counts them.
({WhisperResult result, int taken}) withChunksHeardAgain(
  WhisperResult heard,
  List<int> indices,
  WhisperResult forced,
) {
  if (forced.chunks.length != indices.length) {
    throw StateError(
      'heard ${forced.chunks.length} chunks again, asked ${indices.length}',
    );
  }
  final chunks = [...heard.chunks];
  var taken = 0;
  for (final (k, index) in indices.indexed) {
    final again = forced.chunks[k];
    if (again.range != chunks[index].range) {
      throw StateError('chunk $index heard again at another range');
    }
    chunks[index] = again;
    taken++;
  }
  return (
    result: WhisperResult(
      samples: heard.samples,
      speechSeconds: heard.speechSeconds,
      chunks: chunks,
    ),
    taken: taken,
  );
}
