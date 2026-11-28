// Plan 11 D1: the karaoke exporter's parts (ffmpeg runner, file names,
// audio level) and its steps, with a fake ffmpeg process and fake helpers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/karaoke/karaoke_audio.dart';
import 'package:ownsemble/karaoke/karaoke_exporter.dart';
import 'package:ownsemble/karaoke/karaoke_files.dart';
import 'package:ownsemble/karaoke/karaoke_render.dart';
import 'package:ownsemble/karaoke/karaoke_script.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart' show FitAudioError;
import 'package:path/path.dart' as p;

/// What the fake ffmpeg does when started.
enum FfmpegPlay { succeed, fail, hang, noOutput }

/// A fake ffmpeg: writes -progress blocks and out.mp4 into its working
/// folder, then exits; or fails, or runs until killed.
class FakeFfmpeg implements Process {
  FakeFfmpeg(this.play, this.folder, this.arguments) {
    scheduleMicrotask(_run);
  }

  final FfmpegPlay play;
  final String folder;
  final List<String> arguments;
  var kills = 0;

  /// The peak of audio.f32 when it started (the level ffmpeg was given).
  double? audioPeak;
  String? script;
  int? backgroundBytes;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();

  void _say(String line) => _stdout.add(utf8.encode('$line\n'));

  Future<void> _run() async {
    final audio = File(p.join(folder, renderAudioName));
    if (audio.existsSync()) audioPeak = floatFilePeak(audio);
    final ass = File(p.join(folder, renderScriptName));
    if (ass.existsSync()) script = ass.readAsStringSync();
    final bg = File(p.join(folder, renderBackgroundName));
    if (bg.existsSync()) backgroundBytes = bg.lengthSync();
    final out = File(p.join(folder, renderOutName));
    switch (play) {
      case FfmpegPlay.succeed:
        _say('frame=1');
        _say('out_time_us=N/A');
        _say('progress=continue');
        _say('out_time_us=500000');
        _say('out_time_ms=500000');
        _say('progress=continue');
        out.writeAsBytesSync([1, 2, 3, 4]);
        _say('out_time_us=1000000');
        _say('progress=end');
        _end(0);
      case FfmpegPlay.fail:
        out.writeAsBytesSync([1]); // a half file, to be removed
        _stderr.add(utf8.encode('Error opening input\nsomething broke\n'));
        _end(1);
      case FfmpegPlay.noOutput:
        _end(0);
      case FfmpegPlay.hang:
        out.writeAsBytesSync([1]);
        _say('out_time_us=100000');
        _say('progress=continue');
    }
  }

  void _end(int code) {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    _end(1);
    return true;
  }

  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 7;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
}

/// Starts fakes in the given plays, one per start, and keeps them.
class FfmpegStarter {
  FfmpegStarter(this.plays);
  final List<FfmpegPlay> plays;
  final started = <FakeFfmpeg>[];

  Future<Process> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final play = plays[started.length.clamp(0, plays.length - 1)];
    final fake = FakeFfmpeg(play, workingDirectory!, arguments);
    started.add(fake);
    return fake;
  }
}

/// Writes [frames] stereo frames peaking at [peak] as raw floats.
void writeTone(String path, int frames, {double peak = 0.5}) {
  final samples = Float32List(frames * 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = (i % 7 - 3) / 3 * peak;
  }
  File(path).writeAsBytesSync(Uint8List.sublistView(samples));
}

const _track = Track(
  id: 5,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Artist: One',
  title: 'Song?',
  durationSec: 3,
  sourceKey: '1_2',
);

const _lines = [
  LyricLine('first line here', startMs: 500),
  LyricLine('second line', startMs: 1500),
];

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('karaoke_export_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('render', () {
    test('arguments use fixed relative names and the sample count', () {
      final args = karaokeRenderArgs(samples: 44100 * 3 + 441, threads: 3);
      expect(args, containsAllInOrder(['-t', '3.010000']));
      expect(args, containsAllInOrder(['-threads', '3']));
      expect(args, containsAllInOrder(['-i', 'audio.f32']));
      expect(args, containsAllInOrder(['-i', 'bg.png']));
      expect(args, contains('[1:v]ass=karaoke.ass,format=yuv420p[v]'));
      expect(args, containsAllInOrder(['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args.last, 'out.mp4');
      expect(args, isNot(contains('-shortest')));
    });

    test('progress reads out_time_us, never goes back, ends at 1', () {
      final progress = RenderProgress(2000000);
      expect(progress.add('out_time_us=N/A'), isFalse);
      expect(progress.add('progress=continue'), isTrue);
      expect(progress.share, 0);
      progress.add('out_time_us=1000000');
      expect(progress.share, 0.5);
      progress.add('out_time_ms=400000');
      expect(progress.share, 0.5);
      progress.add('out_time_us=9000000');
      expect(progress.share, 1);
      expect(progress.add('progress=end'), isTrue);
      expect(progress.ended, isTrue);
      expect(progress.add('garbage'), isFalse);
    });

    test('a run reports progress and leaves out.mp4', () async {
      final starter = FfmpegStarter([FfmpegPlay.succeed]);
      final shares = <double>[];
      await renderKaraoke(
        ffmpegPath: 'ffmpeg.exe',
        job: temp,
        samples: 44100,
        start: starter.call,
        onProgress: shares.add,
      );
      expect(shares, [0, 0.5, 1, 1]);
      expect(File(p.join(temp.path, 'out.mp4')).existsSync(), isTrue);
    });

    test('a failed run throws with stderr and removes the half file', () async {
      final starter = FfmpegStarter([FfmpegPlay.fail]);
      await expectLater(
        renderKaraoke(
          ffmpegPath: 'ffmpeg.exe',
          job: temp,
          samples: 44100,
          start: starter.call,
        ),
        throwsA(
          isA<KaraokeRenderError>().having(
            (e) => e.detail,
            'detail',
            'Error opening input | something broke',
          ),
        ),
      );
      expect(File(p.join(temp.path, 'out.mp4')).existsSync(), isFalse);
    });

    test('a run with no video throws', () async {
      final starter = FfmpegStarter([FfmpegPlay.noOutput]);
      await expectLater(
        renderKaraoke(
          ffmpegPath: 'ffmpeg.exe',
          job: temp,
          samples: 44100,
          start: starter.call,
        ),
        throwsA(isA<KaraokeRenderError>()),
      );
    });

    test('stop kills ffmpeg and removes the half file', () async {
      final starter = FfmpegStarter([FfmpegPlay.hang]);
      final stop = KaraokeStop();
      final run = renderKaraoke(
        ffmpegPath: 'ffmpeg.exe',
        job: temp,
        samples: 44100,
        start: starter.call,
        stop: stop,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      stop.stop();
      await expectLater(run, throwsA(isA<KaraokeStopped>()));
      expect(starter.started.single.kills, 1);
      expect(File(p.join(temp.path, 'out.mp4')).existsSync(), isFalse);
    });

    test('an exe that cannot start is a render error', () async {
      await expectLater(
        renderKaraoke(
          ffmpegPath: 'x',
          job: temp,
          samples: 1,
          start: (exe, args, {workingDirectory}) =>
              throw const ProcessException('x', [], 'not found', 2),
        ),
        throwsA(isA<KaraokeRenderError>()),
      );
    });
  });

  group('file names', () {
    test('refused characters, spaces, dots and device names', () {
      expect(
        safeFileNamePart('AC/DC: Back <in> "Black"?*|'),
        'AC_DC_ Back _in_ _Black____',
      );
      expect(
        safeFileNamePart('  many   spaces\tand\nlines  '),
        'many spaces and lines',
      );
      expect(safeFileNamePart('ends with dots...  '), 'ends with dots');
      expect(safeFileNamePart('CON'), '_CON');
      expect(safeFileNamePart('lpt1.txt'), '_lpt1.txt');
      expect(safeFileNamePart('Concert'), 'Concert');
      // Windows cuts at the first dot and drops trailing spaces.
      expect(safeFileNamePart('con .x'), '_con .x');
      expect(safeFileNamePart('Nul.mp3'), '_Nul.mp3');
      expect(safeFileNamePart(r'CONIN$'), r'_CONIN$');
      expect(safeFileNamePart('com¹'), '_com¹');
      expect(safeFileNamePart('console'), 'console');
      // Cyrillic kept as it is (a round trip of the letters).
      const cyrillic = 'Песня Ёлка';
      expect(safeFileNamePart(cyrillic), cyrillic);
    });

    test('long names are cut at whole characters', () {
      // The cap counts UTF-16 units, as NTFS does: an emoji is two.
      final emoji = '\u{1F3B5}' * 10;
      expect(safeFileNamePart(emoji, max: 5), '\u{1F3B5}' * 2);
      expect(safeFileNamePart(emoji, max: 4), '\u{1F3B5}' * 2);
      expect(safeFileNamePart('a' * 400).length, 150);
      expect(
        safeFileNamePart('\u{1F3B5}' * 400).length,
        lessThanOrEqualTo(150),
      );
    });

    test('the variants are named in the brackets', () {
      String name(bool voice, KaraokeShape shape) => karaokeFileName(
        artist: 'Artist',
        title: 'Title',
        withVoice: voice,
        shape: shape,
      );
      expect(
        name(true, KaraokeShape.landscape),
        'Artist - Title (karaoke).mp4',
      );
      expect(
        name(false, KaraokeShape.landscape),
        'Artist - Title (karaoke, no voice).mp4',
      );
      expect(
        name(false, KaraokeShape.vertical),
        'Artist - Title (karaoke, no voice, vertical).mp4',
      );
      expect(
        karaokeFileName(
          artist: ' ',
          title: 'Only title',
          withVoice: true,
          shape: KaraokeShape.vertical,
        ),
        'Only title (karaoke, vertical).mp4',
      );
      expect(
        karaokeFileName(
          artist: '',
          title: '???',
          withVoice: true,
          shape: KaraokeShape.landscape,
        ),
        '___ (karaoke).mp4',
      );
      expect(
        karaokeFileName(
          artist: '',
          title: '...',
          withVoice: true,
          shape: KaraokeShape.landscape,
        ),
        'Song (karaoke).mp4',
      );
    });

    test('a taken name gets (2), then (3)', () {
      File(p.join(temp.path, 'A (karaoke).mp4')).writeAsStringSync('x');
      expect(
        p.basename(freeTarget(temp, 'A (karaoke).mp4').path),
        'A (karaoke) (2).mp4',
      );
      File(p.join(temp.path, 'A (karaoke) (2).mp4')).writeAsStringSync('x');
      expect(
        p.basename(freeTarget(temp, 'A (karaoke).mp4').path),
        'A (karaoke) (3).mp4',
      );
    });

    test('moving into place makes the folder and keeps the bytes', () {
      final source = File(p.join(temp.path, 'out.mp4'))
        ..writeAsBytesSync([9, 8, 7]);
      final folder = Directory(p.join(temp.path, 'Videos', 'Ownsemble'));
      final placed = moveIntoPlace(source, folder, 'S (karaoke).mp4');
      expect(placed.readAsBytesSync(), [9, 8, 7]);
      expect(source.existsSync(), isFalse);
      expect(p.basename(placed.path), 'S (karaoke).mp4');
    });

    test('the Videos folder ends in Ownsemble', () {
      expect(p.basename(karaokeVideosFolder().path), 'Ownsemble');
    });
  });

  group('audio level', () {
    test('a loud track is brought down to the limit, a quiet one kept', () {
      expect(karaokeGain(0.5), 1);
      expect(karaokeGain(karaokePeakLimit), 1);
      expect(karaokeGain(1.32), closeTo(karaokePeakLimit / 1.32, 1e-12));
    });

    test('gain is applied in place across pieces, NaN cleared', () {
      // More than one piece of 2^18 samples.
      final path = p.join(temp.path, 'a.f32');
      writeTone(path, 200000, peak: 1.3);
      final file = File(path);
      file.openSync(mode: FileMode.append)
        ..setPositionSync(4 * 5)
        ..writeFromSync(
          Uint8List.sublistView(
            Float32List.fromList([double.nan, double.infinity]),
          ),
        )
        ..closeSync();
      final length = file.lengthSync();
      expect(floatFilePeak(file), closeTo(1.3, 1e-6));
      final gain = karaokeGain(1.3);
      applyGain(file, gain);
      expect(file.lengthSync(), length);
      expect(floatFilePeak(file), closeTo(karaokePeakLimit, 1e-6));
      final samples = Float32List.sublistView(file.readAsBytesSync());
      expect(samples[5], 0);
      expect(samples[6], 0);
      expect(samples.last, closeTo(((399999 % 7) - 3) / 3 * 1.3 * gain, 1e-6));
    });
  });

  group('exporter', () {
    late Directory out;
    late Directory scratch;
    late FfmpegStarter starter;
    late List<String> calls;
    late String? routeKey;
    late bool toolThere;
    late bool separatorThere;

    KaraokeExporter exporter({
      List<FfmpegPlay> plays = const [FfmpegPlay.succeed],
      Future<String> Function()? audio,
      int? free,
      Future<void> Function(String, String)? decode,
      KaraokeSeparate? separate,
      bool withSeparator = false,
    }) {
      starter = FfmpegStarter(plays);
      return KaraokeExporter(
        toolReady: () => toolThere,
        downloadTool: (onProgress, stop) async {
          calls.add('download');
          onProgress(5, 10);
          onProgress(10, 10);
          toolThere = true;
        },
        ffmpegPath: () => 'ffmpeg.exe',
        audioOf: (track, onProgress) async {
          calls.add('audio');
          onProgress(0.5);
          return audio == null ? p.join(temp.path, 'song.mp3') : audio();
        },
        routeKeyOf: (track) => routeKey,
        decode:
            decode ??
            (audioPath, outPath) async {
              calls.add('decode');
              writeTone(outPath, 44100 * 2, peak: 1.2);
            },
        background: (cover, shape) async =>
            Uint8List.fromList(List.filled(shape.index + 3, 1)),
        measure: (text, size) => text.length * size * 0.5,
        scratchRoot: () => scratch,
        outputFolder: () => out,
        startProcess: starter.call,
        freeBytes: () => free,
        separatorReady: withSeparator ? () => separatorThere : null,
        downloadSeparator: withSeparator
            ? (onProgress, stop) async {
                calls.add('download separator');
                onProgress(1, 1);
                separatorThere = true;
              }
            : null,
        separate: withSeparator
            ? separate ??
                  (audioPath, outPath, onProgress, stop) async {
                    calls.add('separate');
                    onProgress(0.5);
                    writeTone(outPath, 44100 * 2, peak: 1.4);
                  }
            : null,
      );
    }

    KaraokeRequest request({
      List<KaraokeShape> shapes = const [KaraokeShape.landscape],
      List<KaraokeVoice> voices = const [KaraokeVoice.withVoice],
      List<LyricLine> lines = _lines,
    }) => KaraokeRequest(
      track: _track,
      key: '1_2',
      lines: lines,
      shiftMs: -120,
      shapes: shapes,
      voices: voices,
    );

    setUp(() {
      out = Directory(p.join(temp.path, 'Videos', 'Ownsemble'));
      scratch = Directory(p.join(temp.path, 'karaoke-tmp'));
      calls = [];
      routeKey = '1_2';
      toolThere = true;
      separatorThere = true;
    });

    test('makes both shapes, levelled, named, scratch removed', () async {
      final ex = exporter(plays: [FfmpegPlay.succeed, FfmpegPlay.succeed]);
      final stages = <String>[];
      ex.addListener(() {
        final job = ex.job;
        if (job != null) stages.add(karaokeStageText(job.stage));
      });
      final outcome = await ex.export(request(shapes: KaraokeShape.values));
      expect(outcome, isA<KaraokeDone>());
      final files = (outcome as KaraokeDone).files;
      expect(files.map((f) => p.basename(f.path)), [
        'Artist_ One - Song_ (karaoke).mp4',
        'Artist_ One - Song_ (karaoke, vertical).mp4',
      ]);
      for (final file in files) {
        expect(file.existsSync(), isTrue);
      }
      expect(calls, ['audio', 'decode']);
      expect(starter.started, hasLength(2));
      for (final fake in starter.started) {
        expect(fake.audioPeak, closeTo(karaokePeakLimit, 1e-5));
        expect(fake.arguments, containsAllInOrder(['-t', '2.000000']));
      }
      expect(starter.started[0].script, contains('PlayResX: 1920'));
      expect(starter.started[1].script, contains('PlayResX: 1080'));
      expect(starter.started[0].backgroundBytes, 3);
      expect(starter.started[1].backgroundBytes, 4);
      expect(scratch.listSync(), isEmpty);
      expect(ex.job, isNull);
      expect(
        stages,
        containsAllInOrder([
          'saving the song, 0%',
          'saving the song, 50%',
          'reading the song',
          'making the video 1 of 2, 0%',
          'making the video 1 of 2, 25%',
          'making the video 1 of 2, 100%',
          'making the video 2 of 2, 0%',
          'making the video 2 of 2, 100%',
        ]),
      );
    });

    test('downloads the video maker first when missing', () async {
      toolThere = false;
      final outcome = await exporter().export(request());
      expect(outcome, isA<KaraokeDone>());
      expect(calls.first, 'download');
    });

    test('an existing file is kept and the new one gets (2)', () async {
      out.createSync(recursive: true);
      File(p.join(out.path, 'Artist_ One - Song_ (karaoke).mp4'))
          .writeAsStringSync('old');
      final outcome = await exporter().export(request());
      final file = (outcome as KaraokeDone).files.single;
      expect(p.basename(file.path), 'Artist_ One - Song_ (karaoke) (2).mp4');
      expect(
        File(p.join(out.path, 'Artist_ One - Song_ (karaoke).mp4'))
            .readAsStringSync(),
        'old',
      );
    });

    test('a version changed while saving fails before decoding', () async {
      final ex = exporter(
        audio: () async {
          routeKey = '1_3';
          return 'x.mp3';
        },
      );
      final outcome = await ex.export(request());
      expect(outcome, isA<KaraokeFailed>());
      expect((outcome as KaraokeFailed).message, contains('version changed'));
      expect(calls, ['audio']);
    });

    test('a failed render keeps earlier videos and clears scratch', () async {
      final ex = exporter(plays: [FfmpegPlay.succeed, FfmpegPlay.fail]);
      final outcome = await ex.export(request(shapes: KaraokeShape.values));
      expect(outcome, isA<KaraokeFailed>());
      final failed = outcome as KaraokeFailed;
      expect(failed.message, contains('video maker failed'));
      expect(failed.files, hasLength(1));
      expect(failed.files.single.existsSync(), isTrue);
      expect(scratch.listSync(), isEmpty);
      expect(out.listSync(), hasLength(1));
    });

    test('stop during a render ends it and keeps nothing half', () async {
      final ex = exporter(plays: [FfmpegPlay.hang]);
      ex.addListener(() {
        // Once ffmpeg reports (a stop before it starts never starts it).
        final stage = ex.job?.stage;
        if (stage is KaraokeRendering && stage.share > 0) ex.stop();
      });
      final outcome = await ex.export(request());
      expect(outcome, isA<KaraokeStoppedOutcome>());
      expect((outcome as KaraokeStoppedOutcome).files, isEmpty);
      expect(starter.started.single.kills, 1);
      expect(out.existsSync() ? out.listSync() : const [], isEmpty);
      expect(scratch.listSync(), isEmpty);
    });

    test('stop while saving drops the rest', () async {
      final saving = Completer<String>();
      final ex = exporter(audio: () => saving.future);
      final running = ex.export(request());
      await Future<void>.delayed(Duration.zero);
      expect(ex.job?.stage, isA<KaraokeSaving>());
      ex.stop();
      expect(ex.job?.stage, isA<KaraokeStopping>());
      final outcome = await running;
      expect(outcome, isA<KaraokeStoppedOutcome>());
      saving.complete('late.mp3');
      expect(calls, ['audio']);
    });

    test('stop while decoding drops the rest', () async {
      final decoding = Completer<void>();
      final ex = exporter(
        decode: (audioPath, outPath) {
          calls.add('decode');
          return decoding.future;
        },
      );
      final running = ex.export(request());
      while (ex.job?.stage is! KaraokeDecoding) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      ex.stop();
      expect(await running, isA<KaraokeStoppedOutcome>());
      // The decode goes on writing into the job folder after the stop; the
      // folder goes once it ends (review finding).
      expect(scratch.listSync(), hasLength(1));
      File(p.join(scratch.listSync().single.path, 'mix.f32'))
          .writeAsBytesSync(List.filled(800, 0));
      decoding.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scratch.listSync(), isEmpty);
      expect(starter.started, isEmpty);
    });

    test('a song that will not save says so', () async {
      final ex = exporter(
        audio: () async => throw const FitAudioError('the network failed'),
      );
      final outcome = await ex.export(request());
      expect(
        (outcome as KaraokeFailed).message,
        'Could not save the song: the network failed',
      );
    });

    test('an empty decode is an unreadable song', () async {
      final ex = exporter(
        decode: (audioPath, outPath) async =>
            File(outPath).writeAsBytesSync([]),
      );
      final outcome = await ex.export(request());
      expect((outcome as KaraokeFailed).message, contains("song's audio"));
    });

    test('not enough room stops before saving', () async {
      final outcome = await exporter(free: 1000).export(request());
      expect((outcome as KaraokeFailed).message, contains('free space'));
      expect(calls, isEmpty);
    });

    test('both voices: four videos, each voice levelled on its own', () async {
      final ex = exporter(plays: [FfmpegPlay.succeed], withSeparator: true);
      final stages = <String>[];
      ex.addListener(() {
        final job = ex.job;
        if (job != null) stages.add(karaokeStageText(job.stage));
      });
      final outcome = await ex.export(
        request(shapes: KaraokeShape.values, voices: KaraokeVoice.values),
      );
      expect(outcome, isA<KaraokeDone>());
      expect((outcome as KaraokeDone).files.map((f) => p.basename(f.path)), [
        'Artist_ One - Song_ (karaoke).mp4',
        'Artist_ One - Song_ (karaoke, vertical).mp4',
        'Artist_ One - Song_ (karaoke, no voice).mp4',
        'Artist_ One - Song_ (karaoke, no voice, vertical).mp4',
      ]);
      expect(calls, ['audio', 'decode', 'separate']);
      expect(starter.started, hasLength(4));
      for (final fake in starter.started) {
        expect(fake.audioPeak, closeTo(karaokePeakLimit, 1e-5));
      }
      expect(stages, contains('taking the voice out'));
      expect(stages, contains('taking the voice out, 50%'));
      expect(stages, contains('making the video 4 of 4, 100%'));
      expect(scratch.listSync(), isEmpty);
    });

    test('the voice remover is downloaded first when missing', () async {
      separatorThere = false;
      final outcome = await exporter(withSeparator: true)
          .export(request(voices: const [KaraokeVoice.withoutVoice]));
      expect(outcome, isA<KaraokeDone>());
      expect(calls, ['download separator', 'audio', 'decode', 'separate']);
      expect(
        p.basename((outcome as KaraokeDone).files.single.path),
        'Artist_ One - Song_ (karaoke, no voice).mp4',
      );
    });

    test('stop while the voice is taken out waits for the helper', () async {
      final helper = Completer<void>();
      late KaraokeExporter ex;
      ex = exporter(
        withSeparator: true,
        separate: (audioPath, outPath, onProgress, stop) async {
          onProgress(0.2);
          await stop.future;
          // The helper ends its job at the next chunk.
          await helper.future;
          throw const KaraokeStopped();
        },
      );
      final running = ex.export(
        request(voices: const [KaraokeVoice.withoutVoice]),
      );
      while (ex.job?.stage is! KaraokeSeparating) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      ex.stop();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Still waiting for the helper; the job folder is still there.
      expect(ex.job, isNotNull);
      expect(scratch.listSync(), hasLength(1));
      helper.complete();
      expect(await running, isA<KaraokeStoppedOutcome>());
      expect(scratch.listSync(), isEmpty);
      expect(starter.started, isEmpty);
    });

    test('a separation with no sound fails', () async {
      final ex = exporter(
        withSeparator: true,
        separate: (audioPath, outPath, onProgress, stop) async =>
            File(outPath).writeAsBytesSync([]),
      );
      final outcome = await ex.export(
        request(voices: const [KaraokeVoice.withoutVoice]),
      );
      expect((outcome as KaraokeFailed).message, contains('gave no sound'));
    });

    test('nothing to show, nothing chosen, no voice remover', () async {
      final ex = exporter();
      expect(
        await ex.export(
          request(lines: const [LyricLine('plain words, no times')]),
        ),
        isA<KaraokeFailed>(),
      );
      expect(await ex.export(request(shapes: const [])), isA<KaraokeFailed>());
      expect(
        await ex.export(request(voices: const [KaraokeVoice.withoutVoice])),
        isA<KaraokeFailed>(),
      );
      expect(calls, isEmpty);
    });

    test('one export at a time', () async {
      final saving = Completer<String>();
      final ex = exporter(audio: () => saving.future);
      final first = ex.export(request());
      final second = await ex.export(request());
      expect((second as KaraokeFailed).message, contains('Another karaoke'));
      saving.complete(p.join(temp.path, 'song.mp3'));
      expect(await first, isA<KaraokeDone>());
    });

    test('a stopped download is a stop', () async {
      toolThere = false;
      final ex = KaraokeExporter(
        toolReady: () => false,
        downloadTool: (onProgress, stop) async {
          await stop.future;
          throw const DownloadStopped();
        },
        ffmpegPath: () => 'ffmpeg.exe',
        audioOf: (track, onProgress) async => 'x',
        routeKeyOf: (track) => '1_2',
        decode: (a, b) async {},
        background: (cover, shape) async => Uint8List(0),
        measure: (text, size) => 1,
        scratchRoot: () => scratch,
        outputFolder: () => out,
      );
      final running = ex.export(request());
      await Future<void>.delayed(Duration.zero);
      expect(ex.job?.stage, isA<KaraokeDownloading>());
      ex.stop();
      expect(await running, isA<KaraokeStoppedOutcome>());
    });
  });
}
