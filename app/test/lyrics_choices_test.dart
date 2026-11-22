// Widget tests for plan 10 E2: the lyrics chooser (user pick 2026-11-22
// "List like Versions"). The Lyrics place's "Choose lyrics" opens a list of
// every source's lyrics, a click previews one, "Use these lyrics" keeps it
// and returns to Lyrics, right-click "Back to automatic" forgets it. The
// words are made up.

import 'package:flutter/gestures.dart';
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
import 'package:ownsemble/ui/lyrics_choices_page.dart';

/// A source that must not be asked: every answer here is stored already.
class StoredOnlySource implements OutsideLyricsSource {
  StoredOnlySource(this.id);

  @override
  final String id;
  int asked = 0;

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    asked++;
    return null;
  }
}

Lyrics timedOf(String source, String first) => Lyrics(
  source: source,
  lines: [
    LyricLine(first, startMs: 1000),
    const LyricLine('Вторая строка', startMs: 4000),
    const LyricLine('', startMs: 6000),
    const LyricLine('Third line', startMs: 8000),
  ],
);

void main() {
  late LibraryStore store;
  late LibraryController library;
  late Track playing;
  late List<StoredOnlySource> sources;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      for (var i = 0; i < 5; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Артист $i',
          title: 'Песня $i',
          durationSec: 200,
          addedAt: i,
        ),
    ]);
    library = LibraryController(store.loadAll());
    playing = library.all.firstWhere((track) => track.sourceKey == '1_4');
    final key = playing.sourceKey!;
    // Stored answers: VK words only, LRCLIB and NetEase timed (NetEase by
    // rough names, 2 s off). QQ was never asked: the chooser asks it.
    store
      ..saveLyrics(
        'vk',
        key,
        const Lyrics(
          source: 'vk',
          lines: [LyricLine('Слова без времени'), LyricLine('ещё')],
        ),
      )
      ..saveLyrics(
        'lrclib',
        key,
        timedOf('lrclib', 'Первая строка LRCLIB'),
        meta:
            '{"id":"1","artist":"Артист 4","title":"Песня 4","seconds":200,'
            '"exact":true,"diff":0}',
      )
      ..saveLyrics(
        'netease',
        key,
        timedOf('netease', 'First line NetEase'),
        meta:
            '{"id":"2","artist":"Artist 4","title":"Pesnya 4","seconds":202,'
            '"exact":false,"diff":2}',
      );
    sources = [
      StoredOnlySource('lrclib'),
      StoredOnlySource('netease'),
      StoredOnlySource('qq'),
    ];
  });
  tearDown(() => store.close());

  Future<LyricsController> pumpScreen(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lyrics = LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      routeOf: lyricsRouteBySource((sourceId) => null),
      sources: sources,
    );
    final player = PlayerService(muted: true, dataDir: '.')
      ..restore(playing, Duration.zero);
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

  String credit(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('lyrics-credit'))).data!;

  Finder rowOf(String source) => find.byKey(ValueKey('lyrics-choice-$source'));

  Finder tagIn(String source, String tag) => find.descendant(
    of: rowOf(source),
    matching: find.byKey(ValueKey('lyrics-tag-$tag')),
  );

  testWidgets('Choose lyrics lists every source, a preview and Use keep the '
      'choice, Back to automatic forgets it (wide and narrow)', (tester) async {
    for (final size in const [Size(1400, 900), Size(640, 700)]) {
      store.saveLyricsPick(playing.sourceKey!, null);
      await pumpScreen(tester, size);
      await tester.tap(find.byKey(const ValueKey('lyrics')));
      await settle(tester);
      expect(credit(tester), 'From LRCLIB', reason: '$size');

      await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
      await settle(tester);
      expect(library.view.kind, ViewKind.lyricsChoices);
      expect(find.byType(LyricsChoicesPage), findsOneWidget);
      expect(find.text('Choose lyrics'), findsOneWidget);
      expect(find.textContaining('Песня 4 - Артист 4.'), findsOneWidget);
      expect(find.text('3 found'), findsOneWidget);
      expect(
        find.textContaining("Shows LRCLIB's timed lyrics (automatic pick)"),
        findsOneWidget,
      );
      // Best first: the two timed, then VK's words, then QQ without any.
      final tops = [
        for (final source in const ['lrclib', 'netease', 'vk', 'qq'])
          tester.getTopLeft(rowOf(source)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()), reason: '$size');
      expect(tagIn('lrclib', 'in use'), findsOneWidget);
      expect(tagIn('lrclib', 'automatic pick'), findsOneWidget);
      expect(tagIn('lrclib', 'timed'), findsOneWidget);
      expect(tagIn('netease', 'similar names'), findsOneWidget);
      expect(tagIn('vk', 'words only'), findsOneWidget);
      expect(
        find.descendant(
          of: rowOf('netease'),
          matching: find.text('Pesnya 4 - Artist 4 · 2 s off · 3 lines'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowOf('qq'),
          matching: find.text('No lyrics for this song'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('First line NetEase / Вторая строка'),
        findsOneWidget,
        reason: 'the first two lines with words',
      );
      expect(sources[0].asked + sources[1].asked, 0, reason: 'stored');

      // A click previews NetEase's lyrics; Use keeps them and returns.
      await tester.tap(rowOf('netease'));
      await settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyrics-preview-what')))
            .data,
        'NetEase, timed · 2 s off',
      );
      expect(find.text('First line NetEase'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-use')));
      await settle(tester);
      expect(library.view.kind, ViewKind.lyrics);
      expect(credit(tester), 'From NetEase (your choice)');
      expect(
        find.text('Песня 4 - Артист 4 · from NetEase, your choice'),
        findsOneWidget,
        reason: 'the heading says it too: the credit scrolls away',
      );
      expect(store.lyricsPickOf(playing.sourceKey!), 'netease');

      // Back in the chooser: the choice is tagged; right-click LRCLIB, Back
      // to automatic.
      await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
      await settle(tester);
      expect(tagIn('netease', 'your choice'), findsOneWidget);
      expect(tagIn('netease', 'in use'), findsOneWidget);
      expect(tagIn('lrclib', 'in use'), findsNothing);
      await tester.tap(rowOf('lrclib'), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('menu-lyrics-automatic')));
      await settle(tester);
      expect(store.lyricsPickOf(playing.sourceKey!), isNull);
      expect(tagIn('lrclib', 'in use'), findsOneWidget);

      // Back returns to Lyrics, now LRCLIB's again; the mic closes both.
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await settle(tester);
      expect(library.view.kind, ViewKind.lyrics);
      expect(credit(tester), 'From LRCLIB');
      await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('lyrics')));
      await settle(tester);
      expect(library.view.kind, ViewKind.songs, reason: '$size');
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });

  testWidgets('a kept choice shows at once in a new run', (tester) async {
    store.saveLyricsPick(playing.sourceKey!, 'vk');
    await pumpScreen(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics')));
    await settle(tester);
    expect(credit(tester), 'Words only, from VK (your choice)');
    expect(find.text('Слова без времени'), findsOneWidget);
  });

  testWidgets('sources not asked yet are asked when the chooser opens', (
    tester,
  ) async {
    final f = await pumpScreen(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
    await settle(tester);
    expect(sources[2].asked, 1);
    expect(sources[0].asked, 0, reason: 'stored rows are not asked again');
    expect(f.choices.last.status, LyricsChoiceStatus.none);
    // The refresh button asks every source again.
    await tester.tap(find.byKey(const ValueKey('lyrics-choices-refresh')));
    await settle(tester);
    expect(sources.map((source) => source.asked), [1, 1, 2]);
    expect(
      store.lyricsOf('lrclib', playing.sourceKey!)!.lyrics,
      isNotNull,
      reason: 'a none never erases found lyrics',
    );
  });
}
