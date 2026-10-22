import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/artwork_viewport.dart';

void main() {
  testWidgets(
    'fast jumps request only the settled visible destination, not cached offscreen rows',
    (tester) async {
      final scroll = ScrollController();
      final seen = <int>{}, hidden = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 240,
              child: ListView.builder(
                controller: scroll,
                itemExtent: 60,
                itemCount: 2633,
                itemBuilder: (_, index) => ArtworkViewport(
                  key: ValueKey(index),
                  identity: index,
                  onVisible: (_) => seen.add(index),
                  onHidden: (_) => hidden.add(index),
                  child: Text('Generated $index'),
                ),
              ),
            ),
          ),
        ),
      );
      scroll.jumpTo(12000);
      await tester.pump(const Duration(milliseconds: 16));
      scroll.jumpTo(90000);
      await tester.pump(const Duration(milliseconds: 16));
      expect(seen, isEmpty);
      await tester.pump(const Duration(milliseconds: 130));
      expect(seen, {1500, 1501, 1502, 1503});
      scroll.jumpTo(90180);
      await tester.pump();
      expect(hidden, containsAll([1500, 1501, 1502]));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'a non-scrolling player cover registers once and releases its demand',
    (tester) async {
      final active = <Object>{};
      var activations = 0;
      Widget view() => MaterialApp(
        home: ArtworkViewport(
          identity: 'player',
          onVisible: (owner) {
            active.add(owner);
            activations++;
          },
          onHidden: active.remove,
          child: const SizedBox(width: 48, height: 48),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pump(const Duration(milliseconds: 130));
      expect(active.length, 1);
      await tester.pumpWidget(view());
      await tester.pump(const Duration(milliseconds: 130));
      expect(activations, 1);
      await tester.pumpWidget(const SizedBox());
      expect(active, isEmpty);
    },
  );
}
