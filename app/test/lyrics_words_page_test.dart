// Tests for plan 10 J6: the line sung now lights its words as they are sung
// (the smooth fill), only where the line has word times and the user
// follows by word; the clock that moves the fill stops when the song stops
// reporting; the heading's Lines / Words button and its stored setting.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/ui/lyrics_page.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/theme.dart';

const worded = Lyrics(
  source: 'heard',
  lines: [
    LyricLine(
      'Ночь улица фонарь',
      startMs: 1000,
      endMs: 3000,
      words: [WordTime(1000, 1400), WordTime(1500, 2000), WordTime(2100, 2900)],
    ),
    LyricLine('Line without words', startMs: 4000, endMs: 6000),
  ],
);

void main() {
  group('sungWordShares', () {
    const words = [
      WordTime(1000, 1400),
      null,
      WordTime(1500, 2000),
      WordTime(2000, 2000),
    ];

    test('a word fills over its own time', () {
      expect(sungWordShares(words, 900), [0, 0, 0, 0]);
      expect(sungWordShares(words, 1200), [0.5, 0, 0, 0]);
      expect(sungWordShares(words, 1750), [1, 1, 0.5, 0]);
      expect(sungWordShares(words, 2000), [1, 1, 1, 1]);
    });

    test('an untimed word lights after the word before it', () {
      expect(sungWordShares(words, 1399)[1], 0);
      expect(sungWordShares(words, 1400)[1], 1);
      // None before: it waits for the next timed word.
      expect(sungWordShares(const [null, WordTime(500, 900)], 499), [0, 0]);
      expect(sungWordShares(const [null, WordTime(500, 900)], 500)[0], 1);
    });
  });

  group('the word-lit line', () {
    late StreamController<Duration> positions;
    late Duration position;

    setUp(() {
      positions = StreamController<Duration>.broadcast();
      position = const Duration(milliseconds: 1200);
    });
    tearDown(() => positions.close());

    Future<void> open(
      WidgetTester tester, {
      bool byWord = true,
      Lyrics lyrics = worded,
      bool Function()? isPlaying,
    }) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: LyricsLines(
              lyrics: lyrics,
              header: const Text('credit'),
              position: () => position,
              positions: () => positions.stream,
              seek: (_) async {},
              byWord: byWord,
              isPlaying: isPlaying,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// The color the line's (lower) Text gives itself; null inherits.
    Color? ownColorOf(WidgetTester tester, String text) =>
        tester.widgetList<Text>(find.text(text)).first.style?.color;

    Finder sungPaintIn(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ClipPath &&
            '${widget.clipper.runtimeType}' == '_SungClip',
      ),
    );

    testWidgets('lights words on the line sung now when it has word times', (
      tester,
    ) async {
      await open(tester);
      // The text is drawn in the color of words not sung yet, the sung
      // part painted over it.
      final unsung = ownColorOf(tester, 'Ночь улица фонарь');
      expect(unsung, isNotNull);
      expect(unsung, isNot(OwnColors.dark.text));
      expect(sungPaintIn('Ночь улица фонарь'), findsOneWidget);
      // A line without word times lights whole, as before.
      positions.add(const Duration(milliseconds: 4100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(ownColorOf(tester, 'Line without words'), isNull);
      expect(sungPaintIn('Line without words'), findsNothing);
      expect(sungPaintIn('Ночь улица фонарь'), findsNothing);
    });

    testWidgets('following by line lights the whole line', (tester) async {
      await open(tester, byWord: false);
      expect(ownColorOf(tester, 'Ночь улица фонарь'), isNull);
      expect(sungPaintIn('Ночь улица фонарь'), findsNothing);
    });

    testWidgets('the clock runs while reports come and stops after', (
      tester,
    ) async {
      await open(tester);
      positions.add(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'moving');
      // No report for longer than the glide: the line stops asking for
      // frames (a paused song costs nothing).
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a paused song neither glides nor asks for frames', (
      tester,
    ) async {
      await open(tester, isPlaying: () => false);
      // A seek while paused reports one position: the words show it, and
      // no clock starts.
      positions.add(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(sungPaintIn('Ночь улица фонарь'), findsOneWidget);
    });

    testWidgets('the sung words sit on the same layout as the line', (
      tester,
    ) async {
      await open(tester);
      final texts = find.text('Ночь улица фонарь');
      expect(texts, findsNWidgets(2));
      expect(tester.getRect(texts.first), tester.getRect(texts.last));
    });

    testWidgets('a click on a word-lit line still seeks to its start', (
      tester,
    ) async {
      final seeks = <Duration>[];
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: LyricsLines(
              lyrics: worded,
              header: const Text('credit'),
              position: () => position,
              positions: () => positions.stream,
              seek: (to) async => seeks.add(to),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Ночь улица фонарь').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(seeks, [const Duration(milliseconds: 1000)]);
    });
  });

  group('Lines / Words button', () {
    testWidgets('says the way now and switches on a click', (tester) async {
      var byWord = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => LyricsFollowButton(
                byWord: byWord,
                onChanged: (value) => setState(() => byWord = value),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Words'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-follow')));
      await tester.pump();
      expect(byWord, isFalse);
      expect(find.text('Lines'), findsOneWidget);
    });

    testWidgets('compact: an icon with its words in the tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: LyricsFollowButton(
              byWord: false,
              onChanged: (_) {},
              compact: true,
            ),
          ),
        ),
      );
      expect(find.text('Lines'), findsNothing);
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('lyrics-follow')),
      );
      expect(button.tooltip, startsWith('Lines.'));
    });
  });

  test('the setting is kept: words by default, lines once chosen', () {
    final stored = <String, String?>{};
    var settings = ShellSettings(
      read: (key) => stored[key],
      write: (key, value) => stored[key] = value,
    );
    expect(settings.lyricsByWord, isTrue);
    settings.setLyricsByWord(false);
    expect(stored['lyrics.follow'], 'lines');
    settings = ShellSettings(
      read: (key) => stored[key],
      write: (key, value) => stored[key] = value,
    );
    expect(settings.lyricsByWord, isFalse);
  });
}
