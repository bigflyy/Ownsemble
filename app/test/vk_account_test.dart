import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/vk_account.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_login_window.dart';
import 'package:ownsemble/vk/vk_session.dart';
import 'package:path/path.dart' as p;

SessionCookie session(String value) =>
    SessionCookie('remixsid', value, '.vk.ru');

/// A window the test fills with cookies, as a page does while the user logs
/// in.
class FakeWindow implements LoginWindow {
  var cookiesNow = <SessionCookie>[];
  var opens = 0;
  var closes = 0;
  Object? openError;
  void Function()? closedListener;

  @override
  set onClosed(void Function() listener) => closedListener = listener;

  @override
  Future<void> open() async {
    opens++;
    final error = openError;
    if (error != null) throw error;
  }

  @override
  Future<List<SessionCookie>> cookies() async => cookiesNow;

  @override
  Future<void> close() async {
    closes++;
    closedListener?.call();
  }

  void userClosesIt() => closedListener?.call();
}

/// A client whose token depends on the session value: "good" is logged in.
class FakeClient extends VkClient {
  FakeClient(this.sessionValue) : super(const []);

  final String sessionValue;
  static var tokenRequests = 0;
  static Object? failure;

  @override
  int get userId => sessionValue == 'anonymous' ? 0 : 42;

  @override
  Future<void> ensureToken() async {
    tokenRequests++;
    final error = failure;
    if (error != null) throw error;
    if (sessionValue.startsWith('bad')) {
      throw VkException('web_token refused: type=error');
    }
  }
}

class MemorySessions implements VkSessionStore {
  MemorySessions([this.saved]);

  List<SessionCookie>? saved;

  @override
  List<SessionCookie>? load() => saved;

  @override
  void save(List<SessionCookie> cookies) => saved = cookies;

  @override
  void clear() => saved = null;
}

void main() {
  late FakeWindow window;
  late MemorySessions sessions;

  VkAccount account() => VkAccount(
    sessions: sessions,
    window: window,
    clientFor: (cookies) =>
        FakeClient(cookies.firstWhere((c) => c.name == 'remixsid').value),
    checkEvery: const Duration(milliseconds: 5),
  );

  /// Lets the watch look at the window a few times.
  Future<void> watch() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  setUp(() {
    window = FakeWindow();
    sessions = MemorySessions();
    FakeClient.tokenRequests = 0;
    FakeClient.failure = null;
  });

  test('a saved session means logged in, without opening a window', () {
    sessions.saved = [session('good')];
    final vk = account();
    expect(vk.loggedIn, isTrue);
    expect(vk.cookies, hasLength(1));
    expect(window.opens, 0);
  });

  test('no saved session means logged out', () {
    final vk = account();
    expect(vk.loggedIn, isFalse);
    expect(vk.client, isNull);
  });

  test('a login ends when VK gives a token: saved, window closed', () async {
    final vk = account();
    final login = vk.logIn();
    await watch();
    expect(vk.loggingIn, isTrue);
    expect(vk.loggedIn, isFalse);

    window.cookiesNow = [session('good'), SessionCookie('p', 'x', '.vk.ru')];
    expect(await login, isTrue);

    expect(vk.loggedIn, isTrue);
    expect(vk.loggingIn, isFalse);
    expect(sessions.saved, hasLength(2));
    expect(window.closes, 1);
  });

  test('a cookie VK does not accept keeps the login open', () async {
    final vk = account();
    final login = vk.logIn();
    window.cookiesNow = [session('bad')];
    await watch();
    expect(vk.loggedIn, isFalse);
    expect(sessions.saved, isNull);
    expect(window.closes, 0);

    window.cookiesNow = [session('good')];
    expect(await login, isTrue);
  });

  test('the same refused session is not sent to VK again and again', () async {
    final vk = account();
    final login = vk.logIn();
    window.cookiesNow = [session('anonymous')];
    await watch();
    expect(FakeClient.tokenRequests, 1);

    window.cookiesNow = [session('good')];
    expect(await login, isTrue);
  });

  test('a dropped connection during the check tries again', () async {
    final vk = account();
    final login = vk.logIn();
    FakeClient.failure = const SocketException('no route');
    window.cookiesNow = [session('good')];
    await watch();
    expect(vk.loggedIn, isFalse);

    FakeClient.failure = null;
    expect(await login, isTrue);
  });

  test('closing the window ends the login without a session', () async {
    final vk = account();
    final login = vk.logIn();
    await watch();
    window.userClosesIt();

    expect(await login, isFalse);
    expect(vk.loggedIn, isFalse);
    expect(vk.loggingIn, isFalse);
    expect(sessions.saved, isNull);
  });

  test('a second click while the window is open only shows it', () async {
    final vk = account();
    final first = vk.logIn();
    final second = vk.logIn();
    await watch();
    expect(window.opens, 2);

    window.cookiesNow = [session('good')];
    expect(await first, isTrue);
    expect(await second, isTrue);
  });

  test('a window that cannot open says so and leaves no login open', () async {
    window.openError = LoginWindowException('no runtime');
    final vk = account();
    await expectLater(vk.logIn(), throwsA(isA<LoginWindowException>()));
    expect(vk.loggingIn, isFalse);
  });

  test('logging out forgets the session', () async {
    sessions.saved = [session('good')];
    final vk = account();
    var notified = 0;
    vk.addListener(() => notified++);
    vk.logOut();

    expect(vk.loggedIn, isFalse);
    expect(vk.cookies, isNull);
    expect(sessions.saved, isNull);
    expect(notified, 1);
  });

  group('session files', () {
    late Directory dir;
    final cookies = [
      const SessionCookie('remixsid', 'значение-сессии', '.vk.ru'),
      const SessionCookie('p', 'second', '.login.vk.ru'),
    ];

    setUp(() => dir = Directory.systemTemp.createTempSync('session'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the protected file round trips and holds no plain text', () {
      final file = File(p.join(dir.path, 'session.dpapi'));
      ProtectedSessionFile(file).save(cookies);

      final bytes = file.readAsBytesSync();
      expect(String.fromCharCodes(bytes), isNot(contains('remixsid')));
      final loaded = ProtectedSessionFile(file).load()!;
      expect(loaded.map((c) => c.name), ['remixsid', 'p']);
      expect(loaded.first.value, 'значение-сессии');
      expect(loaded.last.domain, '.login.vk.ru');
    });

    test('a damaged protected file counts as no session', () {
      final file = File(p.join(dir.path, 'session.dpapi'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      expect(ProtectedSessionFile(file).load(), isNull);
    });

    test('a missing protected file counts as no session', () {
      final file = File(p.join(dir.path, 'session.dpapi'));
      expect(ProtectedSessionFile(file).load(), isNull);
      ProtectedSessionFile(file).clear();
    });

    test('clearing removes the protected file', () {
      final file = File(p.join(dir.path, 'session.dpapi'));
      final sessions = ProtectedSessionFile(file)..save(cookies);
      sessions.clear();
      expect(file.existsSync(), isFalse);
    });

    test('logging out of the test session leaves its file alone', () {
      final file = File(p.join(dir.path, 'session.json'))
        ..writeAsStringSync(SessionCookie.listToJson(cookies));
      final sessions = PlainSessionFile(file);
      expect(sessions.load(), hasLength(2));

      sessions.clear();
      expect(sessions.load(), isNull);
      expect(file.existsSync(), isTrue);
    });
  });
}
