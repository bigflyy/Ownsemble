import 'dart:async';
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
  VkException(this.message, {this.transient = false});
  final String message;

  /// Whether the same request may work when sent again: a stalled
  /// connection or an overloaded VK server, not a refusal.
  final bool transient;
  @override
  String toString() => 'VkException: $message';
}

/// What VK offers for one song. Never logged: [link] is a private link.
class VkStream {
  const VkStream({
    this.link,
    this.restricted = false,
    this.trackId,
    this.releaseKey,
  });

  /// Fresh link to the audio; null when VK gives none.
  final Uri? link;

  /// VK's `content_restricted` is 1: `audio.getRestrictionPopup` says the
  /// musician or their representative decided the song is unavailable.
  /// Other codes were never seen, so nothing is claimed about them.
  final bool restricted;

  /// VK's id of the recording, the same for every copy of it.
  final int? trackId;

  /// `audio.getById` key of the official release of this recording. Copies
  /// in a library are separate files, and a copy's file can be broken on
  /// VK's audio server while the release plays.
  final String? releaseKey;
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
  /// [requestTimeout] is the longest wait for one whole request and
  /// [silenceTimeout] the longest wait with no bytes from VK. A click needs
  /// the short defaults; the background sync passes longer limits so a slow
  /// but working line can still deliver a big page.
  VkClient(
    this._cookies, {
    this.requestTimeout = const Duration(seconds: 15),
    this.silenceTimeout = const Duration(seconds: 15),
  }) : _http = HttpClient()
         ..userAgent = _userAgent
         ..connectionTimeout = const Duration(seconds: 10);

  /// Longest wait for one VK request; without it a stalled request would
  /// leave a click hanging forever.
  final Duration requestTimeout;

  /// Longest wait for the next bytes of a reply.
  final Duration silenceTimeout;

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
      final code = error['error_code'];
      throw VkException(
        '$method error $code: ${error['error_msg']}',
        // 6: too many requests per second, 10: VK internal server error.
        transient: code == 6 || code == 10,
      );
    }
    return reply['response'];
  }

  /// What VK offers for one song right now, with a fresh link.
  Future<VkStream> resolveStream(String sourceKey, String? accessKey) async {
    final id = accessKey == null ? sourceKey : '${sourceKey}_$accessKey';
    final reply = await call('audio.getById', {'audios': id}) as List;
    if (reply.isEmpty) return const VkStream();
    final audio = reply.first as Map<String, dynamic>;
    final url = audio['url'] as String?;
    return VkStream(
      link: (url == null || url.isEmpty) ? null : Uri.parse(url),
      restricted: audio['content_restricted'] == 1,
      trackId: audio['track_id'] as int?,
      releaseKey: audio['release_audio_id'] as String?,
    );
  }

  /// A link to the official release of [stream]'s recording, or null when it
  /// has none. Another recording is never accepted: a wrong song is worse
  /// than a message saying this one cannot play.
  Future<Uri?> releaseLink(VkStream stream) async {
    final (releaseKey, trackId) = (stream.releaseKey, stream.trackId);
    if (releaseKey == null || trackId == null) return null;
    final release = await resolveStream(releaseKey, null);
    return release.trackId == trackId ? release.link : null;
  }

  /// POSTs a form with the session cookies and decodes the JSON reply.
  Future<Map<String, dynamic>> _postForm(Uri uri, Map<String, String> form) {
    final cookieHeader = _cookies
        .where((cookie) => cookie.appliesTo(uri.host))
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    return postVkForm(
      _http,
      uri,
      form: form,
      cookieHeader: cookieHeader,
      silence: silenceTimeout,
      total: requestTimeout,
    );
  }

  void close() => _http.close(force: true);
}

/// POSTs [form] to [uri] the way vk.ru does and decodes the JSON reply.
///
/// Fails with a transient [VkException] when VK sends nothing for [silence]
/// or the whole reply takes longer than [total], and when VK answers with a
/// server error page (5xx) instead of JSON. A stalled request is aborted, so
/// its connection does not linger.
Future<Map<String, dynamic>> postVkForm(
  HttpClient http,
  Uri uri, {
  required Map<String, String> form,
  required String cookieHeader,
  required Duration silence,
  required Duration total,
}) async {
  HttpClientRequest? request;
  Future<Map<String, dynamic>> send() async {
    request = await http.postUrl(uri);
    request!.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
      ..set('Origin', 'https://vk.ru')
      ..set(HttpHeaders.refererHeader, 'https://vk.ru/')
      ..set(HttpHeaders.cookieHeader, cookieHeader);
    request!.write(Uri(queryParameters: form).query);
    final response = await request!.close().timeout(silence);
    if (response.statusCode >= 500) {
      throw VkException(
        'VK server error ${response.statusCode}',
        transient: true,
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(silence)) {
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  try {
    return await send().timeout(total);
  } on TimeoutException {
    request?.abort();
    throw VkException(
      'VK did not answer in time (no reply within ${total.inSeconds} s '
      'or silent for ${silence.inSeconds} s)',
      transient: true,
    );
  } on VkException {
    request?.abort();
    rethrow;
  }
}

/// Whether [error] is a network failure or VK overload that may pass when
/// the same request is sent again.
bool isTransientVkError(Object error) => switch (error) {
  VkException(:final transient) => transient,
  SocketException() ||
  HandshakeException() ||
  HttpException() ||
  TimeoutException() => true,
  _ => false,
};

/// Runs [action] again after a transient failure ([isTransientVkError]), up
/// to [attempts] times in all, waiting [firstDelay] and then twice as long
/// before each new try. Other failures and the last one are rethrown.
Future<T> retryTransient<T>(
  Future<T> Function() action, {
  int attempts = 4,
  Duration firstDelay = const Duration(seconds: 1),
}) async {
  var delay = firstDelay;
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (attempt >= attempts || !isTransientVkError(error)) rethrow;
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }
}

/// [call] with every request sent again after a transient failure (see
/// [retryTransient]). Only for calls that read: sending one twice is safe.
VkApiCall retryingVkCall(VkApiCall call) =>
    (method, params) => retryTransient(() => call(method, params));
