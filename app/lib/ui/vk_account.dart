import 'dart:async';

import 'package:flutter/foundation.dart';

import '../vk/vk_client.dart';
import '../vk/vk_login_window.dart';
import '../vk/vk_session.dart';

/// Whether the VK account is logged in, and the login itself.
///
/// A login is finished when VK itself says so: the window's cookies must get
/// a web token. Page addresses and cookie names change; that answer does not.
class VkAccount extends ChangeNotifier {
  VkAccount({
    required this.sessions,
    required this.window,
    VkClient Function(List<SessionCookie> cookies)? clientFor,
    this.checkEvery = const Duration(milliseconds: 1200),
  }) : _clientFor = clientFor ?? VkClient.new {
    window.onClosed = _windowClosed;
    final saved = sessions.load();
    if (saved != null) _adopt(saved);
  }

  /// The cookie that exists only once VK knows who is logged in. Its value
  /// changes at login, which tells when asking for a token is worth it.
  static const sessionCookieName = 'remixsid';

  final VkSessionStore sessions;
  final LoginWindow window;
  final VkClient Function(List<SessionCookie> cookies) _clientFor;

  /// How often the window's cookies are looked at while it is open.
  final Duration checkEvery;

  VkClient? _client;
  List<SessionCookie>? _cookies;
  Completer<bool>? _login;
  Timer? _watch;
  String? _triedSession;
  bool _checking = false;

  /// Talks to VK as the logged-in user; null when logged out.
  VkClient? get client => _client;

  /// The session of the logged-in user; null when logged out.
  List<SessionCookie>? get cookies => _cookies;

  bool get loggedIn => _client != null;

  /// Whether the login window is open.
  bool get loggingIn => _login != null;

  void _adopt(List<SessionCookie> cookies) {
    _cookies = cookies;
    _client = _clientFor(cookies);
  }

  /// Opens the login window and completes when it is over: true when the
  /// user logged in, false when they closed the window. Throws
  /// [LoginWindowException] when the window cannot open.
  Future<bool> logIn() async {
    final running = _login;
    if (running != null) {
      await window.open();
      return running.future;
    }
    final login = _login = Completer<bool>();
    notifyListeners();
    try {
      await window.open();
    } on LoginWindowException {
      _finishLogin(false);
      rethrow;
    }
    _triedSession = null;
    _watch = Timer.periodic(checkEvery, (_) => unawaited(_check()));
    return login.future;
  }

  /// One look at the window's cookies.
  Future<void> _check() async {
    if (_checking || _login == null) return;
    _checking = true;
    VkClient? candidate;
    try {
      final cookies = await window.cookies();
      final session = cookies
          .where((c) => c.name == sessionCookieName && c.value.isNotEmpty)
          .map((c) => c.value)
          .firstOrNull;
      if (session == null || session == _triedSession) return;
      candidate = _clientFor(cookies);
      await candidate.ensureToken();
      if (candidate.userId <= 0 || _login == null) {
        candidate.close();
        _triedSession = session;
        return;
      }
      sessions.save(cookies);
      _cookies = cookies;
      _client = candidate;
      _finishLogin(true);
      await window.close();
    } on Exception {
      // VK refused this session (the login is still going on) or did not
      // answer: the next look tries again.
      candidate?.close();
    } finally {
      _checking = false;
    }
  }

  void _windowClosed() => _finishLogin(false);

  void _finishLogin(bool loggedIn) {
    _watch?.cancel();
    _watch = null;
    final login = _login;
    if (login == null) return;
    _login = null;
    notifyListeners();
    login.complete(loggedIn);
  }

  /// Forgets the session. The library stays; songs stored on disk still play.
  void logOut() {
    sessions.clear();
    _client?.close();
    _client = null;
    _cookies = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }
}
