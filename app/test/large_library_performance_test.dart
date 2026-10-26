import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/playback_queue.dart';
import 'package:ownsemble/ui/ownsemble_app.dart';

import 'support/ui_performance_fixture.dart';

/// Measure generated UI work separately from provider/network timing.
void main() {
  // Keep every database and benchmark report separate from real application data.
  late Directory directory;
  // Count synchronous production catalog reads in the generated workload.
  late MeasuredLibraryStore store;
  // Supply silent generated playback clock events.
  late UiBenchmarkPlayback playback;
  // Retain real controller invalidation and queue handling.
  late UiPerformanceController controller;

  setUpAll(() async {
    // Render readable generated previews with the same fonts as the Windows app.
    for (final entry in {
      'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
      'MaterialIcons': '../.local/toolchains/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    }.entries) {
      // Load only public application/system font resources.
      final file = File(entry.value);
      if (file.existsSync()) {
        await (FontLoader(
          entry.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  // Capture only generated application widgets, including their popup overlay.
  final boundary = GlobalKey();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ownsemble-ui-work-');
    store = MeasuredLibraryStore(directory);
    seedUiPerformanceLibrary(store, 2633);
    playback = UiBenchmarkPlayback();
    controller = UiPerformanceController(store, playback);
    controller.queue.replace([const QueueEntry('900000000000002_1')], 0);
  });

  tearDown(() async {
    // Preserve cleanup even when a regression assertion fails.
    if (!controller.disposed) await controller.shutdown();
    await directory.delete(recursive: true);
  });

  /// Render a normal library screen without native media or provider requests.
  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: OwnsembleApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dispose the screen and controller before Flutter checks for pending timers.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Progress both Flutter's fake clock and real stream/IO disposal acknowledgements.
    var closed = false;
    // Observe completion before awaiting a future that may need another event-loop turn.
    final closing = controller.shutdown().then((_) => closed = true);
    for (var attempt = 0; attempt < 30 && !closed; attempt++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(closed, isTrue, reason: 'Generated controller shutdown must finish');
    await closing;
  }

  /// Write only synthetic timing/count measurements to a fixed ignored report directory.
  void record(String operation, Map<String, Object> metrics) {
    // Allow before/after captures without making runtime data paths configurable.
    const requestedLabel = String.fromEnvironment(
      'OWNSEMBLE_PERF_LABEL',
      defaultValue: 'current',
    );
    // Restrict report names to known non-private labels.
    final label = ['baseline', 'current', 'final'].contains(requestedLabel)
        ? requestedLabel
        : 'current';
    // Resolve the repository from the app test working directory.
    final output = Directory('../.local/ownsemble-performance')
      ..createSync(recursive: true);
    File('${output.path}/$label-$operation.json').writeAsStringSync(
      '${jsonEncode({'generated_only': true, 'operation': operation, ...metrics})}\n',
    );
  }

  test(
    'display caches reuse missing values and evict old recording lookups',
    () {
      // Cache absence rather than issuing the same missing-record query repeatedly.
      expect(controller.displayTrack('generated-missing'), isNull);
      store.resetReads();
      expect(controller.displayTrack('generated-missing'), isNull);
      expect(store.trackReads, 0);
      // Keep only a bounded window when visiting many distant recordings.
      for (var index = 1; index <= 600; index++) {
        controller.displayTrack('900000000000002_$index');
        controller.individuallyPinned('900000000000002_$index');
        controller.artworkFile('900000000000002_$index');
      }
      store.resetReads();
      // Reuse the retained window without SQL, including absent artwork keys.
      controller.displayTrack('900000000000002_600');
      controller.individuallyPinned('900000000000002_600');
      controller.artworkFile('900000000000002_600');
      expect(store.reads.values.fold<int>(0, (sum, count) => sum + count), 0);
      // Observe eviction through fresh reads without depending on private cache internals.
      controller.displayTrack('900000000000002_1');
      controller.individuallyPinned('900000000000002_1');
      controller.artworkFile('900000000000002_1');
      expect(store.trackReads, 1);
      expect(store.pinReads, 1);
      expect(store.artworkReads, 1);
    },
  );

  testWidgets(
    'reduced-motion menu supports keyboard dismissal and queue action',
    (tester) async {
      try {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await show(tester);
        await tester.tap(find.byTooltip('Song options').first);
        await tester.pump();
        // Complete immediately when the system requests reduced motion.
        final route = ModalRoute.of(tester.element(find.text('Add to queue')))!;
        expect(route.animation!.isCompleted, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Song details & lyrics'), findsNothing);
        // Keep a single menu action local and preserve the chosen recording.
        await tester.tap(find.byTooltip('Song options').first);
        await tester.pump();
        await tester.tap(find.text('Add to queue'));
        await tester.pumpAndSettle();
        expect(controller.queue.entries.length, 2);
        expect(controller.queue.entries.last.id, '900000000000002_1');
        expect(controller.metadataRequests, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets('playback clock updates do not repeat catalog metadata queries', (
    tester,
  ) async {
    try {
      await show(tester);
      store.resetReads();
      // Measure UI rebuild work after initial metadata and library loading.
      final watch = Stopwatch()..start();
      for (var second = 1; second <= 10; second++) {
        playback.advance(second);
        await tester.pump(const Duration(milliseconds: 16));
      }
      record('clock', {
        'updates': 10,
        'elapsed_us': watch.elapsedMicroseconds,
        'reads': store.reads,
      });
      expect(store.reads.values.fold<int>(0, (sum, count) => sum + count), 0);
      expect(tester.takeException(), isNull);
    } finally {
      await close(tester);
    }
  });

  testWidgets(
    'catalog changes and cursor changes refresh cached display data',
    (tester) async {
      try {
        await show(tester);
        // Keep previously rendered metadata warm before mutating the generated library.
        expect(controller.current?.title, 'Generated song 0');
        // Apply a genuine library change through the same invalidation used by browsing and sync.
        store.merge([
          const Track(
            '900000000000002_1',
            'Updated generated title',
            'Changed artist',
            181,
          ),
          const Track(
            '900000000000002_3000',
            'New generated song',
            'Changed artist',
            182,
          ),
        ]);
        controller.browse('library');
        await tester.pumpAndSettle();
        expect(controller.current?.title, 'Updated generated title');
        expect(find.text('2634 songs in your collection'), findsOneWidget);
        // A selection change must not reuse the previous recording even without a catalog mutation.
        controller.queue.replace([const QueueEntry('900000000000002_2')], 0);
        playback.advance(1);
        await tester.pump();
        expect(controller.current?.title, 'Generated song 1');
        // Distinguish aggregate Pile protection from an individual track pin in the UI.
        final pile = store.piles().first;
        store.addToPile(pile.id, '900000000000002_1');
        await controller.pinPile(pile.id, true);
        await tester.pump();
        expect(find.byTooltip('Release individual pin'), findsNothing);
        await controller.pinTrack('900000000000002_1');
        await tester.pump();
        expect(find.byTooltip('Release individual pin'), findsOneWidget);
        expect(store.isPinned('900000000000002_1'), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  // Require distant jumps to depend on the viewport, not every intervening song.
  for (final catalogSize in [2633, 10000]) {
    testWidgets(
      'queue jumps keep catalog reads bounded at $catalogSize recordings',
      (tester) async {
        try {
          // Build a second stress size without using any real catalog entries.
          if (catalogSize > 2633) seedUiPerformanceLibrary(store, catalogSize);
          controller.queue.replace(
            List.generate(
              catalogSize,
              (index) =>
                  QueueEntry('900000000000002_${index + 1}', index + 100),
            ),
            0,
          );
          await show(tester);
          // Measure the actual queue-open path before its transition settles.
          final openWatch = Stopwatch()..start();
          await tester.tap(find.byTooltip('Queue (Ctrl+Shift+Q)'));
          await tester.pumpAndSettle();
          // Select only the queue's scrollable, excluding sidebar/library scrolling.
          final scrollable = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            ),
          );
          // Preserve queue-open timing independently of the jump itself.
          final openMicroseconds = openWatch.elapsedMicroseconds;
          store.resetReads();
          // Jump directly to a distant region rather than scrolling through earlier rows.
          final jumpWatch = Stopwatch()..start();
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent * .9);
          await tester.pumpAndSettle();
          record('queue-$catalogSize', {
            'catalog_size': catalogSize,
            'open_us': openMicroseconds,
            'jump_us': jumpWatch.elapsedMicroseconds,
            'reads': store.reads,
          });
          expect(
            store.trackReads,
            lessThanOrEqualTo(80),
            reason: 'A jump must not resolve all preceding tracks',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await close(tester);
        }
      },
    );
  }

  testWidgets(
    'song menu is styled and settles within its local interaction budget',
    (tester) async {
      try {
        await show(tester);
        store.resetReads();
        // Time only local input/build work, not provider or metadata loading.
        final watch = Stopwatch()..start();
        await tester.tap(find.byTooltip('Song options').first);
        // Start the newly pushed menu route before measuring its scheduled animation frames.
        await tester.pump();
        // Measure the menu route independently of the button's longer ink-ripple animation.
        final menuRoute = ModalRoute.of(
          tester.element(find.text('Song details & lyrics')),
        )!;
        // Bound the entrance to twelve deterministic 16 ms frames.
        var frames = 0;
        while (!menuRoute.animation!.isCompleted && frames < 12) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
        }
        expect(menuRoute.animation!.isCompleted, isTrue);
        record('menu', {
          'elapsed_us': watch.elapsedMicroseconds,
          'animation_frames': frames,
          'menu_items': find
              .byWidgetPredicate((widget) => widget is PopupMenuItem)
              .evaluate()
              .length,
          'reads': store.reads,
        });
        expect(frames, lessThanOrEqualTo(12));
        expect(find.text('Song details & lyrics'), findsOneWidget);
        // Require each action to carry its matching icon inside the menu item.
        final details = find.ancestor(
          of: find.text('Song details & lyrics'),
          matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        );
        expect(
          find.descendant(
            of: details,
            matching: find.byIcon(Icons.info_outline_rounded),
          ),
          findsOneWidget,
        );
        expect(
          controller.metadataRequests,
          0,
          reason: 'Opening actions must not fetch details',
        );
        expect(controller.queue.entries.length, 1);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          // Save a generated-only visual artifact outside version control.
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          // Release the GPU image after encoding the preview.
          final image = await render.toImage();
          // Encode the popup and library as a standalone PNG.
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('../.local/ownsemble-smoke').create(recursive: true);
          await File('../.local/ownsemble-smoke/song-menu-preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'row buttons respond immediately while title double-tap still selects a song',
    (tester) async {
      try {
        await show(tester);
        await tester.tap(find.byTooltip('Play Generated song 1'));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          controller.playRequests,
          1,
          reason: 'A control must not wait for the row double-tap timeout',
        );
        await tester.tap(find.byTooltip('Keep offline').first);
        await tester.pump(const Duration(milliseconds: 16));
        expect(store.individuallyPinned('900000000000002_1'), isTrue);
        // Keep the intentional title-area gesture after isolating adjacent single-tap controls.
        await tester.tap(find.text('Generated song 0').first);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('Generated song 0').first);
        await tester.pump();
        expect(controller.playRequests, 2);
        expect(controller.queue.current?.id, '900000000000002_1');
        // Let the recognizer's minimum-tap timer expire before disposing the test tree.
        await tester.pump(const Duration(milliseconds: 100));
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'queue keeps repeated occurrences and shuffled selection with large text',
    (tester) async {
      try {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        controller.queue.replace([
          const QueueEntry('900000000000002_1', 101),
          const QueueEntry('900000000000002_1', 102),
          const QueueEntry('900000000000002_2', 103),
        ], 0);
        controller.queue.order = [2, 1, 0];
        await show(tester);
        await tester.tap(find.byTooltip('Queue (Ctrl+Shift+Q)'));
        await tester.pumpAndSettle();
        // Select the last duplicate in playback order, preserving its independent occurrence.
        final duplicate = find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Generated song 0'),
            )
            .last;
        await tester.ensureVisible(duplicate);
        await tester.tap(duplicate);
        await tester.pumpAndSettle();
        expect(controller.selectedOccurrence, 101);
        expect(controller.queue.entries.length, 3);
        expect(controller.queue.order, [2, 1, 0]);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );
}
