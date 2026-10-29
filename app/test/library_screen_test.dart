import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';

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
            player: PlayerService(vk: null, muted: true, dataDir: '.'),
            recordPlay: (_) {},
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
    // The test key simulator cannot produce Cyrillic keys, so the event
    // Windows delivers is handed to the keyboard directly.
    const cyrillicA = LogicalKeyboardKey(0x0430);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyF,
        logicalKey: cyrillicA,
        character: 'а',
        timeStamp: Duration.zero,
      ),
    );
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyF,
        logicalKey: cyrillicA,
        timeStamp: Duration.zero,
      ),
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
      find.descendant(of: fillerRow, matching: find.text('filler')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: vkRow, matching: find.text('filler')),
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
