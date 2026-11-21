// The cover card's Play (user pick A, 2026-11-21): hidden until the card is
// pointed at, kept on the playing card as Pause, a spinner while it starts.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/card_play.dart';
import 'package:ownsemble/ui/playing_mark.dart';
import 'package:ownsemble/ui/theme.dart';

void main() {
  late int plays;
  late int toggles;
  late Completer<void>? starting;

  setUp(() {
    plays = 0;
    toggles = 0;
    starting = null;
  });

  Future<void> show(WidgetTester tester, {bool? state}) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [OwnColors.dark]),
      home: NowPlaying(
        trackId: state == null ? null : 1,
        playing: state ?? false,
        onPlayOrPause: () => toggles++,
        child: Center(
          child: CardHover(
            child: SizedBox(
              key: const ValueKey('card'),
              width: 128,
              height: 160,
              child: Align(
                alignment: Alignment.bottomRight,
                child: CardPlayButton(
                  key: const ValueKey('play'),
                  state: state,
                  onPlay: () async {
                    plays++;
                    await starting?.future;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(const ValueKey('play')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('hidden and not pressable until the card is pointed at', (
    tester,
  ) async {
    await show(tester);
    expect(opacity(tester), 0);
    await tester.tap(find.byKey(const ValueKey('play')), warnIfMissed: false);
    await tester.pump();
    expect(plays, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getTopLeft(find.byKey(const ValueKey('card'))),
    );
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(tester), 1);
    await tester.tap(find.byKey(const ValueKey('play')));
    await tester.pump();
    expect(plays, 1);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(tester), 0);
  });

  testWidgets('the playing card keeps it as Pause and a press pauses', (
    tester,
  ) async {
    await show(tester, state: true);
    expect(opacity(tester), 1);
    expect(find.byIcon(Icons.pause), findsOne);
    await tester.tap(find.byKey(const ValueKey('play')));
    await tester.pump();
    expect(toggles, 1);
    expect(plays, 0);

    await show(tester, state: false);
    expect(opacity(tester), 1);
    expect(find.byIcon(Icons.play_arrow), findsOne);
  });

  testWidgets('a spinner shows while the list starts', (tester) async {
    starting = Completer<void>();
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byKey(const ValueKey('card'))),
    );
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('play')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOne);
    // Kept in sight while it starts, even when the mouse leaves.
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(tester), 1);
    starting!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(opacity(tester), 0);
  });
}
