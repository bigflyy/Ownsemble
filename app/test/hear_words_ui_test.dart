// Widget tests for plan 10 I2f: "Hear the words" on the Lyrics place and
// in the chooser, on a fake worker: the button and its note, the question
// before the first download, the progress panel and Stop, heard words with
// their credit and rough mark, "No singing found", another song being
// heard, a song outside the library, and the chooser's heard row with
// Forget. The words are made up.

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/gigaam_job.dart';
import 'package:ownsemble/lyrics/hear_words.dart';
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_hearer.dart';
import 'package:ownsemble/lyrics/vocals_job.dart';
import 'package:ownsemble/ui/lyrics_choices_page.dart';
import 'package:ownsemble/ui/lyrics_page.dart';
import 'package:ownsemble/ui/theme.dart';

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
  late LyricsController lyrics;
  late Set<HearBundle> ready;
  late FakeRunner runner;
  late double confidence;
  late Track? playing;
  late StreamController<Track?> songs;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('hear_words_ui_test');
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
    for (final key in ['1_0', '1_1', '3_3']) {
      store.saveLyrics('vk', key, null);
    }
    lyrics = LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadHeard: store.heardLyricsOf,
      routeOf: (track) => (key: track.sourceKey!, accessKey: null, call: null),
    );
    ready = {HearBundle.hearWords, HearBundle.whisper};
    confidence = 0.95;
    runner = FakeRunner(
      (job) => switch (job) {
        VocalsJob() => separated,
        GigaamJob() => gigaamHeard([
          (1, 20),
        ], said('come home. ${words(25, 'again')}', 1, confidence)),
        _ => throw StateError('unexpected'),
      },
    );
    playing = tracks[0];
    songs = StreamController<Track?>.broadcast();
  });
  tearDown(() async {
    await songs.close();
    store.close();
    temp.deleteSync(recursive: true);
  });

  LyricsHearer hearer() => LyricsHearer(
    lyrics: lyrics,
    bundleReady: ready.contains,
    bundleMegabytes: (bundle) => bundle == HearBundle.hearWords ? 395 : 585,
    download: (bundle, onProgress, stop) async => ready.add(bundle),
    audioOf: (track, onProgress) async {
      final path = '${temp.path}/${track.sourceKey}.mp3';
      if (!File(path).existsSync()) File(path).writeAsBytesSync([1, 2, 3]);
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
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openPlace(
    WidgetTester tester,
    LyricsHearer hear, {
    double width = 900,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.dark),
        home: Scaffold(
          body: LyricsPage(
            lyrics: lyrics,
            current: () => playing,
            currentStream: songs.stream,
            position: () => Duration.zero,
            positions: () => null,
            seek: (_) async {},
            onChoose: () {},
            hearer: hear,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('no lyrics: Hear the words, its note, and a run to the end', (
    tester,
  ) async {
    final hear = hearer();
    await openPlace(tester, hear);
    expect(text(tester, 'lyrics-message'), 'No lyrics found for this song.');
    expect(text(tester, 'lyrics-note'), contains('2 to 5 minutes'));
    expect(find.byKey(const ValueKey('lyrics-choose')), findsOneWidget);
    runner.hold = (job) => job is GigaamJob;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('hear-words')));
      for (var i = 0; i < 50 && runner.jobs.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await settle(tester);
    expect(find.byKey(const ValueKey('hear-progress')), findsOneWidget);
    expect(text(tester, 'hear-stage'), 'Hearing the words');
    expect(find.text('Stop'), findsOneWidget);
    await tester.runAsync(() async {
      final gigaam = runner.jobs.last;
      gigaam.finish(runner.answer(gigaam.job));
      for (var i = 0; i < 50 && hear.job != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await settle(tester);
    expect(
      text(tester, 'lyrics-credit'),
      'Heard by the app from this recording',
    );
    expect(find.text('come home.'), findsOneWidget);
  });

  testWidgets('Stop: Stopping... until the worker returns, then the button', (
    tester,
  ) async {
    final hear = hearer();
    await openPlace(tester, hear);
    // A job that ends only when the test says, even after its cancel.
    runner.hold = (job) => job is VocalsJob;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('hear-words')));
      for (var i = 0; i < 50 && runner.jobs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await settle(tester);
    expect(text(tester, 'hear-stage'), 'Separating the voice from the music');
    await tester.tap(find.byKey(const ValueKey('hear-stop')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hear-stop')),
        matching: find.text('Stopping...'),
      ),
      findsOneWidget,
    );
    expect(text(tester, 'hear-stage'), startsWith('Stopping after'));
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && hear.job != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await settle(tester);
    expect(text(tester, 'lyrics-message'), 'No lyrics found for this song.');
    expect(find.text('Stopped. Nothing was saved.'), findsOneWidget);
    expect(store.heardLyricsOf('1_0'), isNull);
  });

  testWidgets('the first run asks, naming both downloads; Cancel stops it', (
    tester,
  ) async {
    ready.clear();
    final hear = hearer();
    await openPlace(tester, hear);
    await tester.tap(find.byKey(const ValueKey('hear-words')));
    await settle(tester);
    expect(find.byKey(const ValueKey('hear-ask')), findsOneWidget);
    expect(find.textContaining('395 MB'), findsWidgets);
    expect(find.textContaining('585 MB more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hear-ask-cancel')));
    await settle(tester);
    expect(hear.job, isNull);
    expect(runner.jobs, isEmpty);
  });

  testWidgets('rough words say so', (tester) async {
    confidence = 0.88;
    final hear = hearer();
    lyrics.show(tracks[0]);
    await tester.runAsync(hear.hearShown);
    await openPlace(tester, hear);
    expect(
      text(tester, 'lyrics-credit'),
      'Heard by the app from this recording; rough: some words may be '
      'wrong',
    );
  });

  testWidgets('no singing found: said, and no Hear again', (tester) async {
    store.saveHeardLyrics(
      '1_0',
      judgeHeard(
        model: null,
        words: const [],
        confidence: 0,
        russianConfidence: 0,
        language: null,
        loud: 0,
        songMs: 200000,
        heardAtMs: 1,
      ),
    );
    await openPlace(tester, hearer());
    expect(text(tester, 'lyrics-message'), startsWith('No singing found'));
    expect(find.byKey(const ValueKey('hear-words')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-choose')), findsOneWidget);
  });

  testWidgets('a voice without words: Hear again', (tester) async {
    store.saveHeardLyrics(
      '1_0',
      judgeHeard(
        model: HeardModel.gigaam,
        words: const [],
        confidence: 0,
        russianConfidence: 0.2,
        language: null,
        loud: 50,
        songMs: 200000,
        heardAtMs: 1,
      ),
    );
    await openPlace(tester, hearer());
    expect(text(tester, 'lyrics-message'), contains('could not make out'));
    expect(find.text('Hear again'), findsOneWidget);
  });

  testWidgets('another song being heard: the button is off and says which', (
    tester,
  ) async {
    final hear = hearer();
    runner.hold = (job) => job is VocalsJob;
    lyrics.show(tracks[1]);
    late Future<HearOutcome> running;
    await tester.runAsync(() async {
      running = hear.hearShown();
      for (var i = 0; i < 50 && runner.jobs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await openPlace(tester, hear);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Hear the words'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(text(tester, 'lyrics-note'), contains('Song 1'));
    await tester.runAsync(() async {
      hear.stop();
      await running;
    });
  });

  testWidgets('a song outside the library cannot be heard', (tester) async {
    playing = Track(
      id: -5,
      sourceId: tracks[0].sourceId,
      source: TrackSource.vk,
      artist: 'A',
      title: 'B',
      durationSec: 100,
      sourceKey: '3_3',
    );
    await openPlace(tester, hearer());
    expect(text(tester, 'lyrics-note'), startsWith('Add the song'));
  });

  testWidgets('narrow: the message, buttons and note fit', (tester) async {
    await openPlace(tester, hearer(), width: 360);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('hear-words')), findsOneWidget);
  });

  testWidgets('the chooser lists the heard version; Forget removes it', (
    tester,
  ) async {
    confidence = 0.88;
    final hear = hearer();
    lyrics.show(tracks[0]);
    await tester.runAsync(hear.hearShown);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.dark),
        home: Scaffold(
          body: LyricsChoicesPage(
            lyrics: lyrics,
            current: () => playing,
            currentStream: songs.stream,
            position: () => Duration.zero,
            positions: () => null,
            seek: (_) async {},
            onUsed: () {},
            hearer: hear,
          ),
        ),
      ),
    );
    await settle(tester);
    final row = find.byKey(const ValueKey('lyrics-choice-heard'));
    expect(row, findsOneWidget);
    expect(find.text('Heard by the app'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-tag-rough')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-tag-in use')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-tag-similar names')),
      findsNothing,
    );
    await tester.tapAt(
      tester.getCenter(row),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('menu-hear-again')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-forget-heard')));
    await settle(tester);
    expect(store.heardLyricsOf('1_0'), isNull);
    expect(find.byKey(const ValueKey('lyrics-choice-heard')), findsNothing);
  });
}
