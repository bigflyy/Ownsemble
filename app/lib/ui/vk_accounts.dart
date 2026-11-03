import 'dart:async';

import 'package:flutter/foundation.dart';

import '../vk/vk_client.dart';
import '../vk/vk_login_window.dart';
import '../vk/vk_session.dart';

/// One logged-in VK account.
class VkAccountSession {
  VkAccountSession({
    required this.id,
    required this.account,
    required this.cookies,
    required this.client,
  });

  /// Which saved session this is, for [VkSessionVault].
  String id;

  /// VK user id; null until VK says whose session this is.
  String? account;
  final List<SessionCookie> cookies;

  /// Talks to VK as this account.
  final VkClient client;
}

/// The logged-in VK accounts, and the login itself.
///
/// A login is finished when VK itself says so: the window's cookies must get
/// a web token. Page addresses and cookie names change; that answer does not.
/// Logging in as an account that is here already replaces its session.
class VkAccounts extends ChangeNotifier {
  VkAccounts({
    required this.vault,
    required this.window,
    VkClient Function(List<SessionCookie> cookies)? clientFor,
    this.checkEvery = const Duration(milliseconds: 1200),
  }) : _clientFor = clientFor ?? VkClient.new {
    window.onClosed = _windowClosed;
    for (final saved in vault.load()) {
      _sessions.add(
        VkAccountSession(
          id: saved.id,
          account: saved.account,
          cookies: saved.cookies,
          client: _clientFor(saved.cookies),
        ),
      );
    }
  }

  /// The cookie that exists only once VK knows who is logged in. Its value
  /// changes at login, which tells when asking for a token is worth it.
  static const sessionCookieName = 'remixsid';

  final VkSessionVault vault;
  final LoginWindow window;
  final VkClient Function(List<SessionCookie> cookies) _clientFor;

  /// How often the window's cookies are looked at while it is open.
  final Duration checkEvery;

  final _sessions = <VkAccountSession>[];
  Completer<bool>? _login;
  Timer? _watch;
  String? _triedSession;
  bool _checking = false;
  int _logins = 0;

  /// The logged-in accounts, oldest first.
  List<VkAccountSession> get sessions => List.unmodifiable(_sessions);

  /// The first account's client; null when logged out.
  VkClient? get client => _sessions.firstOrNull?.client;

  /// Client of the VK user [account]; null when that account is logged out.
  VkClient? clientFor(String? account) => _sessionOf(account)?.client;

  /// Whether the VK user [account] is logged in.
  bool hasSession(String? account) => _sessionOf(account) != null;

  /// The session of [account]. A session whose owner is not known yet stands
  /// in for any account, and any session for a source with no account: [identify]
  /// settles the first within a moment of the start.
  VkAccountSession? _sessionOf(String? account) {
    if (account == null) return _sessions.firstOrNull;
    return _sessions.where((s) => s.account == account).firstOrNull ??
        _sessions.where((s) => s.account == null).firstOrNull;
  }

  bool get loggedIn => _sessions.isNotEmpty;

  /// Whether the login window is open.
  bool get loggingIn => _login != null;

  /// How many logins finished in this run; a change means a new session.
  int get logins => _logins;

  /// Asks VK for a token for every session, and so learns whose each one is. A
  /// session that cannot get one (offline, expired) stays as it is; a session
  /// that turns out to be an account's second one is dropped.
  Future<void> identify() async {
    var changed = false;
    for (final session in sessions) {
      try {
        await session.client.ensureToken();
      } catch (_) {
        // Offline or expired: VK songs fail at play time with a message.
        continue;
      }
      if (session.account != null) continue;
      final account = '${session.client.userId}';
      changed = true;
      if (_sessions.any((other) => other.account == account)) {
        vault.remove(session.id);
        session.client.close();
        _sessions.remove(session);
        continue;
      }
      session.id = vault.adopt(
        SavedSession(session.id, null, session.cookies),
        account,
      );
      session.account = account;
    }
    if (changed) notifyListeners();
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
      _add('${candidate.userId}', cookies, candidate);
      _logins++;
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

  /// Keeps a finished login, in place of the account's older session.
  void _add(String account, List<SessionCookie> cookies, VkClient client) {
    final id = vault.save(account, cookies);
    final older = _sessions.where((s) => s.account == account).firstOrNull;
    final session = VkAccountSession(
      id: id,
      account: account,
      cookies: cookies,
      client: client,
    );
    if (older == null) {
      _sessions.add(session);
    } else {
      older.client.close();
      _sessions[_sessions.indexOf(older)] = session;
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

  /// Forgets the session of [account]. Its songs stay; stored ones still play.
  void logOut(String? account) {
    final session = _sessionOf(account);
    if (session == null) return;
    vault.remove(session.id);
    session.client.close();
    _sessions.remove(session);
    notifyListeners();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }
}
