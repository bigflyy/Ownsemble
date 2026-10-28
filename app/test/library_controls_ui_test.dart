import 'package:ownsemble/platform/media_kit_playback.dart';
import 'package:ownsemble/media/local_audio.dart';

import 'support/fixture_provider.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';
import 'package:ownsemble/ui/ownsemble_app.dart';
import 'package:ownsemble/ui/app_shortcuts.dart';

class VolumePlayer extends PlatformPlayer {
  VolumePlayer() : super(configuration: const PlayerConfiguration());
  final volumes = <double>[];
  Completer<void>? gate;
  @override
  Future<void> setVolume(double volume) async {
    final pending = gate;
    gate = null;
    if (pending != null) await pending.future;
    volumes.add(volume);
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }
}

class UiController extends AppController {
  int toggles = 0;
  int nextCalls = 0, previousCalls = 0, stops = 0;
  final seeks = <double>[];
  UiController(super.store, VolumePlayer native)
    : super(
        demo: true,
        playbackPlayer: MediaKitPlayback(Player(platformPlayer: native)),
        decodeAudio: decodeLocalAudio,
        musicProvider: FixtureProvider(),
        diagnosticStore: DiagnosticStore.memory(),
      );
  @override
  Future<void> togglePlay({bool diagnostic = false}) async => toggles++;
  @override
  Future<void> next({bool automatic = false, bool diagnostic = false}) async =>
      nextCalls++;
  @override
  Future<void> previous() async => previousCalls++;
  @override
  Future<void> stopPlayback({bool diagnostic = false}) async => stops++;
  @override
  Future<void> seek(double seconds, {bool diagnostic = false}) async =>
      seeks.add(seconds);
}

void main() {
  setUpAll(() async {
    for (final entry in {
      'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
      'Consolas': 'C:/Windows/Fonts/consola.ttf',
      'MaterialIcons': 'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (file.existsSync()) {
        await (FontLoader(
          entry.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  late Directory folder;
  late LibraryStore store;
  late VolumePlayer native;
  late UiController controller;
  late GlobalKey boundary;
  var created = false;
  void createController() {
    controller = UiController(store, native)..offline = true;
    created = true;
  }

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-controls-ui-');
    store = LibraryStore(folder)
      ..merge([
        const Track('1_1', 'Generated one', 'Fixture artist', 180),
        const Track('1_2', 'Generated two', 'Other artist', 245),
      ])
      ..setSetting('volume', 36.5);
    native = VolumePlayer();
    boundary = GlobalKey();
    created = false;
  });
  tearDown(() async {
    if (created) await controller.shutdown();
    await folder.delete(recursive: true);
  });
  Future<void> show(WidgetTester tester, {double width = 1280}) async {
    if (!created) createController();
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: OwnsembleApp(controller: controller),
      ),
    );
    await tester.pump();
  }

  Future<void> closeView(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Native wrappers and widget events use different async zones. Keep both
    // progressing until disposal has acknowledged the last volume write.
    var closed = false;
    final closing = controller.shutdown().then((_) => closed = true);
    for (var i = 0; i < 20 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(
      closed,
      isTrue,
      reason: 'Fixture shutdown must finish, not leak timers',
    );
    await closing;
  }

  void testControls(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        if (created && !controller.disposed) await closeView(tester);
      }
    });
  }

  Finder row(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(Material))
      .first;
  Finder within(String title, Finder child) =>
      find.descendant(of: row(title), matching: child);

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool alt = false,
    bool shift = false,
    PhysicalKeyboardKey? physicalKey,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key, physicalKey: physicalKey);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testControls(
    'VK coverage distinguishes the verified provider size from saved historical rows',
    (tester) async {
      // Keep generated local history larger than the current provider membership.
      store.setSetting('provider_library_count', 1);
      store.setSetting(
        'provider_library_verified_at',
        '2026-10-24T10:00:00.000Z',
      );
      store.setSetting('coverage', 'complete');
      createController();
      controller.view = 'vk';
      await show(tester);
      expect(
        find.textContaining('1 recording in last verified VK listing'),
        findsOneWidget,
      );
      expect(find.textContaining('2 saved locally'), findsOneWidget);
      expect(find.textContaining('coverage remains partial'), findsNothing);
    },
  );

  testControls('VK coverage labels an unfinished listing as partial', (
    tester,
  ) async {
    // Keep the existing incomplete-import warning visible until a real end witness.
    createController();
    controller.view = 'vk';
    await show(tester);
    expect(
      find.textContaining('VK listing coverage is partial'),
      findsOneWidget,
    );
    expect(find.textContaining('in last verified VK listing'), findsNothing);
  });

  testControls('shortcuts mute and adjust volume without intercepting AltGr', (
    tester,
  ) async {
    await show(tester);
    await chord(tester, LogicalKeyboardKey.keyM, control: true);
    expect(controller.muted, isTrue);
    await chord(tester, LogicalKeyboardKey.keyM, control: true);
    expect(controller.volumeLevel, 36.5);
    await chord(tester, LogicalKeyboardKey.arrowUp, control: true);
    expect(controller.volumeLevel, 41.5);
    await chord(tester, LogicalKeyboardKey.arrowDown, control: true);
    expect(controller.volumeLevel, 36.5);
    await chord(tester, LogicalKeyboardKey.keyM, control: true, alt: true);
    expect(controller.volumeLevel, 36.5);
    await closeView(tester);
  });

  testControls(
    'playback shortcuts preserve search word navigation and text editing',
    (tester) async {
      await show(tester);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Generated one');
      await chord(tester, LogicalKeyboardKey.arrowLeft, control: true);
      expect(controller.previousCalls, 0);
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      expect(
        editor.controller.selection.baseOffset,
        lessThan('Generated one'.length),
      );
      await chord(tester, LogicalKeyboardKey.arrowRight, control: true);
      await chord(tester, LogicalKeyboardKey.keyM, control: true);
      await chord(tester, LogicalKeyboardKey.arrowUp, control: true);
      await chord(tester, LogicalKeyboardKey.arrowLeft, alt: true);
      await chord(tester, LogicalKeyboardKey.period, control: true);
      await chord(tester, LogicalKeyboardKey.keyS, control: true, shift: true);
      await chord(tester, LogicalKeyboardKey.keyR, control: true, shift: true);
      await chord(tester, LogicalKeyboardKey.keyQ, control: true, shift: true);
      expect(controller.nextCalls, 0);
      expect(controller.toggles, 0);
      expect(controller.stops, 0);
      expect(controller.seeks, isEmpty);
      expect(controller.volumeLevel, 36.5);
      expect(controller.queue.shuffle, isFalse);
      expect(controller.queue.repeat, QueueRepeat.off);
      expect(find.text('Up next'), findsNothing);
      await closeView(tester);
    },
  );

  testControls(
    'transport shortcuts match buttons and clamp seeking to track bounds',
    (tester) async {
      createController();
      controller.queue.replace([const QueueEntry('1_1')], 0);
      native.state = native.state.copyWith(
        position: const Duration(seconds: 178),
        duration: const Duration(seconds: 180),
      );
      await show(tester);
      await chord(tester, LogicalKeyboardKey.arrowRight, control: true);
      await chord(tester, LogicalKeyboardKey.arrowLeft, control: true);
      expect(controller.nextCalls, 1);
      expect(controller.previousCalls, 1);
      await chord(tester, LogicalKeyboardKey.arrowRight, alt: true);
      expect(controller.seeks.last, 180);
      native.state = native.state.copyWith(
        position: const Duration(seconds: 2),
      );
      await chord(tester, LogicalKeyboardKey.arrowLeft, alt: true);
      expect(controller.seeks.last, 0);
      await chord(tester, LogicalKeyboardKey.period, control: true);
      expect(controller.stops, 1);
      await chord(tester, LogicalKeyboardKey.keyS, control: true, shift: true);
      await chord(tester, LogicalKeyboardKey.keyR, control: true, shift: true);
      expect(controller.queue.shuffle, isTrue);
      expect(controller.queue.repeat, QueueRepeat.all);
      controller.loading = true;
      await chord(tester, LogicalKeyboardKey.arrowRight, alt: true);
      expect(controller.seeks, [180, 0]);
      await closeView(tester);
    },
  );

  testControls(
    'held mute fires once, held volume repeats, and physical bindings work on Cyrillic layout',
    (tester) async {
      await show(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyM);
      expect(controller.muted, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      expect(controller.volumeLevel, 10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      // The raw-key simulator cannot encode Cyrillic labels. Verify the unified
      // event matcher directly, then exercise dispatch with the supported label.
      expect(
        appShortcuts[AppCommand.mute]!.matches(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyM,
            logicalKey: LogicalKeyboardKey(0x044c),
            timeStamp: Duration.zero,
            character: 'ь',
          ),
        ),
        isTrue,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await chord(tester, LogicalKeyboardKey.keyM, control: true);
      expect(controller.muted, isTrue);
      await closeView(tester);
    },
  );

  testControls(
    'help and queue shortcuts open one closable surface with no action behind it',
    (tester) async {
      await show(tester);
      await chord(tester, LogicalKeyboardKey.f1);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).title,
        isA<Text>().having((t) => t.data, 'title', 'Keyboard shortcuts'),
      );
      expect(find.text('Ctrl+M'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.local/ownsemble-smoke/shortcuts-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await chord(tester, LogicalKeyboardKey.keyM, control: true);
      expect(controller.muted, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyQ, control: true, shift: true);
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsNothing);
      await closeView(tester);
    },
  );

  testControls('hovering controls reveals their actual shortcuts', (
    tester,
  ) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.volume_up_outlined)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Mute (Ctrl+M)'), findsOneWidget);
    expect(find.byTooltip('Next (Ctrl+Right)'), findsOneWidget);
    expect(find.byTooltip('Previous (Ctrl+Left)'), findsOneWidget);
    expect(find.byTooltip('Queue (Ctrl+Shift+Q)'), findsOneWidget);
    expect(find.byTooltip('Keyboard shortcuts (F1)'), findsOneWidget);
    await mouse.removePointer();
    await closeView(tester);
  });

  testControls('Space activates a focused button rather than global playback', (
    tester,
  ) async {
    await show(tester);
    Focus.of(tester.element(find.byIcon(Icons.volume_up_outlined)))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.muted, isTrue);
    expect(controller.toggles, 0);
    await closeView(tester);
  });

  testControls(
    'Space reaches the focused search editor and multiword filtering',
    (tester) async {
      await show(tester);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Generated');
      // The engine inserts printable text only when Flutter leaves the hardware
      // event unhandled. Then deliver the corresponding text-input update below.
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space, character: ' '),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(controller.toggles, 0);
      await tester.enterText(find.byType(TextField), 'Generated one');
      await tester.pump(const Duration(milliseconds: 160));
      expect(controller.query, 'Generated one');
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Generated one'),
        findsOneWidget,
      );
      expect(find.text('Generated two'), findsNothing);
      await closeView(tester);
    },
  );

  testControls(
    'Escape leaves search with pending query intact and restores playback keyboard focus',
    (tester) async {
      await show(tester);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Generated one');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      expect(editor.focusNode.hasFocus, isFalse);
      expect(editor.controller.text, 'Generated one');
      await tester.pump(const Duration(milliseconds: 160));
      expect(controller.query, 'Generated one');
      expect(controller.rows.map((r) => r.track.id), ['1_1']);
      expect(controller.toggles, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(controller.toggles, 1);
      await chord(tester, LogicalKeyboardKey.keyK, control: true);
      expect(editor.focusNode.hasFocus, isTrue);
      expect(editor.controller.text, 'Generated one');
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space, character: ' '),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(controller.toggles, 1);
      await closeView(tester);
    },
  );

  testControls(
    'Escape closes the front dialog before a second press leaves search',
    (tester) async {
      await show(tester);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Generated one');
      await tester.pump(const Duration(milliseconds: 160));
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      await chord(tester, LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(editor.focusNode.hasFocus, isTrue);
      expect(editor.controller.text, 'Generated one');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(editor.focusNode.hasFocus, isFalse);
      expect(controller.query, 'Generated one');
      expect(controller.toggles, 0);
      await closeView(tester);
    },
  );

  testControls(
    'Pile naming keeps spaces and editing chords without changing playback',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Create a Pile'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Generated Pile');
      await chord(tester, LogicalKeyboardKey.arrowLeft, control: true);
      await chord(tester, LogicalKeyboardKey.keyM, control: true);
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space, character: ' '),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(controller.previousCalls, 0);
      expect(controller.muted, isFalse);
      expect(controller.toggles, 0);
      await tester.enterText(field, 'Generated Pile With Spaces');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        store.piles().any((p) => p.name == 'Generated Pile With Spaces'),
        isTrue,
      );
      await closeView(tester);
    },
  );

  testControls(
    'unavailable transport actions do not dispatch without a selected song',
    (tester) async {
      await show(tester);
      await chord(tester, LogicalKeyboardKey.arrowLeft, control: true);
      await chord(tester, LogicalKeyboardKey.arrowRight, control: true);
      await chord(tester, LogicalKeyboardKey.arrowLeft, alt: true);
      await chord(tester, LogicalKeyboardKey.period, control: true);
      expect(controller.nextCalls, 0);
      expect(controller.previousCalls, 0);
      expect(controller.stops, 0);
      expect(controller.seeks, isEmpty);
      await closeView(tester);
    },
  );

  testControls(
    'Space toggles playback outside text input and Ctrl K focuses search',
    (tester) async {
      await show(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(controller.toggles, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      expect(controller.toggles, 1);
      await closeView(tester);
    },
  );

  testControls(
    'speaker mute restores volume, follows slider, and persists while muted',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Mute (Ctrl+M)'));
      await tester.pump();
      expect(controller.muted, isTrue);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(
        native.state.volume,
        0,
        reason: 'native writes: ${native.volumes}',
      );
      expect(find.byIcon(Icons.volume_off_outlined), findsOneWidget);
      expect(store.setting('volume'), 0);
      await tester.tap(find.byTooltip('Unmute (Ctrl+M)'));
      await tester.pump();
      expect(native.state.volume, 36.5);
      final slider = tester.widget<Slider>(find.byType(Slider).last);
      slider.onChanged!(22);
      await tester.pump();
      await tester.tap(find.byTooltip('Mute (Ctrl+M)'));
      await tester.pump();
      await tester.tap(find.byTooltip('Unmute (Ctrl+M)'));
      await tester.pump();
      expect(store.setting('volume'), 22);
      expect(controller.volumeLevel, 22);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await closeView(tester);
    },
  );

  test('muted volume restores the previous level after restart', () async {
    createController();
    await controller.volume(22);
    await controller.toggleMute();
    expect(native.state.volume, 0);
    await controller.shutdown();
    store = LibraryStore(folder);
    native = VolumePlayer();
    controller = UiController(store, native)..offline = true;
    await controller.toggleMute();
    expect(native.state.volume, 22);
    expect(store.setting('volume'), 22);
  });

  test(
    'rapid mute changes preserve intent while native volume is pending',
    () async {
      createController();
      final gate = native.gate = Completer<void>();
      final mute = controller.toggleMute();
      expect(controller.muted, isTrue);
      final unmute = controller.toggleMute();
      expect(controller.muted, isFalse);
      gate.complete();
      await Future.wait([mute, unmute]);
      expect(native.volumes.sublist(native.volumes.length - 2), [0, 36.5]);
      expect(native.state.volume, 36.5);
      expect(store.setting('volume'), 36.5);
    },
  );

  test(
    'zero slider volume can unmute and invalid values do not corrupt settings',
    () async {
      createController();
      await controller.volume(17);
      await controller.volume(0);
      await controller.toggleMute();
      expect(native.state.volume, 17);
      await controller.volume(double.nan);
      await controller.volume(double.infinity);
      expect(store.setting('volume'), 17);
      await controller.volume(130);
      expect(native.state.volume, 100);
      await controller.volume(-5);
      expect(native.state.volume, 0);
    },
  );

  testControls(
    'a failed saved song shows one status, retaining the saved file and error',
    (tester) async {
      store.saveAsset(
        const CachedAudio('1_1', 'generated.mp3', 'fixture', 100, 180),
      );
      store.trackError('1_1', 'audio_decode_failed');
      await show(tester);
      expect(
        within('Generated one', find.byIcon(Icons.error_outline)),
        findsOneWidget,
      );
      expect(
        within('Generated one', find.byIcon(Icons.check_circle_outline)),
        findsNothing,
      );
      expect(store.asset('1_1'), isNotNull);
      expect(
        store.rows().firstWhere((r) => r.track.id == '1_1').error,
        'audio_decode_failed',
      );
      await closeView(tester);
    },
  );

  testControls(
    'an active retry replaces stale saved/error statuses with progress',
    (tester) async {
      store.saveAsset(
        const CachedAudio('1_1', 'generated.mp3', 'fixture', 100, 180),
      );
      store.trackError('1_1', 'audio_decode_failed');
      createController();
      controller.downloadId = '1_1';
      await show(tester);
      expect(
        within('Generated one', find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
      expect(
        within('Generated one', find.byIcon(Icons.error_outline)),
        findsNothing,
      );
      expect(
        within('Generated one', find.byIcon(Icons.check_circle_outline)),
        findsNothing,
      );
      await closeView(tester);
    },
  );

  for (final width in [1080.0, 1440.0]) {
    testControls(
      'headers align with saved status, duration, play and title at $width',
      (tester) async {
        store.saveAsset(
          const CachedAudio('1_1', 'generated.mp3', 'fixture', 100, 180),
        );
        await show(tester, width: width);
        expect(
          tester.getCenter(find.text('SAVED')).dx,
          closeTo(
            tester
                .getCenter(
                  within(
                    'Generated one',
                    find.byIcon(Icons.check_circle_outline),
                  ),
                )
                .dx,
            .5,
          ),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.schedule_rounded)).dx,
          closeTo(tester.getCenter(find.text('3:00')).dx, .5),
        );
        expect(
          tester.getCenter(find.text('#')).dx,
          closeTo(
            tester.getCenter(find.byTooltip('Play Generated one')).dx,
            .5,
          ),
        );
        expect(
          tester.getTopLeft(find.text('TITLE / ARTIST')).dx,
          closeTo(tester.getTopLeft(find.text('Generated one')).dx, .5),
        );
        expect(tester.takeException(), isNull);
        await closeView(tester);
      },
    );
  }
}
