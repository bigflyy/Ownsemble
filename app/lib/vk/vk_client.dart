import 'dart:convert';
import 'dart:io';

/// VK's own public web-client id and API version, as observed on vk.ru.
const webClientId = '6287487';
const apiVersion = '5.289';
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0';

/// One cookie of the saved browser session.
class SessionCookie {
  const SessionCookie(this.name, this.value, this.domain);
  final String name;
  final String value;
  final String domain;

  /// Standard cookie domain matching: ".vk.ru" matches "login.vk.ru".
  bool appliesTo(String host) {
    final bare = domain.startsWith('.') ? domain.substring(1) : domain;
    return host == bare || host.endsWith('.$bare');
  }

  /// Reads the session saved by the login helper (a JSON list of cookies).
  static List<SessionCookie> loadAll(File file) {
    final entries = jsonDecode(file.readAsStringSync(encoding: utf8)) as List;
    return [
      for (final entry in entries.cast<Map<String, dynamic>>())
        SessionCookie(
          entry['name'] as String,
          entry['value'] as String,
          entry['domain'] as String,
        ),
    ];
  }
}

/// Raised when VK answers with an error. Never contains tokens or URLs.
class VkException implements Exception {
  VkException(this.message);
  final String message;
  @override
  String toString() => 'VkException: $message';
}

/// Calls one VK web API method and returns its `response` value.
typedef VkApiCall = Future<Object?> Function(
  String method,
  Map<String, String> params,
);

/// Minimal VK web API client working from a saved browser session.
///
/// Gets a short-lived web token from the session cookies and refreshes it
/// shortly before it expires.
class VkClient {
  VkClient(this._cookies) : _http = HttpClient()..userAgent = _userAgent;

  final List<SessionCookie> _cookies;
  final HttpClient _http;
  String? _token;
  int _userId = 0;
  DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  /// The logged-in user's id; valid after [ensureToken].
  int get userId => _userId;

  /// Makes sure a token valid for at least one more minute is at hand.
  Future<void> ensureToken() async {
    final soon = DateTime.now().add(const Duration(minutes: 1));
    if (_token != null && _tokenExpiry.isAfter(soon)) return;
    final reply = await _postForm(
      Uri.parse('https://login.vk.ru/?act=web_token'),
      {'version': '1', 'app_id': webClientId},
    );
    if (reply['type'] != 'okay') {
      throw VkException('web_token refused: type=${reply['type']}');
    }
    final data = reply['data'] as Map<String, dynamic>;
    _token = data['access_token'] as String;
    _userId = data['user_id'] as int;
    _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(
      (data['expires'] as int) * 1000,
    );
  }

  /// Calls one web API method. Matches [VkApiCall].
  Future<Object?> call(String method, Map<String, String> params) async {
    await ensureToken();
    final reply = await _postForm(
      Uri.parse(
        'https://web.api.vk.ru/method/$method'
        '?v=$apiVersion&client_id=$webClientId',
      ),
      {...params, 'access_token': _token!},
    );
    final error = reply['error'];
    if (error is Map<String, dynamic>) {
      throw VkException(
        '$method error ${error['error_code']}: ${error['error_msg']}',
      );
    }
    return reply['response'];
  }

  /// Fresh stream URL for one song, or null if VK has none (blocked).
  Future<String?> resolveStreamUrl(String sourceKey, String? accessKey) async {
    final id = accessKey == null ? sourceKey : '${sourceKey}_$accessKey';
    final reply = await call('audio.getById', {'audios': id}) as List;
    if (reply.isEmpty) return null;
    final url = (reply.first as Map<String, dynamic>)['url'] as String?;
    return (url == null || url.isEmpty) ? null : url;
  }

  /// POSTs a form with the session cookies and decodes the JSON reply.
  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> form,
  ) async {
    final cookieHeader = _cookies
        .where((cookie) => cookie.appliesTo(uri.host))
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    final request = await _http.postUrl(uri);
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
      ..set('Origin', 'https://vk.ru')
      ..set(HttpHeaders.refererHeader, 'https://vk.ru/')
      ..set(HttpHeaders.cookieHeader, cookieHeader);
    request.write(Uri(queryParameters: form).query);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  void close() => _http.close(force: true);
}
