// Tests for plan 10 F1: timed lines moved by hand per song (a live or
// acoustic version is sung later or earlier than the lines say). The
// Lyrics heading has earlier / later in 0.5 s steps, the moved time shows
// in the heading and in the chooser's preview, and it is kept per upload
// and source. The words are made up.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/lyrics_page.dart';

/// A source that is never asked here: every answer is stored already.
class StoredOnlySource implements OutsideLyricsSource {
  StoredOnlySource(this.id);

  @override
  final String id;

  @override
  Future<LyricsCandidate?> find(SongNames song) async => null;
}

Lyrics timedOf(String source, String first) => Lyrics(
  source: source,
  lines: [
    LyricLine(first, startMs: 1000),
    const LyricLine('Вторая строка', startMs: 4000),
    const LyricLine('Third line', startMs: 8000),
  ],
);

/// Whether line [index] of the shown timed lyrics is the lit one.
bool lit(WidgetTester tester, int index) => tester
    .widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(ValueKey('lyrics-line-$index')),
            matching: find.byType(Semantics),
          )
          .first,
    )
    .properties
    .selected!;

void main() {
  late LibraryStore store;
  late LibraryController library;
  late Track playing;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Артист',
        title: 'Песня (live)',
        durationSec: 200,
        addedAt: 1,
      ),
    ]);
    library = LibraryController(store.loadAll());
    playing = library.all.single;
    store
      ..saveLyrics(
        'vk',
        '1_1',
        const Lyrics(source: 'vk', lines: [LyricLine('Слова без времени')]),
      )
      ..saveLyrics(
        'lrclib',
        '1_1',
        timedOf('lrclib', 'Первая строка LRCLIB'),
        meta: '{"id":"1","exact":true,"diff":0}',
      )
      ..saveLyrics(
        'netease',
        '1_1',
        timedOf('netease', 'First line NetEase'),
        meta: '{"id":"2","exact":false,"diff":2}',
      );
  });
  tearDown(() => store.close());

  LyricsController controllerOf({bool keep = true}) => LyricsController(
    load: store.lyricsOf,
    save: store.saveLyrics,
    loadPick: store.lyricsPickOf,
    savePick: store.saveLyricsPick,
    loadOffset: keep ? store.lyricsOffsetOf : null,
    saveOffset: keep ? store.saveLyricsOffset : null,
    routeOf: lyricsRouteBySource((sourceId) => null),
    sources: [
      StoredOnlySource('lrclib'),
      StoredOnlySource('netease'),
      StoredOnlySource('qq'),
    ],
    now: () => 1000,
  );

  Future<LyricsController> pumpScreen(
    WidgetTester tester,
    Size size, {
    Duration at = const Duration(milliseconds: 4200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lyrics = controllerOf();
    final player = PlayerService(muted: true, dataDir: '.')
      ..restore(playing, at);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          key: ValueKey(size),
          library: library,
          playback: PlaybackController(player: player),
          lyrics: lyrics,
        ),
      ),
    );
    await tester.pump();
    return lyrics;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  String offsetLabel(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-offset')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  testWidgets('earlier and later move the lit line, show in the heading and '
      'the preview, are kept per source, and the label resets them (wide, '
      '640 and 480 px)', (tester) async {
    for (final size in const [
      Size(1400, 900),
      Size(640, 700),
      Size(480, 700),
    ]) {
      store
        ..saveLyricsOffset('1_1', 'lrclib', 0)
        ..saveLyricsPick('1_1', null);
      await pumpScreen(tester, size);
      // At 480 px the bar's Lyrics button is in More (B26).
      library.toggleLyrics();
      await settle(tester);
      expect(offsetLabel(tester), 'Timing', reason: '$size');
      expect(lit(tester, 1), isTrue, reason: '4.2 s is in the second line');

      // Three times later: lines 1.5 s later, so 4.2 s is still the first.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('lyrics-later')));
        await settle(tester);
      }
      expect(offsetLabel(tester), '+1.5 s');
      expect(lit(tester, 0), isTrue, reason: '$size');
      expect(lit(tester, 1), isFalse);
      expect(
        find.text('Песня (live) - Артист · from LRCLIB, lines 1.5 s later'),
        findsOneWidget,
        reason: '$size',
      );
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 1500);
      await tester.tap(find.byKey(const ValueKey('lyrics-earlier')));
      await settle(tester);
      expect(offsetLabel(tester), '+1.0 s');
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 1000);

      // The chooser's preview uses the moved time; NetEase has its own.
      await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('lyrics-choice-lrclib')));
      await settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyrics-preview-what')))
            .data,
        'LRCLIB, timed · same length · lines 1.0 s later',
      );
      expect(lit(tester, 0), isTrue, reason: '4.2 - 1.0 s is in line 1');
      expect(lit(tester, 1), isFalse);
      await tester.tap(find.byKey(const ValueKey('lyrics-preview-back')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('lyrics-choice-netease')));
      await settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyrics-preview-what')))
            .data,
        isNot(contains('later')),
      );
      expect(lit(tester, 1), isTrue, reason: "NetEase's own timing");
      await tester.tap(find.byKey(const ValueKey('lyrics-use')));
      await settle(tester);
      expect(offsetLabel(tester), 'Timing', reason: "NetEase's own timing");
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 1000, reason: 'kept');

      // Back to LRCLIB: its offset is there again; a click on the label
      // goes back to the source's timing.
      store.saveLyricsPick('1_1', 'lrclib');
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpScreen(tester, size);
      await settle(tester);
      expect(library.view.kind, ViewKind.lyrics, reason: 'still open');
      expect(offsetLabel(tester), '+1.0 s', reason: 'kept in a new run');
      await tester.tap(find.byKey(const ValueKey('lyrics-offset')));
      await settle(tester);
      expect(offsetLabel(tester), 'Timing');
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), 0);
      expect(tester.takeException(), isNull, reason: '$size');
      // Closes Lyrics for the next size.
      library.toggleLyrics();
      await settle(tester);
    }
  });

  testWidgets('words without times get no timing control', (tester) async {
    store.saveLyricsPick('1_1', 'vk');
    await pumpScreen(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics')));
    await settle(tester);
    expect(find.text('Слова без времени'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-later')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-offset')), findsNothing);
  });

  testWidgets('a click on a moved line jumps to its moved time', (
    tester,
  ) async {
    final seeks = <Duration>[];
    Future<void> pumpLines(int offsetMs) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsLines(
            lyrics: timedOf('lrclib', 'Первая'),
            header: const SizedBox.shrink(),
            offsetMs: offsetMs,
            position: () => const Duration(milliseconds: 4200),
            positions: () => const Stream<Duration>.empty(),
            seek: (to) async => seeks.add(to),
          ),
        ),
      ),
    );
    await pumpLines(500);
    await tester.tap(find.byKey(const ValueKey('lyrics-line-2')));
    await tester.pump();
    expect(seeks.last, const Duration(milliseconds: 8500));
    // Earlier than the song's start: the jump stops at 0.
    await pumpLines(-1500);
    await tester.pump();
    expect(lit(tester, 1), isTrue, reason: '4.2 + 1.5 s is still line 2');
    await tester.tap(find.byKey(const ValueKey('lyrics-line-0')));
    await tester.pump();
    expect(seeks.last, Duration.zero);
    await tester.pump(const Duration(seconds: 1));
  });

  test('offsets keep to 0.5 s steps and 60 s, per source, also unkept', () {
    for (final keep in [true, false]) {
      store
        ..saveLyricsOffset('1_1', 'lrclib', 0)
        ..saveLyricsOffset('1_1', 'netease', 0);
      final lyrics = controllerOf(keep: keep)..show(playing);
      expect(lyrics.shownSource, 'lrclib');
      lyrics.setOffset('lrclib', 1234);
      expect(lyrics.shownOffset, 1000);
      lyrics.setOffset('lrclib', 70000);
      expect(lyrics.shownOffset, lyricsOffsetLimitMs);
      lyrics.shiftShown(lyricsOffsetStepMs);
      expect(lyrics.shownOffset, lyricsOffsetLimitMs, reason: 'no further');
      lyrics.setOffset('lrclib', -2600);
      expect(lyrics.shownOffset, -2500);
      expect(lyrics.offsetOf('netease'), 0, reason: 'its own timing');
      expect(store.lyricsOffsetOf('1_1', 'lrclib'), keep ? -2500 : 0);

      // Plain words are not moved.
      lyrics.use('vk');
      lyrics.shiftShown(lyricsOffsetStepMs);
      expect(lyrics.offsetOf('vk'), 0);
      lyrics.useAutomatic();
      expect(lyrics.shownOffset, -2500, reason: 'LRCLIB shows again: $keep');
    }
  });

  test('every change tells the listeners once; the same value none', () {
    final lyrics = controllerOf()..show(playing);
    var told = 0;
    lyrics.addListener(() => told++);
    lyrics.shiftShown(lyricsOffsetStepMs);
    lyrics.setOffset('lrclib', 500);
    expect(told, 1);
  });
}
