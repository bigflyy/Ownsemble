import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'proof_core.dart';
import 'proof_player.dart';
import 'proof_store.dart';
import 'self_test.dart';
import 'vk_proof.dart';
import 'native_browser.dart';
import 'music_navigation.dart';
import 'proof_restart.dart';

ProofStore? currentStore;
Map<String, dynamic> diagnosticFields(Object error, StackTrace stack) {
  final source = RegExp(
    r'package:ownsemble_flutter_proof/([a-z_]+)\.dart:(\d+)',
  ).firstMatch(stack.toString());
  final result = <String, dynamic>{
    'kind': error.runtimeType.toString().toLowerCase(),
  };
  if (error is ProofFailure && error.code != null) result['code'] = error.code;
  if (source != null) {
    result['stage'] = source.group(1);
    result['attempt'] = int.parse(source.group(2)!);
  }
  if (error is PlatformException &&
      RegExp(r'^[a-zA-Z0-9_]{1,80}$').hasMatch(error.code)) {
    result['code'] = error.code.toLowerCase();
  }
  if (error is PlatformException) {
    final message = error.message ?? '';
    if (message.contains('Graphics Context is not valid')) {
      result['stage'] = 'webview_graphics_unavailable';
    } else if (message.contains('Cannot create the InAppWebView instance')) {
      result['stage'] = 'webview_instance_creation_failed';
    }
  }
  return result;
}

String findRepository() {
  for (final start in [
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ]) {
    var folder = start;
    for (var i = 0; i < 10; i++) {
      if (File('${folder.path}/AGENTS.md').existsSync() &&
          Directory('${folder.path}/spikes/vk-provider').existsSync()) {
        return folder.path;
      }
      if (folder.parent.path == folder.path) break;
      folder = folder.parent;
    }
  }
  throw const ProofFailure('run_from_repository');
}

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();
      PlatformInAppBrowser.debugLoggingSettings = DebugLoggingSettings(
        enabled: false,
      );
      PlatformWebViewEnvironment.debugLoggingSettings = DebugLoggingSettings(
        enabled: false,
      );
      PlatformInAppWebViewController.debugLoggingSettings =
          DebugLoggingSettings(enabled: false);
      final root = Platform.isWindows
          ? findRepository()
          : (await getApplicationSupportDirectory()).path;
      final data = Directory(
        Platform.isWindows
            ? '$root/.local/flutter-proof'
            : '$root/proof-public',
      );
      final store = currentStore = ProofStore(data);
      store.record('flutter_app_started', {
        'platform': Platform.operatingSystem,
        'phase': 'ts_mp3_v1',
      });
      store.status('flutter_starting');
      final resumeFile = File('${data.path}/resume.json');
      final resume = resumeFile.existsSync()
          ? jsonDecode(resumeFile.readAsStringSync()) as Map
          : {};
      final offline =
          args.contains('--offline') || resume['phase'] == 'offline_pending';
      if (args.contains('--media-test') && !offline) {
        await runFixtureProof(
          store,
          (_) async {},
          (_) async => null,
          (_, _) async {},
          sawResource: () => false,
          browser: false,
        );
        await checkReferenceSample(store, root);
        await Process.start(
          Platform.resolvedExecutable,
          ['--offline'],
          workingDirectory: root,
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
      runApp(
        ProofApp(
          store: store,
          repositoryRoot: root,
          offline: offline,
          vkAuto: args.contains('--vk-auto'),
          autorun:
              args.contains('--self-test') ||
              const bool.fromEnvironment('PROOF_AUTORUN'),
        ),
      );
    },
    (error, stack) {
      currentStore?.record('unhandled_failure', {
        'category': categoryOf(error),
        ...diagnosticFields(error, stack),
      });
      currentStore?.status('failed', category: categoryOf(error));
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        // Third-party packages may print URLs in exceptions. The public report is
        // the only diagnostic channel; never forward raw plugin/browser output.
      },
    ),
  );
}

class ProofApp extends StatefulWidget {
  final ProofStore store;
  final String repositoryRoot;
  final bool offline, autorun, vkAuto;
  const ProofApp({
    super.key,
    required this.store,
    required this.repositoryRoot,
    required this.offline,
    required this.autorun,
    this.vkAuto = false,
  });
  @override
  State<ProofApp> createState() => _ProofAppState();
}

class _ProofAppState extends State<ProofApp> {
  final webKey = GlobalKey();
  final navigationKey = GlobalKey<NavigatorState>();
  InAppWebViewController? controller;
  WebViewEnvironment? environment;
  ProofBrowser? nativeBrowser;
  Completer<void>? pageReady;
  String message = 'Preparing Flutter WebView';
  bool browserReady = false,
      busy = false,
      fixtureMode = true,
      resourceSeen = false;
  bool offline = false, musicPage = false;
  final musicNavigation = MusicNavigation();
  bool autoRequested = false, initialNavigation = false;
  int browserGeneration = 0, fixturePort = 0;
  Timer? commands;
  String? lastNonce;
  VkProof? vk;
  Player? audiblePlayer;
  ProofStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    offline = widget.offline;
    final consumed = File('${store.directory.path}/control-consumed.json');
    if (consumed.existsSync()) {
      try {
        lastNonce = jsonDecode(consumed.readAsStringSync())['nonce'];
      } catch (_) {}
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (offline) {
        await perform(() => runOfflineProof(store));
        return;
      }
      await perform(() => prepareBrowser(real: widget.vkAuto));
    });
    commands = Timer.periodic(
      const Duration(seconds: 1),
      (_) => checkCommand(),
    );
  }

  void update(String text) {
    if (mounted) {
      setState(() {
        message = text;
      });
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
    });
    try {
      await action();
      if (offline) {
        update('Offline decode, SQLite persistence, playback and seek passed');
      }
    } catch (error, stack) {
      final category = categoryOf(error);
      if (![
        'private_signin_required',
        'music_page_required',
        'webview_page_timeout',
        'webview_navigation_failed',
      ].contains(category)) {
        autoRequested = false;
      }
      store.record('operation_failed', {
        'category': category,
        ...diagnosticFields(error, stack),
      });
      store.status('failed', category: category);
      update('Test stopped: $category');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> prepareBrowser({required bool real}) async {
    if (Platform.isWindows) {
      await nativeBrowser?.close();
      controller = null;
      final profile = real
          ? '${widget.repositoryRoot}/.local/vk-proof/app-profile/flutter-webview'
          : '${store.directory.path}/synthetic-webview';
      try {
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: profile),
        );
      } catch (_) {
        throw ProofFailure(
          real
              ? 'private_profile_requires_normal_launch'
              : 'webview_environment_failed',
        );
      }
    }
    fixtureMode = !real;
    if (Platform.isWindows) {
      nativeBrowser = ProofBrowser(
        environment: environment,
        created: (view) {
          controller = view;
          store.record('native_browser_created', {'passed': true});
          Future<void>.delayed(const Duration(milliseconds: 500), () async {
            if (widget.autorun && fixtureMode) await perform(selfTest);
            if (widget.vkAuto && !fixtureMode && !initialNavigation) {
              initialNavigation = true;
              autoRequested = true;
              await perform(() => visit(Uri.parse('https://vk.ru/audios')));
            }
          });
        },
        errored: (error) {
          store.record('native_browser_error', {
            'category': 'webview_navigation_failed',
            'attempt': error.type.toNativeValue(),
          });
          if (pageReady != null && !pageReady!.isCompleted) {
            pageReady!.completeError(
              const ProofFailure('webview_navigation_failed'),
            );
          }
        },
        started: (_) {
          store.record('native_browser_started');
          musicPage = false;
          vk?.pageChanged();
        },
        loaded: (uri) {
          store.record('native_browser_loaded');
          observePage(uri);
          if (pageReady != null && !pageReady!.isCompleted) {
            pageReady!.complete();
          }
          if (mounted) setState(() {});
        },
        historyChanged: observePage,
        intercept: (request) async {
          if (fixtureMode &&
              request.url.host == '127.0.0.1' &&
              request.url.port == fixturePort) {
            resourceSeen = true;
          } else if (!fixtureMode && musicPage) {
            vk?.observe(Uri.parse(request.url.toString()));
          }
          return null;
        },
        navigate: (action) async {
          final uri = action.request.url;
          if (uri == null ||
              uri.scheme == 'about' ||
              fixtureMode &&
                  uri.host == '127.0.0.1' &&
                  uri.port == fixturePort) {
            return NavigationActionPolicy.ALLOW;
          }
          return uri.scheme == 'https' &&
                  ['vk.com', 'vk.ru'].any(
                    (host) => uri.host == host || uri.host.endsWith('.$host'),
                  )
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
      );
      await nativeBrowser!.openUrlRequest(
        urlRequest: URLRequest(url: WebUri('about:blank')),
        settings: InAppBrowserClassSettings(
          webViewSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldInterceptRequest: true,
            useShouldOverrideUrlLoading: false,
            mediaPlaybackRequiresUserGesture: false,
            supportMultipleWindows: true,
            javaScriptCanOpenWindowsAutomatically: true,
          ),
        ),
      );
    }
    setState(() {
      browserGeneration++;
      browserReady = true;
    });
    update(
      real
          ? 'Complete VK sign-in privately. Music tests resume on a recognized music page.'
          : 'Flutter WebView ready',
    );
  }

  void observePage(WebUri? uri) {
    final wasMusic = musicPage;
    musicNavigation.observe(uri == null ? null : Uri.tryParse(uri.toString()));
    musicPage = musicNavigation.isMusic;
    if (wasMusic && !musicPage) vk?.pageChanged();
    if (mounted && wasMusic != musicPage) setState(() {});
  }

  Future<bool> refreshMusicPage() async {
    if (fixtureMode || offline || controller == null) return false;
    final ready = await musicNavigation.refresh(
      readUrl: () async {
        final url = await controller!.getUrl();
        return url == null ? null : Uri.tryParse(url.toString());
      },
      openMusic: () async {
        store.record('feed_to_music_navigation');
        await visit(Uri.parse('https://vk.ru/audios'));
      },
    );
    musicPage = ready;
    return ready;
  }

  Future<void> visit(Uri url) async {
    if (url.host == '127.0.0.1') {
      fixtureMode = true;
      fixturePort = url.port;
      resourceSeen = false;
    }
    pageReady = Completer<void>();
    store.record('navigation_requested');
    await controller!.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
    store.record('navigation_dispatched');
    await pageReady!.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => throw const ProofFailure('webview_page_timeout'),
    );
  }

  Future<dynamic> evaluate(String script) async {
    if (controller == null) throw const ProofFailure('webview_not_ready');
    final result = await controller!.callAsyncJavaScript(
      functionBody: 'return ($script);',
    );
    if (result == null || result.error != null) {
      throw const ProofFailure('music_script_failed');
    }
    return result.value;
  }

  Future<void> tap(double x, double y) async {
    if (!fixtureMode && !musicPage) {
      throw const ProofFailure('private_signin_required');
    }
    final viewport = decodeMap(
      await evaluate(
        'JSON.stringify({w:window.innerWidth,h:window.innerHeight})',
      ),
    );
    final w = (viewport['w'] as num).toDouble(),
        h = (viewport['h'] as num).toDouble();
    if (x < 0 || y < 0 || x >= w || y >= h || w <= 0 || h <= 0) {
      throw const ProofFailure('play_control_outside_viewport');
    }
    if (Platform.isWindows) {
      // Only reached for a synthetic page or an already guarded music control.
      await nativeBrowser?.show();
      await controller!.callDevToolsProtocolMethod(
        methodName: 'Page.bringToFront',
      );
      for (final type in ['mouseMoved', 'mousePressed', 'mouseReleased']) {
        if (!fixtureMode && !musicPage) {
          throw const ProofFailure('private_signin_required');
        }
        await controller!.callDevToolsProtocolMethod(
          methodName: 'Input.dispatchMouseEvent',
          parameters: {
            'type': type,
            'x': x,
            'y': y,
            'button': type == 'mouseMoved' ? 'none' : 'left',
            'clickCount': type == 'mouseMoved' ? 0 : 1,
          },
        );
        if (type == 'mouseMoved') {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      return;
    }
    final box = webKey.currentContext!.findRenderObject() as RenderBox;
    final position = box.localToGlobal(
      Offset(x * box.size.width / w, y * box.size.height / h),
    );
    final kind = Platform.isAndroid
        ? PointerDeviceKind.touch
        : PointerDeviceKind.mouse;
    final binding = WidgetsBinding.instance;
    binding.handlePointerEvent(
      PointerHoverEvent(position: position, kind: kind),
    );
    await Future<void>.delayed(const Duration(milliseconds: 75));
    if (!fixtureMode && !musicPage) {
      throw const ProofFailure('private_signin_required');
    }
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: 17,
        position: position,
        kind: kind,
        buttons: kPrimaryMouseButton,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 75));
    binding.handlePointerEvent(
      PointerUpEvent(pointer: 17, position: position, kind: kind),
    );
  }

  Future<void> selfTest() async {
    if (controller == null) throw const ProofFailure('webview_not_ready');
    update(
      'Running shared Flutter browser, SQLite, encrypted HLS and offline checks',
    );
    await runFixtureProof(
      store,
      visit,
      evaluate,
      tap,
      sawResource: () => resourceSeen,
    );
    await checkReferenceSample(store, widget.repositoryRoot);
    update('Online checks passed. Offline restart is pending.');
    if (Platform.isWindows) {
      await restartOffline();
    }
  }

  Future<void> connect() async {
    offline = false;
    autoRequested = true;
    await prepareBrowser(real: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await visit(Uri.parse('https://vk.ru/audios'));
  }

  Future<void> runVk() async {
    if (!await refreshMusicPage()) {
      throw const ProofFailure('music_page_required');
    }
    vk ??= VkProof(
      store,
      evaluate,
      tap,
      () => musicPage,
      update,
      () => visit(Uri.parse('about:blank')),
      restartOffline,
    );
    await vk!.run();
  }

  Future<void> restartOffline() async {
    if (Platform.isWindows) {
      await Process.start(
        Platform.resolvedExecutable,
        ['--offline'],
        workingDirectory: widget.repositoryRoot,
        mode: ProcessStartMode.detached,
      );
      exit(0);
    }
  }

  Future<void> restartVk() async {
    if (!Platform.isWindows) throw const ProofFailure('restart_windows_only');
    final executable = selectProofRestartExecutable(widget.repositoryRoot);
    autoRequested = false;
    store.record('flutter_restart_requested', {'phase': 'vk'});
    store.status('restarting');
    await audiblePlayer?.dispose();
    await nativeBrowser?.close();
    controller = null;
    // Clear only the public test checkpoint; the app keeps its own session.
    await File('${store.directory.path}/resume.json')
        .writeAsString(jsonEncode({'phase': 'finished'}));
    await Process.start(
      executable,
      ['--vk-auto'],
      workingDirectory: widget.repositoryRoot,
      mode: ProcessStartMode.detached,
    );
    store.close();
    exit(0);
  }

  void checkCommand() {
    if (!busy && autoRequested && !fixtureMode && !offline) {
      perform(() async {
        // Polling also covers hosts that omit SPA history notifications.
        if (await refreshMusicPage()) {
          autoRequested = false;
          await runVk();
        }
      });
    }
    final file = File('${store.directory.path}/control.json');
    try {
      if (!file.existsSync() || file.lengthSync() > 1024) return;
      final command = parseControl(file.readAsStringSync(), lastNonce);
      if (command == null || busy && command.$1 != 'stop') return;
      lastNonce = command.$2;
      File('${store.directory.path}/control-consumed.json')
          .writeAsStringSync(jsonEncode({'nonce': lastNonce}));
      switch (command.$1) {
        case 'selftest':
          perform(selfTest);
        case 'run':
          perform(runVk);
        case 'restart':
          perform(restartVk);
        case 'stop':
          vk?.cancelled = true;
          autoRequested = false;
      }
    } catch (_) {
      store.record('control_unavailable');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigationKey,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('Ownsemble — Flutter feasibility')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(message),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: busy || offline || !browserReady
                          ? null
                          : () => perform(selfTest),
                      child: const Text('Run synthetic tests'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => perform(connect),
                      child: const Text('Connect VK privately'),
                    ),
                    FilledButton(
                      onPressed: busy || !browserReady || fixtureMode || offline
                          ? null
                          : () => perform(runVk),
                      child: const Text('Run VK proof'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final asset = store
                            .assets()
                            .where((a) => !a.id.startsWith('900000000000001_'))
                            .firstOrNull;
                        if (asset == null) return;
                        audiblePlayer ??= newProofPlayer();
                        await openLocalAudio(audiblePlayer!, asset.entry);
                      },
                      child: const Text('Listen to cached sample'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: browserReady && !offline && !Platform.isWindows
                ? SizedBox(key: webKey, child: buildWebView())
                : const Center(child: Text('Local audio mode')),
          ),
        ],
      ),
    ),
  );

  Widget buildWebView() => InAppWebView(
    key: ValueKey(browserGeneration),
    webViewEnvironment: environment,
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      useShouldInterceptRequest: true,
      useShouldOverrideUrlLoading: true,
      mediaPlaybackRequiresUserGesture: false,
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
    ),
    onWebViewCreated: (view) {
      controller = view;
      if (widget.autorun && fixtureMode) {
        Future<void>.delayed(
          const Duration(milliseconds: 500),
          () => perform(selfTest),
        );
      }
      if (widget.vkAuto && !fixtureMode && !initialNavigation) {
        initialNavigation = true;
        autoRequested = true;
        Future<void>.delayed(
          const Duration(milliseconds: 500),
          () => perform(() => visit(Uri.parse('https://vk.ru/audios'))),
        );
      }
    },
    onLoadStart: (_, uri) {
      musicPage = false;
      vk?.pageChanged();
    },
    onLoadStop: (_, uri) async {
      observePage(uri);
      if (pageReady != null && !pageReady!.isCompleted) pageReady!.complete();
      if (mounted) setState(() {});
    },
    onUpdateVisitedHistory: (_, uri, _) => observePage(uri),
    shouldOverrideUrlLoading: (_, navigation) async {
      final uri = navigation.request.url;
      if (uri == null ||
          uri.scheme == 'about' ||
          fixtureMode && uri.host == '127.0.0.1' && uri.port == fixturePort) {
        return NavigationActionPolicy.ALLOW;
      }
      return uri.scheme == 'https' &&
              [
                'vk.com',
                'vk.ru',
              ].any((s) => uri.host == s || uri.host.endsWith('.$s'))
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
    shouldInterceptRequest: (_, request) async {
      if (offline) {
        return WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Offline',
          data: Uint8List(0),
        );
      }
      if (fixtureMode) {
        if (request.url.host == '127.0.0.1' &&
            request.url.port == fixturePort) {
          resourceSeen = true;
        }
      } else if (musicPage) {
        vk?.observe(Uri.parse(request.url.toString()));
      }
      return null;
    },
    onPermissionRequest: (_, request) async => PermissionResponse(
      resources: request.resources,
      action: PermissionResponseAction.DENY,
    ),
    onCreateWindow: (_, action) async {
      if (fixtureMode || offline) return false;
      unawaited(
        showDialog<void>(
          context: navigationKey.currentContext!,
          builder: (context) => Dialog(
            child: SizedBox(
              width: 850,
              height: 700,
              child: InAppWebView(
                windowId: action.windowId,
                webViewEnvironment: environment,
                initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
                onCloseWindow: (_) {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                },
              ),
            ),
          ),
        ),
      );
      return true;
    },
  );
  @override
  void dispose() {
    commands?.cancel();
    audiblePlayer?.dispose();
    super.dispose();
  }
}
