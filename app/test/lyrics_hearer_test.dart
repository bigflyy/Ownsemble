// Unit tests for plan 10 I2f: "Hear the words" as the Lyrics place runs it
// (LyricsHearer) on a fake worker: the downloads (Whisper only when a song
// needs it), saving the song, the stages, Stop in each phase, the checks
// before a run, a song switch, damaged models, forgetting, and the old
// vocals cleanup. The words are made up.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/hear_words.dart';
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart' show FitAudioError;
import 'package:ownsemble/lyrics/lyrics_hearer.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:ownsemble/lyrics/whisper_job.dart';

import 'stt_fakes.dart';

const separated = VocalsResult(
  samples: 0,
  chunks: 1,
  decodeMs: 0,
  separateMs: 0,
  resampleMs: 0,
  scale: 1,
);

void main() {
  late Directory temp;
  late LibraryStore store;
  late List<Track> tracks;
  late Map<int, String> routeKeys;
  late LyricsController lyrics;
  late Set<HearBundle> ready;
  late List<HearBundle> downloads;
  late Completer<void>? downloadGate;
  late Completer<String>? saveGate;
  late List<String> audioAsked;
  late FakeRunner runner;
  late List<String> log;
  late List<HearBundle> checked;
  late bool intact;
  late int? free;
  late String? busy;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('lyrics_hearer_test');
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      for (var i = 0; i < 2; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Artist $i',
          title: 'Song $i',
          durationSec: 200,
          addedAt: i,
        ),
    ]);
    tracks = store.loadAll()
      ..sort((a, b) => a.sourceKey!.compareTo(b.sourceKey!));
    routeKeys = {for (final track in tracks) track.id: track.sourceKey!};
    for (final key in ['1_0', '1_1']) {
      store.saveLyrics('vk', key, null);
    }
    lyrics = LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadHeard: store.heardLyricsOf,
      routeOf: (track) =>
          (key: routeKeys[track.id]!, accessKey: null, call: null),
    );
    ready = {HearBundle.hearWords, HearBundle.whisper};
    downloads = [];
    downloadGate = null;
    saveGate = null;
    audioAsked = [];
    log = [];
    checked = [];
    intact = true;
    free = null;
    busy = null;
    // Russian, sure: GigaAM only.
    runner = FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard([(1, 20)], said(words(25, 'x'), 1, 0.95)),
        WhisperJob(:final ranges) => whisperHeard(ranges!, [
          (language: 'en', words: said(words(25, 'y'), 1, 0.95)),
        ]),
        _ => throw StateError('unexpected'),
      },
    );
  });
  tearDown(() {
    store.close();
    temp.deleteSync(recursive: true);
  });

  LyricsHearer hearer() => LyricsHearer(
    lyrics: lyrics,
    bundleReady: ready.contains,
    bundleMegabytes: (bundle) => bundle == HearBundle.hearWords ? 395 : 585,
    download: (bundle, onProgress, stop) async {
      downloads.add(bundle);
      onProgress(10, 100);
      final gate = downloadGate;
      if (gate != null) {
        await Future.any([gate.future, stop.future]);
        if (stop.stopped) throw const DownloadStopped();
      }
      onProgress(100, 100);
      ready.add(bundle);
    },
    audioOf: (track, onProgress) async {
      audioAsked.add(track.sourceKey!);
      onProgress(0.5);
      final path = '${temp.path}/${track.sourceKey}.mp3';
      // Saved once: a stored song keeps its file (and its time).
      if (!File(path).existsSync()) File(path).writeAsBytesSync([1, 2, 3]);
      final gate = saveGate;
      if (gate != null) return gate.future;
      return path;
    },
    start:
        ({
          required ref,
          required audioPath,
          required vocalsPath,
          required audioBytes,
          required beforeWhisper,
        }) =>
            HearWords(
              runner: runner,
              paths: const HearWordsPaths(
                separatorModel: 'kim.onnx',
                silero: '',
                gigaamFolder: '',
                mpv: '',
                tempDir: '',
                whisperBridge: '',
                whisperLibraries: '',
                whisperModel: '',
              ),
              save: (ref, heard) {
                store.saveHeardLyrics(ref, heard);
                lyrics.heardChanged(ref);
              },
              beforeWhisper: beforeWhisper,
            ).start(
              ref: ref,
              audioPath: audioPath,
              vocalsPath: vocalsPath,
              audioBytes: audioBytes,
            ),
    vocalsPathOf: (key) => '${temp.path}/vocals/$key.vocals16.f32',
    forgetHeard: (ref) => store.saveHeardLyrics(ref, null),
    freeBytes: () => free,
    bundleIntact: (bundle) async {
      checked.add(bundle);
      return intact;
    },
    busyElsewhere: () => busy,
    log: log.add,
  );

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue, reason: 'timed out');
  }

  test('a Russian song: saved, run, heard words shown, no Whisper', () async {
    lyrics.show(tracks[0]);
    expect(lyrics.state, isA<LyricsMissing>());
    final hear = hearer();
    final seen = <String>[];
    hear.addListener(() {
      final stage = hear.stageOf('1_0');
      if (stage != null) seen.add(hearStageText(stage));
    });
    final outcome = await hear.hearShown();
    expect(outcome, isA<HearDone>());
    expect((outcome as HearDone).heard.model, HeardModel.gigaam);
    expect(runner.names, ['separate', 'gigaam']);
    expect(audioAsked, ['1_0']);
    expect(downloads, isEmpty);
    expect(hear.job, isNull);
    expect((lyrics.state as LyricsShown).lyrics.source, heardSource);
    expect(store.heardLyricsOf('1_0'), isNotNull);
    expect(seen, contains('saving the song, 50%'));
    expect(seen, contains('separating the voice from the music'));
    // The vocals went after the save.
    expect(File('${temp.path}/vocals/1_0.vocals16.f32').existsSync(), isFalse);
  });

  test('first run: the base models only; Whisper when a song needs it', () {
    ready.clear();
    final hear = hearer();
    expect(hear.mustAsk, isTrue);
    expect(hear.nowMegabytes, 395);
    expect(hear.laterMegabytes, 585);
    ready.add(HearBundle.whisper);
    expect(hear.laterMegabytes, 0);
  });

  test('a song GigaAM doubts fetches Whisper in the middle', () async {
    ready.remove(HearBundle.whisper);
    runner = FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard([(1, 20)], said(words(25, 'x'), 1, 0.5)),
        WhisperJob(:final ranges) => whisperHeard(ranges!, [
          (language: 'en', words: said(words(25, 'y'), 1, 0.95)),
        ]),
        _ => throw StateError('unexpected'),
      },
    );
    lyrics.show(tracks[0]);
    final hear = hearer();
    final stages = <HearStage>[];
    hear.addListener(() {
      final stage = hear.stageOf('1_0');
      if (stage != null) stages.add(stage);
    });
    final outcome = await hear.hearShown();
    expect((outcome as HearDone).heard.model, HeardModel.whisper);
    expect(downloads, [HearBundle.whisper]);
    expect(runner.names, ['separate', 'gigaam', 'whisper']);
    expect(
      stages.whereType<HearDownloading>().every((stage) => stage.whisper),
      isTrue,
    );
    expect(
      hearStageText(stages.whereType<HearDownloading>().first),
      startsWith('downloading Whisper'),
    );
  });

  test('Stop during the Whisper download: stopped, vocals kept, the next '
      'run starts from GigaAM', () async {
    ready.remove(HearBundle.whisper);
    runner = FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard([(1, 20)], said(words(25, 'x'), 1, 0.5)),
        WhisperJob(:final ranges) => whisperHeard(ranges!, [
          (language: 'en', words: said(words(25, 'y'), 1, 0.95)),
        ]),
        _ => throw StateError('unexpected'),
      },
    );
    downloadGate = Completer<void>();
    lyrics.show(tracks[0]);
    final hear = hearer();
    final running = hear.hearShown();
    await until(() => hear.stageOf('1_0') is HearDownloading);
    hear.stop();
    expect(hear.stageOf('1_0'), isA<HearStopping>());
    final outcome = await running;
    expect(outcome, isA<HearStopped>());
    expect((outcome as HearStopped).download, isTrue);
    expect(store.heardLyricsOf('1_0'), isNull);
    expect(File('${temp.path}/vocals/1_0.vocals16.f32').existsSync(), isTrue);
    downloadGate = null;
    final names = runner.names.length;
    expect(await hear.hearShown(), isA<HearDone>());
    expect(runner.names.skip(names), ['gigaam', 'whisper']);
  });

  test('Stop during the first download', () async {
    ready.clear();
    downloadGate = Completer<void>();
    lyrics.show(tracks[0]);
    final hear = hearer();
    final running = hear.hearShown();
    await until(() => hear.stageOf('1_0') is HearDownloading);
    hear.stop();
    final outcome = await running;
    expect((outcome as HearStopped).download, isTrue);
    expect(audioAsked, isEmpty);
    expect(hear.job, isNull);
  });

  test('Stop while the song is saved returns at once; nothing runs', () async {
    saveGate = Completer<String>();
    lyrics.show(tracks[0]);
    final hear = hearer();
    final running = hear.hearShown();
    await until(() => audioAsked.isNotEmpty);
    hear.stop();
    final outcome = await running;
    expect(outcome, isA<HearStopped>());
    expect((outcome as HearStopped).download, isFalse);
    expect(hear.job, isNull);
    // The save ends later by itself; no stage starts.
    saveGate!.complete('${temp.path}/1_0.mp3');
    await Future<void>.delayed(Duration.zero);
    expect(runner.names, isEmpty);
  });

  test(
    'Stop during separation shows Stopping until the worker returns',
    () async {
      runner.hold = (job) => job is VocalsJob;
      lyrics.show(tracks[0]);
      final hear = hearer();
      final running = hear.hearShown();
      await until(() => runner.jobs.isNotEmpty);
      hear.stop();
      expect(hear.stageOf('1_0'), isA<HearStopping>());
      expect(runner.jobs.single.cancelled, isTrue);
      final outcome = await running;
      expect(outcome, isA<HearStopped>());
      expect(store.heardLyricsOf('1_0'), isNull);
      expect(lyrics.state, isA<LyricsMissing>());
      expect((lyrics.state as LyricsMissing).heard, isNull);
    },
  );

  test('another song shown meanwhile: the run goes on for its own', () async {
    runner.hold = (job) => job is GigaamJob;
    lyrics.show(tracks[0]);
    final hear = hearer();
    final running = hear.hearShown();
    await until(() => runner.jobs.length == 2);
    lyrics.show(tracks[1]);
    expect(hear.stageOf('1_1'), isNull);
    expect(hear.stageOf('1_0'), isA<HearRunning>());
    // A click on the other song while this one runs.
    final second = await hear.hearShown();
    expect(second, isA<HearFailed>());
    expect((second as HearFailed).retry, isFalse);
    final gigaam = runner.jobs.last;
    gigaam.finish(runner.answer(gigaam.job));
    expect(await running, isA<HearDone>());
    expect(store.heardLyricsOf('1_0'), isNotNull);
    expect(store.heardLyricsOf('1_1'), isNull);
    expect(lyrics.state, isA<LyricsMissing>());
  });

  test('a version chosen while the song was saved: not heard', () async {
    saveGate = Completer<String>();
    lyrics.show(tracks[0]);
    final hear = hearer();
    final running = hear.hearShown();
    await until(() => audioAsked.isNotEmpty);
    routeKeys[tracks[0].id] = '2_0';
    saveGate!.complete('${temp.path}/1_0.mp3');
    final outcome = await running;
    expect(outcome, isA<HearFailed>());
    expect(runner.names, isEmpty);
  });

  test(
    'checks before a run: library, other jobs, the song, free space',
    () async {
      final hear = hearer();
      expect(await hear.hearShown(), isA<HearFailed>()); // No song shown.
      lyrics.show(tracks[0]);
      expect(await hear.hearShown(forKey: '1_1'), isA<HearFailed>());
      busy = 'A fit to the recording is running.';
      final fit = await hear.hearShown() as HearFailed;
      expect(fit.message, busy);
      busy = null;
      free = 100 * 1000 * 1000;
      final space = await hear.hearShown() as HearFailed;
      expect(space.message, startsWith('Not enough free space'));
      expect(audioAsked, isEmpty);
      expect(runner.names, isEmpty);
      // A song not in the library cannot be saved.
      final outside = Track(
        id: -5,
        sourceId: tracks[0].sourceId,
        source: TrackSource.vk,
        artist: 'A',
        title: 'B',
        durationSec: 100,
        sourceKey: '3_3',
      );
      routeKeys[outside.id] = '3_3';
      free = null;
      lyrics.show(outside);
      final notOwned = await hear.hearShown() as HearFailed;
      expect(notOwned.message, startsWith('Add the song'));
    },
  );

  test('a model that would not load: only that bundle is checked', () async {
    runner = FakeRunner(
      (job) => switch (job) {
        VocalsJob() => throw const WorkerJobError('OnnxError: bad model'),
        _ => throw StateError('unexpected'),
      },
    );
    lyrics.show(tracks[0]);
    intact = false;
    final damaged = await hearer().hearShown() as HearFailed;
    expect(checked, [HearBundle.hearWords]);
    expect(damaged.message, contains('damaged'));
    // A song that cannot be read costs no hashing.
    checked.clear();
    runner = FakeRunner(
      (job) => throw const WorkerJobError('DecodeError: no audio'),
    );
    final unreadable = await hearer().hearShown() as HearFailed;
    expect(checked, isEmpty);
    expect(unreadable.message, contains("Could not read the song's audio"));
    expect(damagedBundleOf('WhisperError: open failed'), HearBundle.whisper);
    expect(damagedBundleOf('StateError: x'), isNull);
  });

  test('a song that cannot be saved says why', () async {
    lyrics.show(tracks[0]);
    final hear = LyricsHearer(
      lyrics: lyrics,
      bundleReady: (_) => true,
      bundleMegabytes: (_) => 1,
      download: (_, _, _) async {},
      audioOf: (_, _) async => throw const FitAudioError('VK refused'),
      start: ({
        required ref,
        required audioPath,
        required vocalsPath,
        required audioBytes,
        required beforeWhisper,
      }) => throw StateError('no run'),
      vocalsPathOf: (key) => key,
      forgetHeard: (_) {},
    );
    final failed = await hear.hearShown() as HearFailed;
    expect(failed.message, 'Could not save the song: VK refused');
    expect(failed.retry, isTrue);
  });

  test(
    'forget: the heard words go, the place shows the button again',
    () async {
      lyrics.show(tracks[0]);
      final hear = hearer();
      await hear.hearShown();
      expect(lyrics.state, isA<LyricsShown>());
      hear.forget('1_0');
      expect(store.heardLyricsOf('1_0'), isNull);
      expect(lyrics.state, isA<LyricsMissing>());
      expect(log, contains('hear words forgotten'));
    },
  );

  test('old kept vocals are removed, recent ones and a run own stay', () {
    final folder = Directory('${temp.path}/old')..createSync();
    final now = DateTime(2026, 11, 25);
    File old(String name, int days) => File('${folder.path}/$name')
      ..writeAsBytesSync([0])
      ..setLastModifiedSync(now.subtract(Duration(days: days)));
    old('a.vocals16.f32', 20);
    old('a.vocals16.f32.from', 20);
    old('b.vocals16.f32', 3);
    final kept = old('c.vocals16.f32', 30);
    old('c.vocals16.f32.from', 30);
    final removed = removeOldVocals(folder, now: now, keep: {kept.path});
    expect(removed, 2);
    expect(
      folder.listSync().map((entry) => entry.uri.pathSegments.last).toSet(),
      {'b.vocals16.f32', 'c.vocals16.f32', 'c.vocals16.f32.from'},
    );
    expect(removeOldVocals(Directory('${temp.path}/none'), now: now), 0);
  });

  test('threads and room', () {
    expect(sttThreadsFor(16), 8);
    expect(sttThreadsFor(8), 4);
    expect(sttThreadsFor(1), 1);
    // A 6 minute song needs more than the old fixed 300 MB (Codex review).
    expect(hearWorkingBytes(360), greaterThan(500 * 1000 * 1000));
  });
}
