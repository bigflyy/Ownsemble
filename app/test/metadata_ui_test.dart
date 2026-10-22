import 'package:ownsemble/platform/media_kit_playback.dart';
import 'package:ownsemble/media/local_audio.dart';

import 'support/fixture_provider.dart';

import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/media/artwork_cache.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/ui/track_details.dart';
import 'package:ownsemble/ui/ownsemble_app.dart';
import 'package:ownsemble/services/playback_queue.dart';

class MetadataPlayer extends PlatformPlayer {
  MetadataPlayer() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> setVolume(double volume) async {}
}

Future<void> warmArtwork(WidgetTester tester, File file) =>
    tester.runAsync(() async {
      for (final width in [84, 104, 1440]) {
        final ready = Completer<void>();
        final stream = ResizeImage(
          FileImage(file),
          width: width,
        ).resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) {
            stream.removeListener(listener);
            ready.complete();
          },
          onError: (Object error, StackTrace? stack) {
            stream.removeListener(listener);
            ready.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        await ready.future;
      }
    });

void main() {
  setUpAll(() async {
    // Optional local fonts make the generated acceptance preview readable.
    // CI assertions do not depend on these files or pixel-perfect glyphs.
    for (final entry in {
      'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
      'MaterialIcons': 'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(entry.key)
        ..addFont(file.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  late Directory folder;
  late LibraryStore store;
  late AppController controller;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-metadata-ui-');
    store = LibraryStore(folder)
      ..merge([
        const Track('1_2', 'Generated', 'Fixture', 180),
      ], discoveredAt: 1609459200000);
    store.mergeMetadata('1_2', {
      'album': 'Generated album',
      'uploadedAt': 1514764800,
    });
    store.saveLyrics('1_2', {
      'text': 'Generated lyric line',
      'lines': [],
    }, state: 'available');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF83AB62), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 2);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
    final artwork = ArtworkCache(
      Directory('${folder.path}/artwork'),
      fetch: (_) async => ArtworkResponse(png, 'image/png'),
    );
    store.saveArtwork(
      '1_2',
      await artwork.obtain(Uri.parse('https://test.userapi.com/generated.png')),
    );
    controller = AppController(
      store,
      demo: true,
      playbackPlayer: MediaKitPlayback(
        Player(platformPlayer: MetadataPlayer()),
      ),
      decodeAudio: decodeLocalAudio,
      musicProvider: FixtureProvider(),
      artworkCache: artwork,
    );
    controller.offline = true;
  });
  tearDown(() async {
    await controller.shutdown();
    imageCache.clear();
    imageCache.clearLiveImages();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await folder.delete(recursive: true);
  });
  testWidgets(
    'cached row artwork opens a larger zoomable preview offline and Escape closes it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await warmArtwork(tester, controller.artworkFile('1_2')!);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: OwnsembleApp(controller: controller),
        ),
      );
      await tester.tap(find.byTooltip('View artwork for Generated'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        tester.getSize(find.byType(InteractiveViewer)).width,
        greaterThan(400),
      );
      final zoom = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(zoom.maxScale, greaterThan(zoom.minScale));
      expect(find.text('Fixture'), findsWidgets);
      expect(controller.offline, isTrue);
      expect(controller.queue.current, isNull);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 0);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.local/ownsemble-smoke/artwork-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'player artwork opens the selected recording and missing covers are not clickable',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.merge([const Track('1_3', 'No artwork', 'Generated artist', 180)]);
      controller.queue.replace([const QueueEntry('1_2')], 0);
      await warmArtwork(tester, controller.artworkFile('1_2')!);
      await tester.pumpWidget(OwnsembleApp(controller: controller));
      expect(find.byTooltip('View artwork for No artwork'), findsNothing);
      final current = controller.queue.current;
      final playing = controller.player.state.playing;
      await tester.tap(find.byTooltip('View artwork for Generated').last);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Generated'), findsWidgets);
      expect(controller.queue.current, current);
      expect(controller.player.state.playing, playing);
      await tester.tap(find.byTooltip('Close artwork (Escape)'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'details label import/upload dates separately and show saved lyrics offline',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackDetails(
              controller: controller,
              track: store.track('1_2')!,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Imported into Ownsemble'), findsOneWidget);
      expect(find.text('Uploaded to VK'), findsOneWidget);
      expect(find.text('Added in VK'), findsNothing);
      expect(find.text('Generated album'), findsOneWidget);
      expect(find.text('Generated lyric line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'cached artwork renders offline and the real song menu opens its bound details',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      // Preload the exact ResizeImage key outside fakeAsync, otherwise the file
      // reader can remain suspended when the test tears down on Windows.
      await tester.runAsync(() async {
        final done = Completer<void>();
        final stream = ResizeImage(
          FileImage(controller.artworkFile('1_2')!),
          width: 84,
        ).resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (image, synchronous) {
            stream.removeListener(listener);
            done.complete();
          },
          onError: (Object error, StackTrace? stack) {
            done.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        await done.future;
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: OwnsembleApp(controller: controller),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(controller.artworkFile('1_2'), isNotNull);
      await tester.tap(find.byTooltip('Song options'));
      // Current row double-tap recognition delays this single click. The reported
      // menu-latency issue is queued separately; this is the details acceptance test.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song details & lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Generated album'), findsOneWidget);
      expect(find.text('Generated lyric line'), findsOneWidget);
      expect(find.text('Imported into Ownsemble'), findsOneWidget);
      expect(find.text('Uploaded to VK'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final preview =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await preview.toByteData(format: ui.ImageByteFormat.png);
        final output = File('../.local/ownsemble-smoke/metadata-preview.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        preview.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
