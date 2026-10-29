import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../media/audio_policy.dart';

/// App-internal IPC only. No socket/debugging port or cookie export is exposed.
abstract interface class BrowserBridge {
  Stream<Map<String, dynamic>> get events;
  Future<dynamic> request(String method, Map<String, dynamic> arguments);
  void notify(Map<String, dynamic> message);
  Future<void> close();
}

class ProcessBrowserBridge implements BrowserBridge {
  final Process _process;
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _pending = <int, Completer<dynamic>>{};
  int _sequence = 0;
  bool _ended = false, _closing = false;
  ProcessBrowserBridge(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive, onError: (Object _) => _failed(), onDone: _failed);
    // Native diagnostics must not persist URLs, console text or auth responses.
    _process.stderr.drain<void>().catchError((Object _) {});
    _process.exitCode.then((_) => _failed());
  }
  static Future<BrowserBridge> start(
    String executable,
    String profilePath,
  ) async => ProcessBrowserBridge(
    await Process.start(executable, ['--profile-path=$profilePath']),
  );
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  void _receive(String line) {
    if (_ended) return;
    try {
      if (line.length > 4 * 1024 * 1024) throw const FormatException();
      final message = jsonDecode(line);
      if (message is! Map<String, dynamic>) throw const FormatException();
      final id = message['id'];
      if (id is int) {
        final pending = _pending.remove(id);
        if (pending == null) return;
        if (message['ok'] == true) {
          pending.complete(message['value']);
        } else {
          final category = message['error'];
          pending.completeError(
            ProofFailure(
              _allowedErrors.contains(category)
                  ? category as String
                  : 'browser_native_failed',
            ),
          );
        }
      } else if (_allowedEvents.contains(message['event'])) {
        if (message['browser'] is! int ||
            message['uri'] != null && message['uri'] is! String ||
            message['kind'] != null && message['kind'] is! String ||
            message['event'] == 'navigation' && message['token'] is! int) {
          throw const FormatException();
        }
        _events.add({
          for (final key in const ['event', 'browser', 'uri', 'kind', 'token'])
            if (message.containsKey(key)) key: message[key],
        });
      } else {
        throw const FormatException();
      }
    } catch (_) {
      _failed();
      _process.kill();
    }
  }

  void _failed() {
    if (_ended) return;
    _ended = true;
    for (final pending in _pending.values) {
      pending.completeError(const ProofFailure('browser_closed'));
    }
    _pending.clear();
    _events.add({'event': 'bridge_closed'});
  }

  @override
  Future<dynamic> request(String method, Map<String, dynamic> arguments) async {
    if (_ended || _closing && method != 'shutdown') {
      throw const ProofFailure('browser_closed');
    }
    final id = ++_sequence;
    final pending = Completer<dynamic>();
    _pending[id] = pending;
    try {
      _process.stdin.writeln(
        jsonEncode({'id': id, 'method': method, ...arguments}),
      );
      return await pending.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const ProofFailure('browser_native_timeout');
    } on ProofFailure {
      rethrow;
    } catch (_) {
      throw const ProofFailure('browser_closed');
    } finally {
      _pending.remove(id);
    }
  }

  @override
  void notify(Map<String, dynamic> message) {
    if (!_ended && !_closing) _process.stdin.writeln(jsonEncode(message));
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    if (!_ended) {
      try {
        await request('shutdown', {}).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      _process.kill();
    }
    _failed();
  }

  static const _allowedEvents = {
    'navigation',
    'started',
    'loaded',
    'history',
    'error',
    'closed',
    'request',
  };
  static const _allowedErrors = {
    'cancelled',
    'browser_closed',
    'browser_capability_missing',
    'browser_mute_unavailable',
    'browser_sandbox_unavailable',
    'browser_navigation_blocked',
    'browser_native_failed',
    'music_script_failed',
    'browser_native_timeout',
  };
}
