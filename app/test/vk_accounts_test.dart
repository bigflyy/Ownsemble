import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/vk_accounts.dart';
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

/// A client whose token depends on the session value: "good" is user 42,
/// "good-7" user 7, "bad" is refused.
class FakeClient extends VkClient {
  FakeClient(this.sessionValue) : super(const []);

  final String sessionValue;
  static var tokenRequests = 0;
  static Object? failure;
  var closed = false;

  @override
  int get userId => switch (sessionValue) {
    'anonymous' => 0,
    final value when value.startsWith('good-') => int.parse(value.substring(5)),
    _ => 42,
  };

  @override
  Future<void> ensureToken() async {
    tokenRequests++;
    final error = failure;
    if (error != null) throw error;
    if (sessionValue.startsWith('bad')) {
      throw VkException('web_token refused: type=error');
    }
  }

  @override
  void close() => closed = true;
}

class MemorySessions implements VkSessionVault {
  /// Sessions by id, as the vault's files would be.
  final saved = <String, SavedSession>{};

  /// A session from before there could be several: nobody knows whose it is.
  void addSingle(List<SessionCookie> cookies) =>
      saved['single'] = SavedSession('single', null, cookies);

  @override
  List<SavedSession> load() => saved.values.toList();

  @override
  String save(String account, List<SessionCookie> cookies) {
    saved[account] = SavedSession(account, account, cookies);
    return account;
  }

  @override
  String adopt(SavedSession session, String account) {
    saved.remove(session.id);
    return save(account, session.cookies);
  }

  @override
  void remove(String id) => saved.remove(id);
}

void main() {
  late FakeWindow window;
  late MemorySessions sessions;

  VkAccounts account() => VkAccounts(
    vault: sessions,
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
    sessions.save('42', [session('good')]);
    final vk = account();
    expect(vk.loggedIn, isTrue);
    expect(vk.sessions.single.cookies, hasLength(1));
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
    expect(sessions.saved['42']!.cookies, hasLength(2));
    expect(window.closes, 1);
    expect(vk.logins, 1);
  });

  test('a cookie VK does not accept keeps the login open', () async {
    final vk = account();
    final login = vk.logIn();
    window.cookiesNow = [session('bad')];
    await watch();
    expect(vk.loggedIn, isFalse);
    expect(sessions.saved, isEmpty);
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
    expect(sessions.saved, isEmpty);
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
    sessions.save('42', [session('good')]);
    final vk = account();
    var notified = 0;
    vk.addListener(() => notified++);
    vk.logOut('42');

    expect(vk.loggedIn, isFalse);
    expect(vk.sessions, isEmpty);
    expect(sessions.saved, isEmpty);
    expect(notified, 1);
  });

  group('several accounts', () {
    test('a second login adds an account', () async {
      sessions.save('7', [session('good-7')]);
      final vk = account();
      final login = vk.logIn();
      window.cookiesNow = [session('good')];
      expect(await login, isTrue);

      expect(vk.sessions.map((s) => s.account), ['7', '42']);
      expect(sessions.saved.keys, unorderedEquals(['7', '42']));
    });

    test('each account has its own client', () async {
      sessions
        ..save('7', [session('good-7')])
        ..save('42', [session('good')]);
      final vk = account();
      expect((vk.clientFor('7')! as FakeClient).sessionValue, 'good-7');
      expect((vk.clientFor('42')! as FakeClient).sessionValue, 'good');
    });

    test('an account that is logged out has no client', () {
      sessions.save('7', [session('good-7')]);
      final vk = account();
      expect(vk.clientFor('42'), isNull);
      expect(vk.hasSession('42'), isFalse);
      expect(vk.hasSession('7'), isTrue);
    });

    test('logging in as an account again replaces its session', () async {
      sessions
        ..save('7', [session('bad-old')])
        ..save('42', [session('good')]);
      final vk = account();
      final old = vk.clientFor('7')! as FakeClient;
      final login = vk.logIn();
      window.cookiesNow = [session('good-7')];
      expect(await login, isTrue);

      expect(vk.sessions.map((s) => s.account), ['7', '42']);
      expect((vk.clientFor('7')! as FakeClient).sessionValue, 'good-7');
      expect(old.closed, isTrue);
      expect(sessions.saved['7']!.cookies.single.value, 'good-7');
    });

    test('logging out of one leaves the other', () {
      sessions
        ..save('7', [session('good-7')])
        ..save('42', [session('good')]);
      final vk = account();
      final gone = vk.clientFor('7')! as FakeClient;
      vk.logOut('7');

      expect(vk.sessions.single.account, '42');
      expect(sessions.saved.keys, ['42']);
      expect(gone.closed, isTrue);
    });
  });

  group('a session saved before there could be several', () {
    test('stands in for its account until VK says whose it is', () {
      sessions.addSingle([session('good')]);
      final vk = account();
      expect(vk.sessions.single.account, isNull);
      expect(vk.clientFor('42'), isNotNull);
    });

    test('becomes the account VK names', () async {
      sessions.addSingle([session('good')]);
      final vk = account();
      var notified = 0;
      vk.addListener(() => notified++);
      await vk.identify();

      expect(vk.sessions.single.account, '42');
      expect(sessions.saved.keys, ['42']);
      expect(notified, 1);
    });

    test('stays as it is while VK cannot be reached', () async {
      sessions.addSingle([session('good')]);
      final vk = account();
      FakeClient.failure = const SocketException('no route');
      await vk.identify();

      expect(vk.sessions.single.account, isNull);
      expect(sessions.saved.keys, ['single']);
    });

    test('goes when the account has a newer session', () async {
      sessions
        ..save('42', [session('good')])
        ..addSingle([session('good')]);
      final vk = account();
      await vk.identify();

      expect(vk.sessions.single.account, '42');
      expect(sessions.saved.keys, ['42']);
    });
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

    test('the folder keeps one encrypted file per account', () {
      final folder = ProtectedSessionFolder(dir.path);
      expect(folder.save('7', cookies), '7');
      folder.save('42', cookies.reversed.toList());

      final loaded = ProtectedSessionFolder(dir.path).load();
      expect(loaded.map((s) => s.account), unorderedEquals(['7', '42']));
      final file = File(p.join(dir.path, 'sessions', '7.dpapi'));
      expect(
        String.fromCharCodes(file.readAsBytesSync()),
        isNot(contains('remixsid')),
      );
    });

    test('the single file of an earlier build loads with no owner', () {
      final single = File(p.join(dir.path, 'session.dpapi'));
      ProtectedSessionFile(single).save(cookies);

      final folder = ProtectedSessionFolder(dir.path);
      final saved = folder.load().single;
      expect(saved.account, isNull);
      expect(saved.cookies.first.value, 'значение-сессии');
    });

    test('adopting the single file moves it into the folder', () {
      final single = File(p.join(dir.path, 'session.dpapi'));
      ProtectedSessionFile(single).save(cookies);
      final folder = ProtectedSessionFolder(dir.path);

      expect(folder.adopt(folder.load().single, '7'), '7');

      expect(single.existsSync(), isFalse);
      expect(folder.load().single.account, '7');
    });

    test('a damaged file in the folder counts as no session', () {
      final folder = ProtectedSessionFolder(dir.path)..save('7', cookies);
      File(p.join(dir.path, 'sessions', '42.dpapi'))
          .writeAsBytesSync([1, 2, 3, 4]);
      expect(folder.load().single.account, '7');
    });

    test('removing forgets one session', () {
      final folder = ProtectedSessionFolder(dir.path)
        ..save('7', cookies)
        ..save('42', cookies);
      folder.remove('7');
      expect(folder.load().single.account, '42');
    });

    test('test session files are read, never written or deleted', () {
      final first = File(p.join(dir.path, 'session.json'))
        ..writeAsStringSync(SessionCookie.listToJson(cookies));
      final second = File(p.join(dir.path, 'session-2.json'))
        ..writeAsStringSync(SessionCookie.listToJson(cookies));
      final files = PlainSessionFiles([first, second]);
      final saved = files.load();
      expect(saved, hasLength(2));
      expect(saved.first.account, isNull);

      expect(files.adopt(saved.first, '7'), saved.first.id);
      files.remove(saved.first.id);
      expect(files.load(), hasLength(1));
      expect(first.existsSync(), isTrue);

      final added = files.save('9', cookies);
      expect(files.load().last.account, '9');
      files.remove(added);
      expect(files.load(), hasLength(1));
    });
  });
}
