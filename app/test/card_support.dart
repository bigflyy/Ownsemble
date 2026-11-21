// Pressing a cover card's Play in widget tests: the button shows only while
// the card is pointed at (CardPlayButton), so a mouse rests on it first.

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Points a mouse at [button] (a card's Play), lets it fade in, then taps it.
/// The mouse stays there until the test ends.
Future<void> tapCardPlay(WidgetTester tester, Finder button) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(button));
  addTearDown(mouse.removePointer);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(button);
}
