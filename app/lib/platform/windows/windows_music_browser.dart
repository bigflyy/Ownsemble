import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../contracts/music_browser.dart';
import '../../media/audio_policy.dart';
import 'native_browser.dart';
import 'background_browser.dart';

/// Shares only the plugin's dedicated private environment between independent
/// documents. No profile/cookie inspection or session export API is exposed.
class WindowsMusicBrowserFactory implements MusicBrowserFactory {
  final String profilePath;
  final bool hidden;
  WebViewEnvironment? _environment;
  Future<void>? _preparing;
  WindowsMusicBrowserFactory(this.profilePath, {this.hidden = true});
  @override
  Set<BrowserCapability> get capabilities => Platform.isWindows
      ? Set.unmodifiable(BrowserCapability.values)
      : const {};
  @override
  bool get prepared => _environment != null;
  @override
  Future<void> prepare() {
    requireMusicBrowserCapabilities(this);
    if (prepared) return Future.value();
    return _preparing ??= () async {
      try {
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: profilePath),
        );
      } finally {
        _preparing = null;
      }
    }();
  }

  @override
  MusicBrowser create(BrowserEvents events) {
    if (_environment == null) throw const ProofFailure('browser_not_prepared');
    return WindowsMusicBrowser(_environment!, events, hidden: hidden);
  }
}

class WindowsMusicBrowser implements MusicBrowser {
  late final VkBrowser _browser;
  InAppWebViewController? _view;
  final _ready = Completer<void>();
  bool _closed = false;
  final bool hidden;
  WindowsMusicBrowser(
    WebViewEnvironment environment,
    BrowserEvents events, {
    this.hidden = true,
  }) {
    _browser = VkBrowser(
      environment: environment,
      exited: () {
        _closed = true;
        events.exited();
      },
      created: (view) {
        _view = view;
        if (!_ready.isCompleted) _ready.complete();
        if (_closed) {
          // A close can race native window creation. Dispose a late renderer
          // as soon as the plugin exposes it; never let it navigate/read later.
          unawaited(_browser.close().catchError((Object _) {}));
        }
      },
      started: (uri) => events.started(_uri(uri)),
      loaded: (uri) => events.loaded(_uri(uri)),
      historyChanged: (uri) => events.historyChanged(_uri(uri)),
      errored: (_) => events.errored(),
      intercept: (request) async {
        events.request(_uri(request.url));
        return null;
      },
      navigate: (action) async =>
          events.allowNavigation(_uri(action.request.url))
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL,
    );
  }
  Uri? _uri(WebUri? value) =>
      value == null ? null : Uri.tryParse(value.toString());
  InAppWebViewController get _controller {
    if (_closed || _view == null) throw const ProofFailure('cancelled');
    return _view!;
  }

  @override
  Future<void> open(Uri uri) async {
    final settings = backgroundMusicBrowserSettings();
    settings.browserSettings.hidden = hidden;
    await _browser.openUrlRequest(
      urlRequest: URLRequest(url: WebUri.uri(uri)),
      settings: settings,
    );
    await _ready.future.timeout(const Duration(seconds: 30));
    if (_closed) throw const ProofFailure('cancelled');
  }

  @override
  Future<void> navigate(Uri uri) =>
      _controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
  @override
  Future<void> reload() => _controller.reload();
  @override
  Future<Uri?> currentUrl() async => _uri(await _controller.getUrl());
  @override
  Future<dynamic> evaluate(String expression) async {
    final value = await _controller.callAsyncJavaScript(
      functionBody: 'return ($expression);',
    );
    if (value == null || value.error != null) {
      throw const ProofFailure('music_script_failed');
    }
    return value.value;
  }

  @override
  Future<void> addDocumentStartScript(String source) =>
      _controller.addUserScript(
        userScript: UserScript(
          source: source,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
  @override
  Future<bool> isAudioIsolated() async {
    final result = await _controller.callDevToolsProtocolMethod(
      methodName: 'Ownsemble.getAudioMuted',
    );
    final data = result is String ? jsonDecode(result) : result;
    return data is Map && data['muted'] == true;
  }

  @override
  Future<void> activate() => activateBackgroundMusicPage(_controller);
  @override
  Future<void> pointer(BrowserPointer event) async {
    await _controller.callDevToolsProtocolMethod(
      methodName: 'Input.dispatchMouseEvent',
      parameters: {
        'type': switch (event.phase) {
          PointerPhase.move => 'mouseMoved',
          PointerPhase.down => 'mousePressed',
          PointerPhase.up => 'mouseReleased',
        },
        'x': event.x,
        'y': event.y,
        'button': event.phase == PointerPhase.move ? 'none' : 'left',
        'buttons': event.phase == PointerPhase.down ? 1 : 0,
        'pointerType': 'mouse',
        'clickCount': event.phase == PointerPhase.move ? 0 : 1,
      },
    );
  }

  @override
  Future<void> observeRequests(void Function(BrowserRequest) observed) async {
    await _controller.addDevToolsProtocolEventListener(
      eventName: 'Network.requestWillBeSent',
      callback: (data) {
        // Project to URL/type at the platform boundary. Never expose headers,
        // cookies, bodies or authentication responses to the provider.
        if (_closed || data is! Map) {
          return;
        }
        final request = data['request'];
        final value = request is Map ? request['url'] : null;
        if (value is String) {
          observed(
            BrowserRequest(
              Uri.tryParse(value),
              kind: ['Media', 'Fetch', 'XHR', 'Other'].contains(data['type'])
                  ? data['type'] as String
                  : 'non_media',
            ),
          );
        }
      },
    );
    await _controller.callDevToolsProtocolMethod(methodName: 'Network.enable');
  }

  @override
  Future<void> showPrivateSignIn() async {
    _browser.allowAuthPopups = true;
    await _browser.show();
  }

  @override
  Future<void> finishPrivateSignIn() => _browser.finishPrivateSignIn();
  @override
  Future<void> hide() => _browser.hide();
  @override
  Future<bool> isHidden() => _browser.isHidden();
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _browser.close();
  }
}
