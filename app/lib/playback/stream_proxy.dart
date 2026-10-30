import 'dart:async';
import 'dart:io';
import 'dart:math';

/// One upstream stream made reachable for mpv through [StreamProxy].
class ProxiedStream {
  ProxiedStream._(this.localUri, this._upstream, this._cacheTo);

  /// Loopback address mpv opens instead of the real link.
  final Uri localUri;
  final Uri _upstream;

  /// Where the whole audio is saved while it streams; null: not saved.
  final File? _cacheTo;

  final _firstChunk = Completer<int>();
  final _failure = Completer<int>();
  final _stored = Completer<int?>();
  bool _teeStarted = false;
  bool _cachingCanceled = false;

  /// Ends a running save early (canceled or the proxy closing).
  Completer<bool>? _teeDone;

  /// Completes with the size once the whole audio is saved to the cache
  /// file, or with null when it is not (no cache file, canceled, failed).
  Future<int?> get stored => _stored.future;

  /// Stops saving this stream (another song started). The part already
  /// fetched is thrown away; what mpv is playing is not affected.
  void cancelCaching() {
    _cachingCanceled = true;
    if (!_teeStarted) _finishStored(null);
  }

  void _finishStored(int? bytes) {
    if (!_stored.isCompleted) _stored.complete(bytes);
  }

  /// Milliseconds from sending the first upstream request to receiving its
  /// first body bytes: the network's share of the start time.
  Future<int> get networkFirstChunkMs => _firstChunk.future;

  /// Completes with the HTTP status (0 when unreachable) if the audio server
  /// answered with an error instead of audio. Never completes on success.
  Future<int> get upstreamFailure => _failure.future;

  void _fail(int status) {
    if (!_failure.isCompleted) _failure.complete(status);
  }
}

/// Local HTTP proxy between mpv and the VK CDN.
///
/// The app does all network I/O itself, so it can time the network exactly,
/// apply its own timeouts and keep links away from mpv, its logs and disk.
/// Range requests are passed through, so seeking works as with a direct link.
///
/// The first request for the whole file is also saved to the stream's cache
/// file while mpv plays it. If mpv drops that connection (a seek), saving
/// goes on in the background until the file is complete or caching is
/// canceled, so a song played once plays from disk afterwards.
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
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 30);

  /// Longest wait for the audio server's answer (headers), over all tries.
  /// The player gives a song 20 s to make a sound, so this leaves it a
  /// little time to start playing.
  static const _upstreamBudget = Duration(seconds: 17);

  /// Requests [uri] (with [range], if any) and returns the answer, or null
  /// when no answer came. On a lossy line a connection may drop or stall
  /// before the server answers, and a fresh one often goes through at once,
  /// so a failed try is repeated (up to 4 tries) while [_upstreamBudget]
  /// lasts. Nothing has reached mpv before the answer, so a new try is safe.
  Future<HttpClientResponse?> _connectUpstream(Uri uri, String? range) async {
    final clock = Stopwatch()..start();
    for (var attempt = 1; attempt <= 4; attempt++) {
      final left = _upstreamBudget - clock.elapsed;
      if (left <= Duration.zero) break;
      HttpClientRequest? outgoing;
      try {
        outgoing = await _http.getUrl(uri).timeout(left);
        if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
        // One try waits at most 8 s for the answer, so a stalled one still
        // leaves time for another.
        final limit = _upstreamBudget - clock.elapsed;
        return await outgoing.close().timeout(
          limit < const Duration(seconds: 8)
              ? limit
              : const Duration(seconds: 8),
        );
      } catch (_) {
        outgoing?.abort();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return null;
  }

  /// Saves still running, including those of streams no longer registered.
  final _caching = <ProxiedStream>{};

  /// Registers [upstream] and returns the stream mpv should open; the whole
  /// audio is also saved to [cacheTo] when given. Only the most recent
  /// streams stay registered.
  ProxiedStream add(Uri upstream, {File? cacheTo}) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    final stream = ProxiedStream._(
      Uri.parse('http://127.0.0.1:${_server.port}/s/$id.mp3'),
      upstream,
      cacheTo,
    );
    _streams[id] = stream;
    while (_streams.length > 4) {
      _streams.remove(_streams.keys.first)?.cancelCaching();
    }
    return stream;
  }

  /// Cancels saving every stream except [keep], so downloads of songs no
  /// longer playing do not take bandwidth from the new one.
  void cancelCachingExcept(ProxiedStream? keep) {
    for (final stream in {..._streams.values, ..._caching}) {
      if (identical(stream, keep)) continue;
      stream.cancelCaching();
      // A save whose mpv connection is gone stops at once.
      final done = stream._teeDone;
      if (done != null && !done.isCompleted) done.complete(false);
    }
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
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final wholeFile = range == null || range.trim() == 'bytes=0-';
    // A seek: the save still fetching from the start would share the line
    // with it and make it slow, so saving stops; the song is saved the next
    // time it plays through.
    final saving = stream._teeDone;
    if (!wholeFile && saving != null && !saving.isCompleted) {
      stream.cancelCaching();
      saving.complete(false);
    }
    final clock = Stopwatch()..start();
    final upstream = await _connectUpstream(stream._upstream, range);
    if (upstream == null) {
      stream._fail(0);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    // An error page is not audio: mpv may misread it as a song, so report
    // the failure and give mpv nothing.
    if (upstream.statusCode >= 400) {
      stream._fail(upstream.statusCode);
      await upstream.drain<void>();
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

    final cacheTo = stream._cacheTo;
    if (cacheTo != null &&
        wholeFile &&
        !stream._teeStarted &&
        !stream._cachingCanceled &&
        upstream.statusCode < 300) {
      stream._teeStarted = true;
      await _serveAndSave(stream, upstream, response, cacheTo, clock);
      return;
    }

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

  /// Sends [upstream] to mpv and writes it to [cacheTo] at the same time;
  /// keeps writing after mpv hangs up, until the file is whole or caching
  /// is canceled.
  Future<void> _serveAndSave(
    ProxiedStream stream,
    HttpClientResponse upstream,
    HttpResponse response,
    File cacheTo,
    Stopwatch clock,
  ) async {
    // The total size: from Content-Range for "bytes=0-", else the length.
    final contentRange = upstream.headers.value(HttpHeaders.contentRangeHeader);
    final total = contentRange == null
        ? upstream.contentLength
        : int.tryParse(contentRange.split('/').last) ?? -1;
    final part = File('${cacheTo.path}.part');
    IOSink? file;
    try {
      part.parent.createSync(recursive: true);
      file = part.openWrite();
    } on FileSystemException {
      file = null;
    }
    var written = 0;
    var mpvGone = false;
    response.done.then(
      (_) {},
      onError: (Object _) {
        mpvGone = true;
      },
    );
    _caching.add(stream);
    final done = stream._teeDone = Completer<bool>();
    final subscription = upstream.listen(
      (chunk) {
        if (!stream._firstChunk.isCompleted) {
          stream._firstChunk.complete(clock.elapsedMilliseconds);
        }
        file?.add(chunk);
        written += chunk.length;
        if (!mpvGone) {
          try {
            response.add(chunk);
          } catch (_) {
            mpvGone = true;
          }
        }
        // Canceled: go on only while mpv still listens.
        if (stream._cachingCanceled && mpvGone && !done.isCompleted) {
          done.complete(false);
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete(false);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(true);
      },
      cancelOnError: true,
    );
    // VK sometimes stops sending without closing the connection.
    var lastWritten = -1;
    final watchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      if (written == lastWritten && !done.isCompleted) done.complete(false);
      lastWritten = written;
    });
    final complete = await done.future;
    watchdog.cancel();
    if (!complete) await subscription.cancel();
    _caching.remove(stream);
    if (!mpvGone) {
      try {
        await response.close();
      } catch (_) {
        // mpv hung up meanwhile.
      }
    }
    var saved = false;
    if (file != null) {
      try {
        await file.close();
        if (complete &&
            !stream._cachingCanceled &&
            written > 0 &&
            (total < 0 || written == total)) {
          if (cacheTo.existsSync()) cacheTo.deleteSync();
          part.renameSync(cacheTo.path);
          saved = true;
        }
      } on FileSystemException {
        saved = false;
      }
      if (!saved && part.existsSync()) {
        try {
          part.deleteSync();
        } on FileSystemException {
          // Still open somewhere; the next save of this song replaces it.
        }
      }
    }
    stream._finishStored(saved ? written : null);
  }

  Future<void> close() async {
    cancelCachingExcept(null);
    _http.close(force: true);
    await _server.close(force: true);
  }
}
