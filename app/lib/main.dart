import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'data/library_store.dart';
import 'media/audio_policy.dart';
import 'bootstrap/application.dart';
import 'platform/windows/windows_music_browser.dart';
import 'services/browser_smoke_test.dart';
import 'services/preview.dart';
import 'services/smoke_test.dart';
import 'services/streaming_smoke_test.dart';
import 'services/runtime_diagnostics.dart';
import 'ui/ownsemble_app.dart';

String? repositoryRoot() {
  for (final start in [
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ]) {
    var folder = start;
    for (var i = 0; i < 10; i++) {
      if (File('${folder.path}/AGENTS.md').existsSync() &&
          Directory('${folder.path}/app').existsSync()) {
        return folder.path;
      }
      if (folder.parent.path == folder.path) break;
      folder = folder.parent;
    }
  }
  return null;
}

void main(List<String> args) {
  LibraryStore? store;
  void reportError(Object error, StackTrace? stack) {
    try {
      store?.report(categoryOf(error));
      if (store != null) {
        File('${store!.directory.path}/runtime-error.json').writeAsStringSync(
          jsonEncode({
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            ...runtimeDiagnostic(error, stack),
          }),
        );
      }
    } catch (_) {
      /* A closed/full database must not cause a second failure. */
    }
  }

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) =>
          reportError(details.exception, details.stack);
      MediaKit.ensureInitialized();
      PlatformInAppBrowser.debugLoggingSettings = DebugLoggingSettings(
        enabled: false,
      );
      PlatformWebViewEnvironment.debugLoggingSettings = DebugLoggingSettings(
        enabled: false,
      );
      PlatformInAppWebViewController.debugLoggingSettings =
          DebugLoggingSettings(enabled: false);
      final root = repositoryRoot();
      final smoke =
          args.contains('--smoke-test') || args.contains('--smoke-resume');
      final browserSmoke = args.contains('--browser-smoke');
      final streamingSmoke = args.contains('--streaming-smoke');
      final preview =
          smoke || browserSmoke || streamingSmoke || args.contains('--demo');
      if (preview && root == null) {
        throw const ProofFailure('preview_requires_checkout');
      }
      final directory = Directory(
        root != null
            ? '$root/.local/${streamingSmoke
                  ? 'ownsemble-streaming-smoke'
                  : browserSmoke
                  ? 'ownsemble-browser-smoke'
                  : smoke
                  ? 'ownsemble-smoke'
                  : preview
                  ? 'ownsemble-demo'
                  : 'ownsemble'}'
            : (await getApplicationSupportDirectory()).path,
      );
      store = LibraryStore(directory);
      if (preview && !browserSmoke && !streamingSmoke) {
        await seedPreview(store!);
      }
      final controller = createApplication(
        store!,
        demo: preview,
        repositoryRoot: root,
        profilePath: root != null
            ? '$root/.local/vk-proof/app-profile/flutter-webview'
            : '${directory.path}/private-webview',
      );
      if (args.contains('--offline') ||
          args.contains('--offline-check') ||
          preview) {
        controller.offline = true;
      }
      const MethodChannel('ownsemble/lifecycle')
          .setMethodCallHandler((call) async {
            if (call.method == 'closing') await controller.shutdown();
            return null;
          });
      final boundary = GlobalKey();
      runApp(
        RepaintBoundary(
          key: boundary,
          child: OwnsembleApp(controller: controller),
        ),
      );
      store!.report(
        preview ? 'preview_ready' : 'app_ready',
        count: store!.count,
      );
      if (args.contains('--offline-check') && !preview) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            await controller.checkOfflineControls();
            await controller.shutdown();
            await const MethodChannel('ownsemble/lifecycle')
                .invokeMethod<void>('close');
          }());
        });
      } else if (streamingSmoke) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            await runStreamingSmoke(store!);
            await controller.shutdown();
            await const MethodChannel('ownsemble/lifecycle')
                .invokeMethod<void>('close');
          }());
        });
      } else if (browserSmoke) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            await runBackgroundBrowserSmoke(
              store!,
              visible: args.contains('--browser-smoke-visible'),
              browserFactory: WindowsMusicBrowserFactory(
                '${store!.directory.path}/browser-runtime-$pid',
                hidden: !args.contains('--browser-smoke-visible'),
              ),
            );
            await controller.shutdown();
            await const MethodChannel('ownsemble/lifecycle')
                .invokeMethod<void>('close');
          }());
        });
      } else if (smoke) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(
            runSmokeTest(
              controller,
              boundary,
              resumed: args.contains('--smoke-resume'),
            ),
          );
        });
      }
    },
    reportError,
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {}),
  );
}
