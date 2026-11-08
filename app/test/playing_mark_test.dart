import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/playing_mark.dart';

void main() {
  Future<void> pumpMark(
    WidgetTester tester, {
    required bool playing,
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: PlayingMark(playing: playing, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }

  /// The bar heights the mark paints at this moment.
  List<double> barsNow(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('playing-bars')),
    );
    return (paint.painter! as PlayingBarsPainter).heights();
  }

  testWidgets('the bars move while the song plays', (tester) async {
    await pumpMark(tester, playing: true);
    final first = barsNow(tester);
    await tester.pump(const Duration(milliseconds: 160));
    final later = barsNow(tester);
    expect(later, isNot(equals(first)));
    expect(tester.binding.hasScheduledFrame, isTrue);
    // Each bar stays inside the mark.
    for (final h in [...first, ...later]) {
      expect(h, inInclusiveRange(0.2, 1.0));
    }
  });

  testWidgets('a paused song shows the still pause sign and asks for no '
      'frames', (tester) async {
    await pumpMark(tester, playing: false);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('playing-bars')), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('pausing stops the bars, playing starts them again', (
    tester,
  ) async {
    await pumpMark(tester, playing: true);
    await pumpMark(tester, playing: false);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await pumpMark(tester, playing: true);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('with reduced motion the bars stand still', (tester) async {
    await pumpMark(tester, playing: true, reduceMotion: true);
    expect(find.byKey(const ValueKey('playing-bars')), findsOneWidget);
    final first = barsNow(tester);
    await tester.pump(const Duration(milliseconds: 160));
    expect(barsNow(tester), first);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('NowPlaying tells a row whether its song is the current one', (
    tester,
  ) async {
    late bool? seen;
    Widget probe(int id) => Builder(
      builder: (context) {
        seen = NowPlaying.stateFor(context, id);
        return const SizedBox();
      },
    );
    await tester.pumpWidget(
      NowPlaying(trackId: 7, playing: true, child: probe(7)),
    );
    expect(seen, isTrue);
    await tester.pumpWidget(
      NowPlaying(trackId: 7, playing: false, child: probe(7)),
    );
    expect(seen, isFalse, reason: 'current but paused');
    await tester.pumpWidget(
      NowPlaying(trackId: 7, playing: true, child: probe(8)),
    );
    expect(seen, isNull, reason: 'not the current song');
    await tester.pumpWidget(probe(7));
    expect(seen, isNull, reason: 'no scope');
  });
}
