import 'dart:async';
import 'dart:io';
import 'dart:math';

/// One upstream stream made reachable for mpv through [StreamProxy].
class ProxiedStream {
  ProxiedStream._(
    this.localUri,
    this._upstream,
    this._cacheTo,
    this._alternative,
    this._onSaved,
  );

  /// Loopback address mpv opens instead of the real link.
  final Uri localUri;
  Uri _upstream;

  /// Where the whole audio is saved while it streams; null: not saved.
  final File? _cacheTo;

  /// Gets another link to the same audio; null: there is no other.
  final Future<Uri?> Function()? _alternative;

  /// Told how much is saved so far and the whole size.
  final void Function(int written, int total)? _onSaved;
  Future<Uri?>? _switching;

  /// Moves this stream to its alternative link, asked for only once, so
  /// later requests (seeks) use it too. Null when there is none. If asking
  /// fails the audio server's own failure is the one to report.
  Future<Uri?> _switchLink() => _switching ??= () async {
    try {
      final other = await _alternative?.call();
      if (other != null) _upstream = other;
      return other;
    } catch (_) {
      return null;
    }
  }();

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

/// What happened to one request mpv made through [StreamProxy]: for
/// perf.log and the seek benchmark, so a slow seek can be split into the
/// audio server's share and the proxy's. Holds no links.
class ProxyRequestLog {
  const ProxyRequestLog({
    required this.startedAt,
    required this.asked,
    required this.fromByte,
    required this.tries,
    required this.headersMs,
    required this.status,
    required this.firstByteMs,
    required this.bytes,
    required this.totalMs,
    required this.end,
    this.ranges,
  });

  /// When mpv's request arrived.
  final DateTime startedAt;

  /// The Range header mpv sent, such as "bytes=0-"; null when it sent none.
  final String? asked;

  /// Where the requested range starts; null for the whole file.
  final int? fromByte;

  /// One note per try at the audio server, such as "8001 ms timeout".
  final List<String> tries;

  /// From mpv's request to the audio server's answer (headers); null when
  /// no answer came.
  final int? headersMs;

  /// The audio server's HTTP status; 0 when it never answered.
  final int status;

  /// From mpv's request to the first audio bytes; null when none came.
  final int? firstByteMs;

  /// Audio bytes passed on to mpv.
  final int bytes;

  /// From mpv's request until the proxy finished with it.
  final int totalMs;

  /// How it ended: done, mpv hung up (", saved on" when the save went on
  /// to the end), save canceled, upstream error, no answer, stalled.
  final String end;

  /// What the audio server says about ranges: its Accept-Ranges header,
  /// or "content-range" when it sent only that; null when it said nothing.
  final String? ranges;

  /// One perf.log line.
  @override
  String toString() =>
      'proxy ${fromByte == null ? 'whole' : 'range from $fromByte'}: '
      'asked ${asked ?? 'no range'}, '
      'tries [${tries.join(', ')}], status $status, ranges ${ranges ?? '-'}, '
      'headers ${headersMs ?? '-'} ms, first byte ${firstByteMs ?? '-'} ms, '
      '$bytes bytes in $totalMs ms, $end';

  Map<String, Object?> toJson() => {
    'asked': asked,
    'fromByte': fromByte,
    'ranges': ranges,
    'tries': tries,
    'status': status,
    'headersMs': headersMs,
    'firstByteMs': firstByteMs,
    'bytes': bytes,
    'totalMs': totalMs,
    'end': end,
  };
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
  final _requests = StreamController<ProxyRequestLog>.broadcast();

  /// Every finished request from mpv, with its timing.
  Stream<ProxyRequestLog> get requests => _requests.stream;
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
  /// Each try's time and outcome is added to [tries].
  Future<HttpClientResponse?> _connectUpstream(
    Uri uri,
    String? range,
    List<String> tries,
  ) async {
    final clock = Stopwatch()..start();
    for (var attempt = 1; attempt <= 4; attempt++) {
      final left = _upstreamBudget - clock.elapsed;
      if (left <= Duration.zero) break;
      final tryStartedMs = clock.elapsedMilliseconds;
      HttpClientRequest? outgoing;
      try {
        outgoing = await _http.getUrl(uri).timeout(left);
        if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
        // One try waits at most 8 s for the answer, so a stalled one still
        // leaves time for another.
        final limit = _upstreamBudget - clock.elapsed;
        final answer = await outgoing.close().timeout(
          limit < const Duration(seconds: 8)
              ? limit
              : const Duration(seconds: 8),
        );
        tries.add('${clock.elapsedMilliseconds - tryStartedMs} ms ok');
        return answer;
      } catch (error) {
        // The error's type only: messages may carry the server's address.
        final kind = error is TimeoutException
            ? 'timeout'
            : error.runtimeType.toString();
        tries.add('${clock.elapsedMilliseconds - tryStartedMs} ms $kind');
        outgoing?.abort();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return null;
  }

  /// How many times a song without another link is asked for again.
  static const _sameLinkRetries = 2;

  /// The wait before that; a server error rarely lasts longer.
  static const _sameLinkPause = Duration(milliseconds: 300);

  /// A whole song is never this short: at 128 kbit/s this is 2 seconds.
  static const _stubBytes = 32 * 1024;

  /// Whether [reply] is something other than the song: an error page or, for
  /// a whole-file request, a stub. VK has answered with a 206 of 1.7 KB and
  /// closed (twice in about 300 plays); the song played on the next try.
  static bool _isNotAudio(HttpClientResponse reply, bool wholeFile) {
    if (reply.statusCode >= 400) return true;
    final length = reply.contentLength;
    return wholeFile && length >= 0 && length < _stubBytes;
  }

  /// A line for the log about a reply that was not the song, which also
  /// reads the reply to its end. Headers and first bytes only, never links.
  Future<String> _describe(HttpClientResponse reply) async {
    final head = <int>[];
    await for (final chunk in reply) {
      if (head.length < 8) head.addAll(chunk);
    }
    final start = head
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'status ${reply.statusCode}: ${reply.contentLength} bytes, '
        '${reply.headers.value(HttpHeaders.contentTypeHeader)}, '
        'range ${reply.headers.value(HttpHeaders.contentRangeHeader)}, '
        'starts $start';
  }

  /// Saves still running, including those of streams no longer registered.
  final _caching = <ProxiedStream>{};

  /// Registers [upstream] and returns the stream mpv should open; the whole
  /// audio is also saved to [cacheTo] when given. [alternative] gets another
  /// link to the same audio for when the audio server answers [upstream]
  /// with an error. [onSaved] is told how far the save has got. Only the
  /// most recent streams stay registered.
  ProxiedStream add(
    Uri upstream, {
    File? cacheTo,
    Future<Uri?> Function()? alternative,
    void Function(int written, int total)? onSaved,
  }) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    final stream = ProxiedStream._(
      Uri.parse('http://127.0.0.1:${_server.port}/s/$id.mp3'),
      upstream,
      cacheTo,
      alternative,
      onSaved,
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
    final trace = _Trace(
      range,
      wholeFile
          ? null
          : int.tryParse(
              RegExp(r'bytes=(\d+)-').firstMatch(range)?.group(1) ?? '',
            ),
    );
    // A seek: the save still fetching from the start would share the line
    // with it and make it slow, so saving stops; the song is saved the next
    // time it plays through.
    final saving = stream._teeDone;
    if (!wholeFile && saving != null && !saving.isCompleted) {
      stream.cancelCaching();
      saving.complete(false);
    }
    final clock = Stopwatch()..start();
    var upstream = await _connectUpstream(stream._upstream, range, trace.tries);
    // Not the song. Nothing has reached mpv, so the other link can take over
    // without mpv noticing; a song without one is asked again, because most
    // of these go away by themselves (a broken file answers 504 every time).
    if (upstream != null && _isNotAudio(upstream, wholeFile)) {
      final other = await stream._switchLink();
      if (other != null) {
        trace.tries.add('${await _describe(upstream)}, trying the other link');
        upstream = await _connectUpstream(other, range, trace.tries);
      } else {
        for (var again = 0; again < _sameLinkRetries; again++) {
          trace.tries.add('${await _describe(upstream!)}, asking again');
          await Future<void>.delayed(_sameLinkPause);
          upstream = await _connectUpstream(
            stream._upstream,
            range,
            trace.tries,
          );
          if (upstream == null || !_isNotAudio(upstream, wholeFile)) break;
        }
      }
    }
    if (upstream == null) {
      stream._fail(0);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      _report(trace, 'no answer');
      return;
    }
    trace
      ..headersMs = trace.clock.elapsedMilliseconds
      ..status = upstream.statusCode
      ..ranges =
          upstream.headers.value(HttpHeaders.acceptRangesHeader) ??
          (upstream.headers.value(HttpHeaders.contentRangeHeader) == null
              ? null
              : 'content-range');
    // An error page or a stub is not audio: mpv may misread it as a song or
    // fail with a message that says nothing, so report the failure and give
    // mpv nothing.
    if (_isNotAudio(upstream, wholeFile)) {
      stream._fail(
        upstream.statusCode >= 400
            ? upstream.statusCode
            : HttpStatus.badGateway,
      );
      await upstream.drain<void>();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      _report(trace, 'upstream error');
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
      await _serveAndSave(stream, upstream, response, cacheTo, clock, trace);
      return;
    }

    final body = upstream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          if (!stream._firstChunk.isCompleted) {
            stream._firstChunk.complete(clock.elapsedMilliseconds);
          }
          trace.firstByteMs ??= trace.clock.elapsedMilliseconds;
          trace.bytes += chunk.length;
          sink.add(chunk);
        },
      ),
    );
    try {
      await response.addStream(body);
      await response.close();
      // mpv may hang up without an error reaching the proxy.
      final short =
          upstream.contentLength >= 0 && trace.bytes < upstream.contentLength;
      _report(trace, short ? 'mpv hung up' : 'done');
    } catch (_) {
      // mpv closed the connection (new song, seek or stop).
      _report(trace, 'mpv hung up');
    }
  }

  void _report(_Trace trace, String end) {
    if (!_requests.isClosed) _requests.add(trace.finish(end));
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
    _Trace trace,
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
        trace.firstByteMs ??= trace.clock.elapsedMilliseconds;
        file?.add(chunk);
        written += chunk.length;
        if (file != null && !stream._cachingCanceled) {
          stream._onSaved?.call(written, total);
        }
        if (!mpvGone) {
          try {
            response.add(chunk);
            trace.bytes += chunk.length;
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
    final stalled = !complete && written == lastWritten;
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
    _report(
      trace,
      stalled
          ? 'stalled'
          : complete
          ? (mpvGone ? 'mpv hung up, saved on' : 'done')
          : stream._cachingCanceled
          ? (mpvGone ? 'mpv hung up, save canceled' : 'save canceled')
          : 'upstream error',
    );
  }

  Future<void> close() async {
    cancelCachingExcept(null);
    await _requests.close();
    _http.close(force: true);
    await _server.close(force: true);
  }
}

/// Timing of one request while the proxy serves it; see [ProxyRequestLog].
class _Trace {
  _Trace(this.asked, this.fromByte);

  final String? asked;
  final int? fromByte;
  final startedAt = DateTime.now();
  String? ranges;
  final clock = Stopwatch()..start();
  final tries = <String>[];
  int? headersMs;
  int status = 0;
  int? firstByteMs;
  int bytes = 0;

  ProxyRequestLog finish(String end) => ProxyRequestLog(
    startedAt: startedAt,
    asked: asked,
    fromByte: fromByte,
    ranges: ranges,
    tries: List.unmodifiable(tries),
    headersMs: headersMs,
    status: status,
    firstByteMs: firstByteMs,
    bytes: bytes,
    totalMs: clock.elapsedMilliseconds,
    end: end,
  );
}
