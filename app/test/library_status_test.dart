import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/ui/ownsemble_app.dart';

import 'support/fixture_provider.dart';
import 'support/ui_performance_fixture.dart';

/// Hold generated sync replies so UI transitions can be observed without VK.
class StatusProvider extends FixtureProvider {
  Completer<SyncResult> reply = Completer<SyncResult>();
  void Function(List<Track>)? merge;
  final modes = <bool>[];
  int disconnections = 0;
  int syncCancellations = 0;
  Object? connectionFailure;
  Completer<void>? finishSignIn;

  @override
  Future<void> finishPrivateSignIn() async {
    await finishSignIn?.future;
  }

  @override
  Future<void> cancelSync() async {
    syncCancellations++;
  }

  StatusProvider() {
    connected = true;
  }

  @override
  Future<void> connect() async {
    if (connectionFailure != null) throw connectionFailure!;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnections++;
    connected = false;
  }

  @override
  Future<SyncResult> sync(
    void Function(List<Track>) receive, {
    required bool fromTop,
    bool newestOnly = false,
    List<String> checkpoint = const [],
  }) {
    merge = receive;
    modes.add(newestOnly);
    return reply.future;
  }
}

void main() {
  final boundary = GlobalKey();
  setUpAll(() async {
    for (final entry in {
      'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
      'MaterialIcons': '../.local/toolchains/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (file.existsSync()) {
        await (FontLoader(
          entry.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  Future<void> preview(WidgetTester tester, String name) => tester.runAsync(
    () async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await render.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('../.local/ownsemble-smoke').create(recursive: true);
      await File('../.local/ownsemble-smoke/status-$name-preview.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    },
  );

  late Directory folder;
  late LibraryStore store;
  late StatusProvider provider;
  late AppController controller;

  AppController open() => AppController(
    store,
    musicProvider: provider,
    playbackPlayer: UiBenchmarkPlayback(),
    decodeAudio: (_) async => 180,
    diagnosticStore: DiagnosticStore.memory(),
  );

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-status-');
    store = LibraryStore(folder)
      ..merge([const Track('1_1', 'Generated status song', 'Fixture', 180)]);
    store.setSetting('volume', 0);
    store.saveSyncHead(['1_1']);
    provider = StatusProvider();
    controller = open();
  });

  tearDown(() async {
    if (!provider.reply.isCompleted) {
      provider.reply.complete(const SyncResult(0, false, reason: 'cancelled'));
    }
    if (!controller.disposed) await controller.shutdown();
    await folder.delete(recursive: true);
  });

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
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    if (!provider.reply.isCompleted) {
      provider.reply.complete(const SyncResult(0, false, reason: 'cancelled'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final closing = controller.shutdown().then((_) => closed = true);
    for (var attempt = 0; attempt < 30 && !closed; attempt++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(closed, isTrue);
    await closing;
  }

  test('sync result persists independently from playback and newest checks preserve coverage', () async {
    controller.message = 'Paused';
    final syncing = controller.refresh(full: false);
    await Future<void>.delayed(Duration.zero);
    expect(controller.syncing, isTrue);
    provider.merge!([const Track('1_2', 'Generated new song', 'Fixture', 180)]);
    provider.reply.complete(
      const SyncResult(12, false, reason: 'known_head', head: ['1_2', '1_1']),
    );
    await syncing;
    expect(controller.message, 'Paused');
    expect(
      store.setting('last_sync_result'),
      containsPair('phase', 'succeeded'),
    );
    expect(store.setting('last_sync_result'), containsPair('mode', 'head'));
    expect(store.setting('last_sync_result'), containsPair('checked', 12));
    expect(store.setting('last_sync_result'), containsPair('added', 1));
    expect(store.setting('coverage'), isNot('complete'));
    await controller.shutdown();
    store = LibraryStore(folder);
    provider = StatusProvider();
    controller = open();
    expect(controller.syncing, isFalse);
    expect(store.setting('last_sync_result'), containsPair('checked', 12));
  });

  test(
    'offline cancels sync and ignores late rows and successful completion',
    () async {
      final syncing = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      await controller.setOffline(true);
      provider.merge!([
        const Track('1_2', 'Late generated song', 'Fixture', 180),
      ]);
      provider.reply.complete(
        const SyncResult(99, false, reason: 'provider_end'),
      );
      await syncing;
      expect(store.count, 1);
      expect(store.setting('coverage'), isNot('complete'));
      expect(
        store.setting('last_sync_result'),
        containsPair('phase', 'cancelled'),
      );
      expect(controller.offline, isTrue);
      expect(controller.syncing, isFalse);
    },
  );

  test(
    'stopping initial discovery does not silently resume a full scan',
    () async {
      store.setSetting('initial_sync_pending', true);
      final initial = controller.refresh(full: false);
      await Future<void>.delayed(Duration.zero);
      await controller.cancelSync();
      expect(provider.syncCancellations, 1);
      provider.reply.complete(
        const SyncResult(40, false, reason: 'provider_end'),
      );
      await initial;
      provider.reply = Completer<SyncResult>();
      final next = controller.refresh(full: false);
      await Future<void>.delayed(Duration.zero);
      provider.reply.complete(const SyncResult(1, false, reason: 'known_head'));
      await next;
      expect(provider.modes, [false, true]);
    },
  );

  test(
    'newest check cannot silently discard a pending full-scan continuation',
    () async {
      provider.reply.complete(const SyncResult(1, true, reason: 'time_budget'));
      await controller.refresh();
      await controller.checkNewest();
      expect(provider.modes, [false]);
      await controller.cancelSync();
      expect(controller.syncActivity.phase, 'cancelled');
    },
  );

  testWidgets('a full scan can be stopped between continuation slices', (
    tester,
  ) async {
    provider.reply.complete(const SyncResult(1, true, reason: 'time_budget'));
    await tester.runAsync(() => controller.refresh());
    try {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('library-sync-control')));
      await tester.pumpAndSettle();
      expect(find.text('Stop sync'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check newest'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Scan full library'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Stop sync'));
      await tester.pumpAndSettle();
      expect(controller.syncActivity.phase, 'cancelled');
      provider.reply = Completer<SyncResult>();
      final next = controller.refresh(full: false);
      await tester.pump();
      expect(provider.modes, [false, true]);
      provider.reply.complete(const SyncResult(1, false, reason: 'known_head'));
      await tester.runAsync(() => next);
      await tester.pumpAndSettle();
    } finally {
      await close(tester);
    }
  });

  testWidgets('explicit Check newest stays bounded during unfinished import', (
    tester,
  ) async {
    store.setSetting('initial_sync_pending', true);
    try {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('library-sync-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check newest'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(provider.modes, [true]);
    } finally {
      await close(tester);
    }
  });

  test(
    'sync failure stays separate from playback feedback and permits retry',
    () async {
      controller.message = 'Paused';
      final failing = controller.checkNewest();
      provider.reply.completeError(const ProofFailure('music_page_timeout'));
      await failing;
      expect(controller.syncing, isFalse);
      expect(controller.message, 'Paused');
      expect(controller.syncActivity.phase, 'failed');
      provider.reply = Completer<SyncResult>();
      final retry = controller.checkNewest();
      provider.reply.complete(const SyncResult(1, false, reason: 'known_head'));
      await retry;
      expect(controller.syncActivity.phase, 'succeeded');
    },
  );

  test('disconnect keeps generated cache bytes and prevents late connection completion', () async {
    final file = File('${folder.path}/generated-cache.mp3')
      ..writeAsBytesSync([1, 2, 3]);
    store.saveAsset(CachedAudio('1_1', file.path, 'generated', 3, 180));
    store.pinTrack('1_1', true);
    provider.finishSignIn = Completer<void>();
    final connecting = controller.connectVk();
    await controller.disconnectVk();
    provider.finishSignIn!.complete();
    await connecting;
    expect(provider.connected, isFalse);
    expect(controller.autoSync, isFalse);
    expect(controller.offline, isTrue);
    expect(file.readAsBytesSync(), [1, 2, 3]);
    expect(store.asset('1_1'), isNotNull);
    expect(store.individuallyPinned('1_1'), isTrue);
  });

  test(
    'shutdown ignores a late sync merge without touching its closed database',
    () async {
      final syncing = controller.refresh();
      await controller.shutdown();
      provider.merge!([
        const Track('1_2', 'Late after shutdown', 'Fixture', 180),
      ]);
      provider.reply.complete(
        const SyncResult(20, false, reason: 'provider_end'),
      );
      await syncing;
      store = LibraryStore(folder);
      provider = StatusProvider();
      controller = open();
      expect(store.count, 1);
      expect(controller.syncActivity.phase, 'cancelled');
    },
  );

  testWidgets(
    'status panel scales and Escape dismisses it without issuing a scan',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await show(tester);
        await tester.tap(find.byKey(const ValueKey('library-sync-control')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('No sync result yet'), findsNothing);
        expect(provider.modes, isEmpty);
      } finally {
        await close(tester);
      }
    },
  );

  test('private sign-in failure stays in connection status', () async {
    controller.message = 'Paused';
    provider.connectionFailure = const ProofFailure('private_signin_required');
    await controller.signInVk();
    expect(controller.message, 'Paused');
    expect(controller.connectionError, 'private_signin_required');
  });

  testWidgets('connection badge inherits the application label font', (
    tester,
  ) async {
    try {
      await show(tester);
      expect(
        DefaultTextStyle.of(tester.element(find.text('VK CONNECTED')))
            .style
            .fontFamily,
        'Segoe UI',
      );
    } finally {
      await close(tester);
    }
  });

  testWidgets(
    'sync stays in its own control while local playback remains available',
    (tester) async {
      final syncing = controller.refresh(full: false);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      controller.providerStatus('Checking generated VK entries');
      try {
        await show(tester);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.byKey(const ValueKey('library-sync-control')),
          findsOneWidget,
        );
        expect(find.text('Checking generated VK entries'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find
                    .ancestor(
                      of: find.byTooltip('Play Generated status song'),
                      matching: find.byType(IconButton),
                    )
                    .first,
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const ValueKey('library-sync-control')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('Checking newest entries'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Check newest'),
              )
              .onPressed,
          isNull,
        );
        provider.reply.complete(
          const SyncResult(12, false, reason: 'head_budget'),
        );
        await tester.runAsync(() => syncing);
        await tester.pumpAndSettle();
        expect(find.text('Newest check incomplete'), findsOneWidget);
        expect(find.text('12 checked · 0 new'), findsOneWidget);
        final turn = tester.widget<RotationTransition>(
          find.descendant(
            of: find.byKey(const ValueKey('library-sync-control')),
            matching: find.byType(RotationTransition),
          ),
        );
        expect(
          turn.turns.value,
          0,
          reason: 'Idle status icons must remain upright',
        );
        expect(find.text('Full scan complete'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'sync panel offers explicit short and full actions without scanning on open',
    (tester) async {
      try {
        await show(tester);
        await tester.tap(find.byKey(const ValueKey('library-sync-control')));
        await tester.pumpAndSettle();
        expect(provider.modes, isEmpty);
        expect(find.text('No sync result yet'), findsOneWidget);
        await tester.tap(find.text('Check newest'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(provider.modes, [true]);
        provider.reply.complete(
          const SyncResult(1, false, reason: 'known_head'),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        provider.reply = Completer<SyncResult>();
        await tester.tap(find.text('Scan full library'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(provider.modes, [true, false]);
        provider.reply.complete(
          const SyncResult(1, false, reason: 'provider_end'),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.text('Full scan complete'), findsOneWidget);
        await preview(tester, 'sync');
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'connection badge opens controls and disconnect preserves local library and pins',
    (tester) async {
      store.pinTrack('1_1', true);
      try {
        await show(tester);
        await tester.tap(
          find.byKey(const ValueKey('library-connection-control')),
        );
        await tester.pumpAndSettle();
        expect(provider.disconnections, 0);
        await preview(tester, 'connection');
        await tester.tap(find.text('Disconnect VK'));
        await tester.pumpAndSettle();
        expect(provider.disconnections, 1);
        expect(controller.offline, isTrue);
        expect(controller.autoSync, isFalse);
        expect(store.count, 1);
        expect(store.individuallyPinned('1_1'), isTrue);
        expect(find.text('Offline mode'), findsWidgets);
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets(
    'download states distinguish cache and protection without contradictory success icons',
    (tester) async {
      store.pinTrack('1_1', true);
      try {
        await show(tester);
        expect(
          find.byTooltip('Kept offline · waiting to download'),
          findsOneWidget,
        );
        expect(find.byTooltip('Allow automatic cleanup'), findsOneWidget);
        controller.downloadId = '1_1';
        controller.downloadStage = 'receiving';
        controller.providerChanged();
        await tester.pump();
        expect(
          find.byTooltip('Kept offline · waiting to download'),
          findsNothing,
        );
        expect(
          find.byTooltip('Stop playback and cancel download'),
          findsOneWidget,
        );
      } finally {
        await close(tester);
      }
    },
  );
}
