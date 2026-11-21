import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/lyrics_page.dart';

void main() {
  late LibraryStore store;
  late LibraryController library;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final generated = store.ensureSource(
      TrackSource.generated,
      account: 'generator',
      name: 'Generated songs',
    );
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    final fillerId = store.upsertAll(generated, [
      const NewTrack(
        sourceKey: 'gen-1',
        artist: 'Filler Artist',
        title: 'Filler Song',
        durationSec: 200,
        addedAt: 100,
      ),
    ]).single;
    store.saveAudioFile(fillerId, 'cache/sample.mp3', 1, pinned: true);
    store.upsertAll(vk, [
      for (var i = 0; i < 30; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Artist $i',
          title: 'Song $i',
          durationSec: 200,
          addedAt: i,
        ),
    ]);
    library = LibraryController(store.loadAll());
  });
  tearDown(() => store.close());

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          playback: PlaybackController(
            player: PlayerService(muted: true, dataDir: '.'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  EditableText searchField(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText));

  Future<void> pressCtrlF(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('the mic button opens Lyrics and closes it again, wide and '
      'narrow (plan 10)', (tester) async {
    for (final size in const [
      Size(1400, 900),
      Size(760, 900),
      Size(640, 700),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final lyrics = LyricsController(
        load: (source, ref) => null,
        save: (source, ref, lyrics, {md5}) {},
        routeOf: lyricsRouteBySource((sourceId) => null),
      );
      // The player's buttons show with a song: one restored from before.
      final player = PlayerService(muted: true, dataDir: '.')
        ..restore(library.all.last, Duration.zero);
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
      expect(find.text('Song 29'), findsOneWidget, reason: '$size');

      await tester.tap(find.byKey(const ValueKey('lyrics')));
      await tester.pump();
      await tester.pump();
      expect(library.view.kind, ViewKind.lyrics, reason: '$size');
      // No account here to ask VK: the place says so.
      expect(find.byType(LyricsPage), findsOneWidget);
      expect(find.textContaining('Log in to the VK account'), findsOneWidget);
      expect(find.text('Song 29'), findsNothing);

      // The mic button closes it; then it opens again and Back closes it.
      await tester.tap(find.byKey(const ValueKey('lyrics')));
      await tester.pump();
      expect(library.view.kind, ViewKind.songs, reason: '$size');
      expect(find.text('Song 29'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await tester.pump();
      expect(library.view.kind, ViewKind.songs, reason: '$size');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the smallest window fits the bottom bar with the heart, Up '
      'Next and the mic (B24: acceptance-36g, a 16 px overflow of the title '
      'row)', (tester) async {
    for (final size in const [Size(480, 440), Size(560, 440)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = PlayerService(muted: true, dataDir: '.')
        ..restore(library.all.last, Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            key: ValueKey(size),
            library: library,
            playback: PlaybackController(player: player),
            collections: CollectionsController(store),
            lyrics: LyricsController(
              load: (source, ref) => null,
              save: (source, ref, lyrics, {md5}) {},
              routeOf: lyricsRouteBySource((sourceId) => null),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('player-heart')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });

  testWidgets('a search typed on Lyrics shows the songs it finds; Back '
      'returns to Lyrics and the mic closes it (Codex review)', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerService(muted: true, dataDir: '.')
      ..restore(library.all.last, Duration.zero);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          playback: PlaybackController(player: player),
          lyrics: LyricsController(
            load: (source, ref) => null,
            save: (source, ref, lyrics, {md5}) {},
            routeOf: lyricsRouteBySource((sourceId) => null),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lyrics')));
    await tester.pump();
    expect(library.view.kind, ViewKind.lyrics);
    await tester.enterText(find.byType(TextField), 'Song 2');
    await tester.pump();
    expect(library.view.kind, ViewKind.songs);
    expect(find.text('Song 29'), findsOneWidget);
    // Songs has no Back button: Alt+Left goes back.
    library.goBack();
    await tester.pump();
    expect(library.view.kind, ViewKind.lyrics);
    await tester.tap(find.byKey(const ValueKey('lyrics')));
    await tester.pump();
    expect(library.view.kind, ViewKind.songs);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bottom bar keeps a usable volume slider with the mic '
      'button (plan 10; acceptance-36a tapped beside a 7 px slider)', (
    tester,
  ) async {
    for (final width in const [1100.0, 900.0, 760.0]) {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // As in the app: Stack and Download buttons too.
      final player = PlayerService(
        muted: true,
        dataDir: '.',
        storage: AudioStorage(dataDir: '.', store: store),
      )..restore(library.all.last, Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            key: ValueKey(width),
            library: library,
            playback: PlaybackController(player: player),
            collections: CollectionsController(store),
            lyrics: LyricsController(
              load: (source, ref) => null,
              save: (source, ref, lyrics, {md5}) {},
              routeOf: lyricsRouteBySource((sourceId) => null),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      // A slider is wide enough to hit, or only the mute button shows.
      final slider = find.byKey(const ValueKey('volume'));
      expect(find.byKey(const ValueKey('mute')), findsOneWidget);
      if (width >= 900) expect(slider, findsOneWidget, reason: '$width px');
      if (slider.evaluate().isNotEmpty) {
        expect(
          tester.getSize(slider).width,
          greaterThanOrEqualTo(40),
          reason: 'volume slider at a $width px window',
        );
      }
      expect(tester.takeException(), isNull, reason: '$width px');
    }
  });

  testWidgets('Ctrl+F focuses search after clicking a song', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Song 29'));
    await tester.pump();
    searchField(tester).focusNode.unfocus();
    await tester.pump();
    expect(searchField(tester).focusNode.hasFocus, isFalse);

    await pressCtrlF(tester);
    expect(searchField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('Ctrl+F selects the search text while typing', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'song');
    await pressCtrlF(tester);
    final selection = library.searchText.selection;
    expect((selection.start, selection.end), (0, 4));
  });

  testWidgets('Ctrl+F works with the Russian keyboard layout', (tester) async {
    await pumpScreen(tester);
    searchField(tester).focusNode.unfocus();
    await tester.pump();
    // With the Russian layout the F key types "а": the logical key is the
    // Cyrillic letter, only the physical key is still F.
    // The test key simulator cannot produce Cyrillic keys, so another Latin
    // letter stands in: only the physical key says F.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.keyV,
      physicalKey: PhysicalKeyboardKey.keyF,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(searchField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('generated filler songs are marked, VK songs are not', (
    tester,
  ) async {
    await pumpScreen(tester);
    final fillerRow = find.ancestor(
      of: find.text('Filler Song'),
      matching: find.byType(InkWell),
    );
    final vkRow = find.ancestor(
      of: find.text('Song 29'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(
        of: fillerRow,
        matching: find.byKey(const ValueKey('filler-tag')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: vkRow,
        matching: find.byKey(const ValueKey('filler-tag')),
      ),
      findsNothing,
    );
  });

  testWidgets('Escape clears the search even without focus', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'song 1');
    searchField(tester).focusNode.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(library.searchText.text, isEmpty);
  });
}
