import 'dart:async';
import 'dart:io';

import '../../contracts/music_browser.dart';
import '../../media/audio_policy.dart';
import 'browser_bridge.dart';

/// Owns one dedicated native helper/session and independent document IDs.
class LinuxMusicBrowserFactory implements MusicBrowserFactory {
  final String profilePath, executablePath;
  final Future<BrowserBridge> Function()? launch;
  BrowserBridge? _bridge;
  Future<void>? _preparing, _releasing;
  final _pages = <int, LinuxMusicBrowser>{};
  int _sequence = 0;
  LinuxMusicBrowserFactory(
    this.profilePath, {
    String? executablePath,
    this.launch,
  }) : executablePath =
           executablePath ??
           '${File(Platform.resolvedExecutable).parent.path}/lib/ownsemble_browser/ownsemble_browser';
  @override
  Set<BrowserCapability> get capabilities =>
      launch != null || Platform.isLinux && File(executablePath).existsSync()
      ? Set.unmodifiable(BrowserCapability.values)
      : const {};
  @override
  bool get prepared => _bridge != null;
  @override
  Future<void> prepare() {
    requireMusicBrowserCapabilities(this);
    if (prepared) return Future.value();
    return _preparing ??= () async {
      BrowserBridge? bridge;
      try {
        await _releasing;
        bridge =
            await (launch?.call() ??
                ProcessBrowserBridge.start(executablePath, profilePath));
        final hello = await bridge.request('hello', {});
        if (hello is! Map ||
            hello['protocol'] != 1 ||
            hello['audio_capture_required'] != true ||
            hello['sandbox_requested'] != true) {
          throw const ProofFailure('browser_capability_missing');
        }
        _bridge = bridge;
        final active = bridge;
        bridge.events.listen((event) {
          if (identical(_bridge, active)) _event(event);
        });
      } catch (_) {
        await bridge?.close();
        rethrow;
      } finally {
        _preparing = null;
      }
    }();
  }

  void _event(Map<String, dynamic> event) {
    if (event['event'] == 'bridge_closed') {
      _bridge = null;
      final pages = _pages.values.toList();
      _pages.clear();
      for (final page in pages) {
        page._exited();
      }
      return;
    }
    final page = _pages[event['browser']];
    if (event['event'] == 'navigation') {
      var allow = false;
      if (page != null && !page._closed) {
        try {
          allow = page.events.allowNavigation(
            Uri.tryParse(event['uri'] as String? ?? ''),
          );
        } catch (_) {}
      }
      _bridge?.notify({'decision': event['token'], 'allow': allow});
    } else {
      page?._event(event);
    }
  }

  @override
  MusicBrowser create(BrowserEvents events) {
    if (!prepared) throw const ProofFailure('browser_not_prepared');
    final page = LinuxMusicBrowser._(this, ++_sequence, events, _bridge!);
    _pages[page.id] = page;
    return page;
  }

  Future<void> _remove(LinuxMusicBrowser page) async {
    _pages.remove(page.id);
    if (_pages.isNotEmpty || _bridge == null) return;
    final bridge = _bridge!;
    _bridge = null;
    final releasing = bridge.close();
    _releasing = releasing;
    try {
      await releasing;
    } finally {
      if (identical(_releasing, releasing)) _releasing = null;
    }
  }
}

class LinuxMusicBrowser implements MusicBrowser {
  final LinuxMusicBrowserFactory factory;
  final BrowserBridge bridge;
  final int id;
  final BrowserEvents events;
  bool _closed = false, _opened = false;
  void Function(BrowserRequest)? _observed;
  LinuxMusicBrowser._(this.factory, this.id, this.events, this.bridge);
  Future<dynamic> _call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (_closed) throw const ProofFailure('cancelled');
    return bridge.request(method, {'browser': id, ...arguments});
  }

  @override
  Future<void> open(Uri uri) async {
    if (_opened) throw const ProofFailure('browser_already_open');
    try {
      final result = await _call('create');
      if (_closed) throw const ProofFailure('cancelled');
      _opened = true;
      if (result is! Map || result['audio_isolated'] != true) {
        throw const ProofFailure('browser_mute_unavailable');
      }
      if (result['sandboxed'] != true) {
        throw const ProofFailure('browser_sandbox_unavailable');
      }
      await navigate(uri);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> navigate(Uri uri) async {
    if (_closed) throw const ProofFailure('cancelled');
    if (!events.allowNavigation(uri)) {
      throw const ProofFailure('browser_navigation_blocked');
    }
    await _call('navigate', {'uri': uri.toString()});
  }

  @override
  Future<void> reload() async {
    await _call('reload');
  }

  @override
  Future<Uri?> currentUrl() async =>
      Uri.tryParse(await _call('url') as String? ?? '');
  @override
  Future<dynamic> evaluate(String expression) =>
      _call('evaluate', {'expression': expression});
  @override
  Future<void> addDocumentStartScript(String source) async {
    await _call('script', {'source': source});
  }

  @override
  Future<bool> isAudioIsolated() async => await _call('isolation') == true;
  @override
  Future<void> activate() async {
    await _call('activate');
  }

  @override
  Future<void> pointer(BrowserPointer event) async {
    await _call('pointer', {
      'phase': event.phase.name,
      'x': event.x,
      'y': event.y,
    });
  }

  @override
  Future<void> observeRequests(void Function(BrowserRequest) observed) async {
    _observed = observed;
  }

  @override
  Future<void> showPrivateSignIn() async {
    await _call('show');
  }

  @override
  Future<void> finishPrivateSignIn() async {
    await _call('finishSignIn');
  }

  @override
  Future<void> hide() async {
    await _call('hide');
  }

  @override
  Future<bool> isHidden() async => await _call('isHidden') == true;
  void _event(Map<String, dynamic> event) {
    if (_closed) return;
    final uri = Uri.tryParse(event['uri'] as String? ?? '');
    switch (event['event']) {
      case 'started':
        events.started(uri);
      case 'loaded':
        events.loaded(uri);
      case 'history':
        events.historyChanged(uri);
      case 'error':
        events.errored();
      case 'closed':
        _exited();
      case 'request':
        events.request(uri);
        final kind = event['kind'];
        _observed?.call(
          BrowserRequest(
            uri,
            kind: const {'Media', 'Fetch', 'XHR', 'Other'}.contains(kind)
                ? kind as String
                : 'non_media',
          ),
        );
    }
  }

  void _exited() {
    if (!_closed) {
      _closed = true;
      events.exited();
      unawaited(factory._remove(this).catchError((Object _) {}));
    }
  }

  @override
  Future<void> close() async {
    if (_closed && !factory._pages.containsKey(id)) return;
    _closed = true;
    try {
      await bridge.request('close', {'browser': id});
    } catch (_) {}
    _opened = false;
    await factory._remove(this);
  }
}
