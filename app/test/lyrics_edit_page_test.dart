// Tests for plan 10 I2g2: the lyrics editor place in the real screen.
// Edit opens on what the Lyrics place shows, typing and Save keep the
// user's edit (Undo in the toast takes it back), Enter splits and
// Backspace joins, Tap to time takes Space, Edit as text keeps the times
// of unchanged lines, Cancel asks before dropping changes, and Back keeps
// a draft. Wide and narrow windows. The words are made up.

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_edit.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';

/// A source that is never asked here: every answer is stored already.
class StoredOnlySource implements OutsideLyricsSource {
  StoredOnlySource(this.id);

  @override
  final String id;

  @override
  Future<LyricsCandidate?> find(SongNames song) async => null;
}

const lrclibLines = [
  LyricLine('Первая строка', startMs: 1000),
  LyricLine('Second line here', startMs: 4000),
  LyricLine('Third line', startMs: 8000),
];

void main() {
  late LibraryStore store;
  late LibraryController library;
  late Track playing;
  late LyricsController lyrics;
  late PlaybackController playback;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Артист',
        title: 'Песня',
        durationSec: 200,
        addedAt: 1,
      ),
    ]);
    library = LibraryController(store.loadAll());
    playing = library.all.single;
    store
      ..saveLyrics('vk', '1_1', null)
      ..saveLyrics(
        'lrclib',
        '1_1',
        const Lyrics(source: 'lrclib', lines: lrclibLines),
        meta: '{"id":"1","exact":true,"diff":0}',
      );
  });
  tearDown(() => store.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpEditor(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    lyrics = LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadOffset: store.lyricsOffsetOf,
      saveOffset: store.saveLyricsOffset,
      edits: store,
      routeOf: lyricsRouteBySource((sourceId) => null),
      sources: [
        StoredOnlySource('lrclib'),
        StoredOnlySource('netease'),
        StoredOnlySource('qq'),
      ],
      now: () => 1000,
    );
    final player = PlayerService(muted: true, dataDir: '.')
      ..restore(playing, const Duration(milliseconds: 4200));
    playback = PlaybackController(player: player);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          key: ValueKey(size),
          library: library,
          playback: playback,
          lyrics: lyrics,
        ),
      ),
    );
    await tester.pump();
    if (library.view.kind != ViewKind.lyrics) library.toggleLyrics();
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit')));
    await settle(tester);
  }

  Finder field(int index) => find.byKey(ValueKey('lyrics-edit-field-$index'));

  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextField>(field(index)).controller!.text;

  testWidgets('Edit, type, Save; Undo in the toast takes it back (wide and '
      'narrow)', (tester) async {
    for (final size in const [Size(1400, 900), Size(480, 760)]) {
      store.forgetEdit('1_1');
      await pumpEditor(tester, size);
      expect(library.view.kind, ViewKind.lyricsEdit, reason: '$size');
      expect(playback.holdSong, isTrue, reason: 'the song repeats');
      expect(fieldText(tester, 0), 'Первая строка');
      expect(find.text('0:04.0'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow at $size');

      await tester.enterText(field(1), 'Second line, fixed');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('lyrics-edit-save')));
      await settle(tester);
      expect(library.view.kind, ViewKind.lyrics);
      expect(playback.holdSong, isFalse);
      expect(lyrics.shownSource, editedSource);
      final edit = store.editOf('1_1')!;
      expect(edit.basedOn, 'lrclib');
      expect(
        edit.lines[1],
        const LyricLine('Second line, fixed', startMs: 4000),
      );
      expect(find.text('Your edit is saved.'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(store.editOf('1_1'), isNull);
      expect(lyrics.shownSource, 'lrclib');
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('Enter splits a line; Backspace at its start joins it back', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.showKeyboard(field(1));
    final controller = tester.widget<TextField>(field(1)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await settle(tester);
    expect(fieldText(tester, 1), 'Second');
    expect(fieldText(tester, 2), 'line here');
    expect(find.text('--:--'), findsOneWidget, reason: 'the new row');
    expect(find.text('no time: lit with the line above'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(fieldText(tester, 1), 'Second line here');
    expect(find.text('--:--'), findsNothing);
  });

  testWidgets('Tap to time: Space times the marked line, not play or pause', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-tap')));
    await settle(tester);
    // At 4.2 s the lines up to 4.0 s are sung: Third line is next.
    expect(find.text('next'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(find.text('0:04.2'), findsOneWidget, reason: 'Third line at 4.2');
    expect(playback.player.playing.value, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(find.text('next'), findsOneWidget);
    // Ctrl+Z outside a field undoes the tap.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('0:04.2'), findsNothing, reason: 'the tap is undone');
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-tap')));
    await settle(tester);
    expect(find.text('0:08.0'), findsOneWidget);
  });

  testWidgets('Edit as text keeps the times of lines left as they were', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-text')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('lyrics-edit-textbox')),
      'Первая строка\nA new line\nThird line',
    );
    await settle(tester);
    expect(
      find.text('3 lines: 2 keep a time, 1 new without one.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-text')));
    await settle(tester);
    expect(fieldText(tester, 1), 'A new line');
    expect(find.text('0:01.0'), findsOneWidget);
    expect(find.text('0:08.0'), findsOneWidget);
    expect(find.text('--:--'), findsOneWidget);
  });

  testWidgets('Cancel asks before dropping changes', (tester) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.enterText(field(0), 'changed');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-cancel')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-keep')));
    await settle(tester);
    expect(library.view.kind, ViewKind.lyricsEdit);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-cancel')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-drop')));
    await settle(tester);
    expect(library.view.kind, ViewKind.lyrics);
    expect(store.editOf('1_1'), isNull);
  });

  testWidgets('Back keeps a draft; Edit goes on from it', (tester) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.enterText(field(0), 'draft words');
    await settle(tester);
    library.goBack();
    await settle(tester);
    expect(library.view.kind, ViewKind.lyrics);
    expect(find.byKey(const ValueKey('lyrics-edit-draft')), findsOneWidget);
    expect(store.editOf('1_1'), isNull);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit')));
    await settle(tester);
    expect(fieldText(tester, 0), 'draft words');
  });

  testWidgets('Edited menu: undo the last save, back to the original, and '
      'the chooser row forgets the edit', (tester) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.enterText(field(0), 'one');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-save')));
    await settle(tester);
    expect(find.text('Песня - Артист · edited by you'), findsOneWidget);
    expect(
      find.text("Edited by you, from LRCLIB's lyrics"),
      findsOneWidget,
      reason: 'the credit line',
    );
    await tester.pump(const Duration(seconds: 5));

    await tester.tap(find.byKey(const ValueKey('lyrics-edited')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-again')));
    await settle(tester);
    await tester.enterText(field(0), 'two');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-save')));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(store.editOf('1_1')!.saves, 2);
    expect(store.editOf('1_1')!.basedOn, 'lrclib', reason: 'still LRCLIB');

    await tester.tap(find.byKey(const ValueKey('lyrics-edited')));
    await settle(tester);
    expect(find.textContaining('; 2 saves kept'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-undo-save')));
    await settle(tester);
    expect(store.editOf('1_1')!.lines.first.text, 'one');

    await tester.tap(find.byKey(const ValueKey('lyrics-edited')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lyrics-show-original')));
    await settle(tester);
    expect(lyrics.shownSource, 'lrclib');
    expect(find.byKey(const ValueKey('lyrics-edit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
    await settle(tester);
    expect(find.byKey(const ValueKey('lyrics-choice-edited')), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('lyrics-choice-edited'))),
      buttons: kSecondaryButton,
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('menu-forget-edit')));
    await settle(tester);
    expect(store.editOf('1_1'), isNull);
    expect(find.byKey(const ValueKey('lyrics-choice-edited')), findsNothing);
  });

  // Plan 10 I2g5, from the user's first try (session 57): a line below, a
  // music break that says what it is, and the keys shown and listed.
  Future<void> openMenu(WidgetTester tester, int row, String item) async {
    await tester.tap(find.byKey(ValueKey('lyrics-edit-menu-$row')));
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('lyrics-edit-$item')));
    await settle(tester);
  }

  testWidgets('The line menu inserts a line below and a timed music break', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-menu-1')));
    await settle(tester);
    expect(
      find.text('Make it a music break'),
      findsNothing,
      reason: 'it only cleared the words',
    );
    await tester.tapAt(Offset.zero);
    await settle(tester);

    await openMenu(tester, 1, 'insert-below');
    expect(fieldText(tester, 1), 'Second line here');
    expect(fieldText(tester, 2), '', reason: 'the new row is below');
    expect(fieldText(tester, 3), 'Third line');
    expect(find.text('(gap between verses)'), findsOneWidget);
    expect(find.text('a time makes it a music break'), findsOneWidget);

    // The song is at 4.2 s, past row 1's start: the break starts now.
    await openMenu(tester, 1, 'insert-break');
    expect(fieldText(tester, 2), '');
    expect(find.text('0:04.2'), findsOneWidget);
    expect(find.text('(music break)'), findsOneWidget);
    await openMenu(tester, 0, 'insert-above');
    expect(fieldText(tester, 0), '');
    expect(fieldText(tester, 1), 'Первая строка');
  });

  testWidgets('Ctrl+S saves, also while typing in a line', (tester) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.enterText(field(1), 'Saved by keys');
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(library.view.kind, ViewKind.lyrics);
    expect(store.editOf('1_1')!.lines[1].text, 'Saved by keys');
    expect(playback.shuffle, isFalse, reason: 'not Shuffle here');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Tap to time shows its keys; F1 lists the editor keys', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-tap')));
    await settle(tester);
    for (final words in const [
      'line starts now',
      'back a line',
      'skip a line',
      'play 3 s back',
    ]) {
      expect(find.text(words), findsOneWidget, reason: words);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle(tester);
    expect(find.text('In the lyrics editor'), findsOneWidget);
    expect(find.text('Save the edit'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);

    // F1 also while typing in a line, and the top bar's keyboard button
    // (a keyboard without a usable F1) opens the same list.
    await tester.tap(find.byKey(const ValueKey('lyrics-edit-tap')));
    await settle(tester);
    await tester.showKeyboard(field(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle(tester);
    expect(find.text('In the lyrics editor'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);
    // Ctrl+/ for keyboards whose F1 opens something else (the user's
    // opens the browser, session 57), also while typing.
    await tester.showKeyboard(field(1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('In the lyrics editor'), findsOneWidget);
    expect(fieldText(tester, 1), 'Second line here', reason: 'nothing typed');
    await tester.tap(find.text('Close'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('keyboard-help')));
    await settle(tester);
    expect(find.text('In the lyrics editor'), findsOneWidget);
  });
}
