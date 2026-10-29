import 'dart:async';
import 'dart:io';
import 'dart:math';

/// One upstream stream made reachable for mpv through [StreamProxy].
class ProxiedStream {
  ProxiedStream._(this.localUri, this._upstream);

  /// Loopback address mpv opens instead of the real link.
  final Uri localUri;
  final Uri _upstream;

  final _firstChunk = Completer<int>();

  /// Milliseconds from sending the first upstream request to receiving its
  /// first body bytes: the network's share of the start time.
  Future<int> get networkFirstChunkMs => _firstChunk.future;
}

/// Local HTTP proxy between mpv and the VK CDN.
///
/// The app does all network I/O itself, so it can time the network exactly,
/// apply its own timeouts and keep links away from mpv, its logs and disk.
/// Range requests are passed through, so seeking works as with a direct link.
class StreamProxy {
  StreamProxy._(this._server) {
    _server.listen(_handle);
  }

  static Future<StreamProxy> start() async =>
      StreamProxy._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final _streams = <String, ProxiedStream>{};
  final _random = Random.secure();
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  /// Registers [upstream] and returns the stream mpv should open. Only the
  /// most recent streams stay registered.
  ProxiedStream add(Uri upstream) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    final stream = ProxiedStream._(
      Uri.parse('http://127.0.0.1:${_server.port}/s/$id.mp3'),
      upstream,
    );
    _streams[id] = stream;
    while (_streams.length > 4) {
      _streams.remove(_streams.keys.first);
    }
    return stream;
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final id = segments.length == 2 ? segments[1].replaceAll('.mp3', '') : '';
    final stream = _streams[id];
    final response = request.response;
    if (stream == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final clock = Stopwatch()..start();
    HttpClientResponse upstream;
    try {
      final outgoing = await _http.getUrl(stream._upstream);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
      upstream = await outgoing.close().timeout(const Duration(seconds: 15));
    } catch (_) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    response.statusCode = upstream.statusCode;
    for (final name in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
    if (upstream.contentLength >= 0) {
      response.contentLength = upstream.contentLength;
    }
    response.bufferOutput = false;

    final body = upstream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          if (!stream._firstChunk.isCompleted) {
            stream._firstChunk.complete(clock.elapsedMilliseconds);
          }
          sink.add(chunk);
        },
      ),
    );
    try {
      await response.addStream(body);
      await response.close();
    } catch (_) {
      // mpv closed the connection (new song, seek or stop).
    }
  }

  Future<void> close() async {
    _http.close(force: true);
    await _server.close(force: true);
  }
}
