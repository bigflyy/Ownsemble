import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'vk_client.dart';

/// VK's page where a login starts.
const vkLoginUrl = 'https://vk.ru/';

/// The login window could not open; [reason] is fit for a message.
class LoginWindowException implements Exception {
  LoginWindowException(this.reason);

  final String reason;

  @override
  String toString() => 'LoginWindowException: $reason';
}

/// The window the user logs in with, as the account controller sees it.
abstract interface class LoginWindow {
  /// Opens the window, or shows it if it is open already. Throws
  /// [LoginWindowException].
  Future<void> open();

  /// The cookies the page has right now.
  Future<List<SessionCookie>> cookies();

  Future<void> close();

  /// Called when the window is gone, whoever closed it.
  set onClosed(void Function() listener);
}

/// The native window (windows/runner/vk_login_window.h): WebView2 in private
/// mode with VK's own login page.
class NativeLoginWindow implements LoginWindow {
  NativeLoginWindow({required this.userDataDir, this.seedFile}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed') _onClosed?.call();
    });
  }

  static const _channel = MethodChannel('ownsemble/vk_login');

  /// Folder for WebView2's own files. Private mode keeps no session there.
  final String userDataDir;

  /// A session file whose cookies are set before the page loads, if it
  /// exists when the window opens. Only the agent's login check passes one,
  /// because the agent never types into a login page.
  final File? seedFile;

  void Function()? _onClosed;

  @override
  set onClosed(void Function() listener) => _onClosed = listener;

  @override
  Future<void> open() async {
    final seed = seedFile;
    final seedCookies = seed != null && seed.existsSync()
        ? SessionCookie.loadAll(seed)
        : null;
    try {
      await _channel.invokeMethod<bool>('open', {
        'url': vkLoginUrl,
        'userDataDir': userDataDir,
        if (seedCookies != null)
          'cookies': [
            for (final cookie in seedCookies)
              {
                'name': cookie.name,
                'value': cookie.value,
                'domain': cookie.domain,
              },
          ],
      });
    } on PlatformException catch (error) {
      throw LoginWindowException(switch (error.code) {
        'closed' => 'the login window was closed',
        'webview_missing' =>
          'Windows has no WebView2 Runtime; install it from Microsoft',
        _ => 'could not open the login window',
      });
    } on MissingPluginException {
      throw LoginWindowException('there is no login window on this system');
    }
  }

  @override
  Future<List<SessionCookie>> cookies() async {
    final list = await _channel.invokeListMethod<Object?>('cookies') ?? [];
    return [
      for (final entry in list.cast<Map<Object?, Object?>>())
        SessionCookie(
          entry['name'] as String,
          entry['value'] as String,
          entry['domain'] as String,
        ),
    ];
  }

  /// Host and path of the current page; for the agent's login check.
  Future<String> location() async =>
      await _channel.invokeMethod<String>('location') ?? '';

  /// Saves a PNG of the page to [path]; for the agent's login check.
  Future<bool> capture(String path) async =>
      await _channel.invokeMethod<bool>('capture', {'path': path}) ?? false;

  @override
  Future<void> close() => _channel.invokeMethod<void>('close');
}
