// The bottom bar's song text (user, 2026-11-08): the artist line is cut at
// the title's width, at least 160 px and at most 280 px, so the heart after
// it stays by the title; a cut line scrolls while the mouse is over it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/album_link.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/ui/theme.dart';

const longArtists = 'Сергей Канунников, Никита Алёшин, Илья Кудряшов';

Track song(String title, {String artist = longArtists, String album = ''}) =>
    Track(
      id: 1,
      sourceId: 1,
      source: TrackSource.vk,
      artist: artist,
      title: title,
      album: album,
      durationSec: 200,
    );

Future<void> pumpTitle(WidgetTester tester, Track track) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(OwnColors.dark),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SongTitle(track: track),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

double widthOf(WidgetTester tester, Finder finder) =>
    tester.getSize(finder).width;

void main() {
  final block = find.byType(SongTitle);
  final artist = find.byType(ArtistAlbumLine);

  testWidgets("a long artist line is cut at the title's width", (tester) async {
    // A title between 160 and 280 px wide.
    await pumpTitle(tester, song('Полыхала степь', album: 'Зодчий'));
    final title = widthOf(tester, find.text('Полыхала степь'));
    expect(title, inInclusiveRange(170, 270));
    expect(widthOf(tester, block), closeTo(title, 1));
    expect(widthOf(tester, artist), closeTo(title, 1));
  });

  testWidgets('a very short title still leaves the artist 160 px', (
    tester,
  ) async {
    await pumpTitle(tester, song('Я'));
    expect(widthOf(tester, block), closeTo(160, 1));
    expect(widthOf(tester, artist), closeTo(160, 1));
  });

  testWidgets('a very long title stops at 280 px', (tester) async {
    await pumpTitle(tester, song('Очень длинное название песни без конца'));
    expect(widthOf(tester, block), closeTo(280, 1));
  });

  testWidgets('short lines keep their own width', (tester) async {
    await pumpTitle(tester, song('Я', artist: 'Ая'));
    expect(widthOf(tester, block), lessThan(40));
  });

  testWidgets('a cut line scrolls while the mouse is over it, and stops '
      'when it leaves', (tester) async {
    await pumpTitle(tester, song('Полыхала степь', album: 'Зодчий'));
    final scroll = find.descendant(
      of: block,
      matching: find.byType(Scrollable),
    );
    expect(scroll, findsNothing, reason: 'nothing moves at rest');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(artist));
    await tester.pump();
    expect(scroll, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));
    final position = tester.state<ScrollableState>(scroll).position;
    expect(position.pixels, greaterThan(0), reason: 'the line moves');
    expect(position.maxScrollExtent, greaterThan(0));

    await mouse.moveTo(const Offset(790, 500));
    await tester.pump();
    expect(scroll, findsNothing, reason: 'back to "..." when the mouse left');
    await tester.pump(const Duration(seconds: 30));
    await mouse.removePointer();
  });

  testWidgets('a line that fits does not scroll', (tester) async {
    await pumpTitle(tester, song('Полыхала степь', artist: 'Кино'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(artist));
    await tester.pump();
    expect(
      find.descendant(of: block, matching: find.byType(Scrollable)),
      findsNothing,
    );
    await mouse.removePointer();
  });
}
