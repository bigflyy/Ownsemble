import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mp3_length.dart';

/// One upstream stream made reachable for mpv through [StreamProxy].
class ProxiedStream {
  ProxiedStream._(
    this.localUri,
    this._upstream,
    this._cacheTo,
    this._onSaved,
    this.label,
    this._expectSeconds,
  );

  /// Names the song in perf.log (such as "song 123"), never a title.
  final String? label;

  /// Loopback address mpv opens instead of the real link.
  final Uri localUri;

  /// The link of this copy of the song. Never swapped for another link: a
  /// different file can be another recording (VK gives a live version the
  /// same track_id as the studio one), and a wrong song is worse than a song
  /// that says it cannot play (user, 2026-11-04).
  final Uri _upstream;

  /// Where the whole audio is saved while it streams; null: not saved.
  final File? _cacheTo;

  /// Told how much is saved so far and the whole size.
  final void Function(int written, int total)? _onSaved;

  /// How long the file should play, in seconds; null: not checked. A file
  /// more than [otherRecordingSeconds] off is held back from mpv and
  /// reported through [otherRecording] instead (Stage K).
  final double? _expectSeconds;

  final _measured = Completer<FileFacts?>();
  final _other = Completer<FileFacts>();

  /// The file's size and length, measured from its first bytes when mpv
  /// asks for the whole file; null when it could not be measured or is not
  /// checked. Never completes while mpv has not asked for the file.
  Future<FileFacts?> get measured => _measured.future;

  /// Completes when the file is another recording than expected. mpv then
  /// gets none of it: its request waits until the stream is let go.
  Future<FileFacts> get otherRecording => _other.future;

  /// Set once [otherRecording] completed, to read without waiting.
  FileFacts? otherRecordingFacts;

  /// Ends mpv's held request of a file that is another recording.
  void Function()? _releaseHeld;

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

  /// Stops saving this stream, for [reason] (named in perf.log). The part
  /// already fetched is thrown away; what mpv is playing is not affected.
  void cancelCaching([String reason = 'canceled']) {
    if (_cachingCanceled || _stored.isCompleted) return;
    _cachingCanceled = true;
    _cancelReason = reason;
    if (!_teeStarted) _finishStored(null, reason);
  }

  /// Why saving was canceled, once it was.
  String? _cancelReason;

  /// Bytes saved so far and the whole size (negative: not known yet).
  int _written = 0;
  int _total = -1;

  /// Told about a save that ended without a whole file; set by the proxy.
  void Function(LostSave lost)? _onLost;

  /// Ends the save with [bytes] saved, or with null for [reason] when it
  /// was lost; a lost save is reported once, if there was a file to save.
  void _finishStored(int? bytes, [String? reason]) {
    if (_stored.isCompleted) return;
    _stored.complete(bytes);
    if (bytes == null && _cacheTo != null) {
      _onLost?.call(
        LostSave(
          label: label,
          written: _written,
          total: _total,
          reason: reason ?? 'canceled',
        ),
      );
    }
  }

  /// The audio server's status when it failed; null while it has not.
  int? _failedWith;

  /// Milliseconds from sending the first upstream request to receiving its
  /// first body bytes: the network's share of the start time.
  Future<int> get networkFirstChunkMs => _firstChunk.future;

  /// Completes with the HTTP status (0 when unreachable) if the audio server
  /// answered with an error instead of audio. Never completes on success.
  Future<int> get upstreamFailure => _failure.future;

  void _fail(int status) {
    _failedWith ??= status;
    if (!_failure.isCompleted) _failure.complete(status);
  }
}

/// A song that streamed with a cache file but was not saved whole, and why:
/// for perf.log. Holds no titles or links.
class LostSave {
  const LostSave({
    required this.label,
    required this.written,
    required this.total,
    required this.reason,
  });

  /// The song, as given to [StreamProxy.add] (such as "song 123").
  final String? label;

  /// Bytes saved before the save stopped.
  final int written;

  /// The whole size; negative when the audio server never said.
  final int total;

  /// Why it stopped, such as "skipped after 1.2 s of play".
  final String reason;

  /// One perf.log line.
  @override
  String toString() =>
      'save lost: ${label ?? 'a song'}, $written of '
      '${total < 0 ? '?' : total} bytes, $reason';
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
/// canceled, so a song played once plays from disk afterwards. When the
/// song changes, [songChanged] decides which saves go on.
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

  final _lostSaves = StreamController<LostSave>.broadcast(sync: true);

  /// Every save that ended without a whole file, and why.
  Stream<LostSave> get lostSaves => _lostSaves.stream;
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

  /// Whether [reply] is something other than the song: an error page, an HLS
  /// playlist (the "206 of 1.7 KB" VK sometimes answers, see
  /// [VkClient.resolveStream]) or, for a whole-file request, a stub.
  static bool _isNotAudio(HttpClientResponse reply, bool wholeFile) {
    if (reply.statusCode >= 400) return true;
    final type = reply.headers.value(HttpHeaders.contentTypeHeader);
    if (type != null && type.toLowerCase().contains('mpegurl')) return true;
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
  /// audio is also saved to [cacheTo] when given. [onSaved] is told how far
  /// the save has got. Only the
  /// most recent streams stay registered.
  ///
  /// With [expectSeconds] the file's length is checked from its first
  /// bytes before mpv gets any (see [ProxiedStream.otherRecording]).
  ProxiedStream add(
    Uri upstream, {
    File? cacheTo,
    void Function(int written, int total)? onSaved,
    String? label,
    double? expectSeconds,
  }) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    final stream = ProxiedStream._(
      Uri.parse('http://127.0.0.1:${_server.port}/s/$id.mp3'),
      upstream,
      cacheTo,
      onSaved,
      label,
      expectSeconds,
    ).._onLost = _reportLost;
    _streams[id] = stream;
    while (_streams.length > 4) {
      final old = _streams.remove(_streams.keys.first);
      // A skipped song's save may go on: it needs no more requests from mpv.
      if (old != null && !_kept.contains(old)) {
        _stop(old, 'another song started');
      }
    }
    return stream;
  }

  void _reportLost(LostSave lost) {
    if (!_lostSaves.isClosed) _lostSaves.add(lost);
  }

  /// For checks only: the most bytes a second a save reads from the audio
  /// server (null: no limit). On a fast line a song is saved in 2-4 s, before
  /// a check can skip it after [keepSavingAfter]; slowed down, the save is
  /// still running then, as it is on a slow day.
  int? saveRateLimit;

  /// A skipped song goes on saving once it played this long.
  static const keepSavingAfter = Duration(seconds: 5);

  /// How many skipped songs go on saving at once, the most recent ones.
  static const keptSaves = 2;

  /// Skipped songs whose saves go on, oldest first.
  final _kept = <ProxiedStream>[];

  /// Stops [stream]'s save for [reason], at once if mpv no longer reads it.
  /// A request held back as another recording ends here too.
  void _stop(ProxiedStream stream, String reason) {
    _kept.remove(stream);
    stream._releaseHeld?.call();
    stream.cancelCaching(reason);
    final done = stream._teeDone;
    if (done != null && !done.isCompleted) done.complete(false);
  }

  /// A new song is about to play instead of [skipped] (null: the last song
  /// was not streamed), which played for [heard]. Its save goes on in the
  /// background if it played at least [keepSavingAfter] or is [playedAgain]
  /// (the new song is the same one, which then saves nothing itself); only
  /// the [keptSaves] most recently skipped songs go on. Every other save
  /// stops, so it does not take bandwidth from the new song.
  void songChanged(
    ProxiedStream? skipped, {
    required Duration heard,
    bool playedAgain = false,
  }) {
    if (skipped != null && !skipped._stored.isCompleted) {
      final failed = skipped._failedWith;
      if (failed != null) {
        _stop(skipped, 'audio server failed (status $failed)');
      } else if (!playedAgain && heard < keepSavingAfter) {
        final seconds = (heard.inMilliseconds / 1000).toStringAsFixed(1);
        _stop(skipped, 'skipped after $seconds s of play');
      } else if (!skipped._teeStarted) {
        _stop(skipped, 'the player never asked for the whole file');
      } else {
        _kept
          ..remove(skipped)
          ..add(skipped);
        skipped.stored.whenComplete(() => _kept.remove(skipped));
        while (_kept.length > keptSaves) {
          _stop(_kept.first, 'pushed out by $keptSaves later skipped songs');
        }
      }
    }
    for (final stream in {..._streams.values, ..._caching}) {
      if (identical(stream, skipped) || _kept.contains(stream)) continue;
      _stop(stream, 'another song started');
    }
  }

  /// Cancels saving every stream except [keep], so downloads of songs no
  /// longer playing do not take bandwidth from the new one.
  void cancelCachingExcept(ProxiedStream? keep, [String reason = 'canceled']) {
    for (final stream in {..._streams.values, ..._caching}) {
      if (identical(stream, keep)) continue;
      _stop(stream, reason);
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
    // A seek leaves a running save alone: the two share the line, and the
    // song is kept for its next play (user's pick, 2026-11-04).
    final clock = Stopwatch()..start();
    var upstream = await _connectUpstream(stream._upstream, range, trace.tries);
    // Not the song. It is asked again, because most of these go away by
    // themselves (a broken file answers 504 every time, and then the song
    // says it cannot play; no other file is ever used instead).
    if (upstream != null && _isNotAudio(upstream, wholeFile)) {
      for (var again = 0; again < _sameLinkRetries; again++) {
        trace.tries.add('${await _describe(upstream!)}, asking again');
        await Future<void>.delayed(_sameLinkPause);
        upstream = await _connectUpstream(stream._upstream, range, trace.tries);
        if (upstream == null || !_isNotAudio(upstream, wholeFile)) break;
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

    // The whole size: from Content-Range for "bytes=0-", else the length.
    final contentRange = upstream.headers.value(HttpHeaders.contentRangeHeader);
    final total = contentRange == null
        ? upstream.contentLength
        : int.tryParse(contentRange.split('/').last) ?? -1;
    void noteFirstChunk() {
      if (!stream._firstChunk.isCompleted) {
        stream._firstChunk.complete(clock.elapsedMilliseconds);
      }
    }

    final Stream<List<int>> source;
    if (wholeFile &&
        stream._expectSeconds != null &&
        !stream._measured.isCompleted &&
        total > 0) {
      source = _checked(stream, upstream, total, noteFirstChunk);
    } else {
      if (wholeFile && !stream._measured.isCompleted) {
        stream._measured.complete(null);
      }
      source = upstream;
    }

    final cacheTo = stream._cacheTo;
    if (cacheTo != null &&
        wholeFile &&
        !stream._teeStarted &&
        !stream._cachingCanceled &&
        upstream.statusCode < 300) {
      stream._teeStarted = true;
      await _serveAndSave(
        stream,
        source,
        total,
        response,
        cacheTo,
        noteFirstChunk,
        trace,
      );
      return;
    }

    final body = source.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          noteFirstChunk();
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

  /// [upstream], held back until its first bytes tell how long the file of
  /// [total] bytes plays. A file within [otherRecordingSeconds] of what
  /// [stream] expects then flows on unchanged; another recording reaches mpv
  /// not at all: it is reported, its save canceled, and mpv's request waits
  /// (an early end would look like the song's end and start the next song)
  /// until the stream is let go. A file that cannot be measured flows on.
  Stream<List<int>> _checked(
    ProxiedStream stream,
    Stream<List<int>> upstream,
    int total,
    void Function() onFirstChunk,
  ) {
    final controller = StreamController<List<int>>();
    final held = BytesBuilder(copy: false);
    final heldChunks = <List<int>>[];
    var open = false;
    StreamSubscription<List<int>>? subscription;
    void letThrough() {
      open = true;
      heldChunks.forEach(controller.add);
      heldChunks.clear();
    }

    controller.onListen = () {
      subscription = upstream.listen(
        (chunk) {
          if (open) {
            controller.add(chunk);
            return;
          }
          onFirstChunk();
          heldChunks.add(chunk);
          held.add(chunk);
          final reading = readHead(held.toBytes(), total);
          if (reading.needMore) return;
          final facts = reading.facts;
          if (!stream._measured.isCompleted) stream._measured.complete(facts);
          if (facts != null && facts.differsFrom(stream._expectSeconds!)) {
            stream.otherRecordingFacts = facts;
            stream.cancelCaching('another recording ($facts)');
            stream._releaseHeld = () {
              stream._releaseHeld = null;
              if (!controller.isClosed) {
                controller.addError(const HttpException('another recording'));
                unawaited(controller.close());
              }
            };
            unawaited(subscription?.cancel());
            heldChunks.clear();
            if (!stream._other.isCompleted) stream._other.complete(facts);
            return;
          }
          letThrough();
        },
        onError: (Object error, StackTrace trace) {
          if (!open && stream.otherRecordingFacts == null) letThrough();
          controller.addError(error, trace);
        },
        onDone: () {
          if (stream.otherRecordingFacts != null) return;
          if (!open) {
            // A file shorter than the bytes the check wanted.
            final reading = readHead(held.toBytes(), total);
            if (!stream._measured.isCompleted) {
              stream._measured.complete(reading.facts);
            }
            letThrough();
          }
          unawaited(controller.close());
        },
      );
    };
    controller
      ..onPause = (() => subscription?.pause())
      ..onResume = (() => subscription?.resume())
      ..onCancel = (() => subscription?.cancel());
    return controller.stream;
  }

  void _report(_Trace trace, String end) {
    if (!_requests.isClosed) _requests.add(trace.finish(end));
  }

  /// Sends [upstream] to mpv and writes it to [cacheTo] at the same time;
  /// keeps writing after mpv hangs up, until the file is whole or caching
  /// is canceled.
  Future<void> _serveAndSave(
    ProxiedStream stream,
    Stream<List<int>> upstream,
    int total,
    HttpResponse response,
    File cacheTo,
    void Function() noteFirstChunk,
    _Trace trace,
  ) async {
    stream._total = total;
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
    // For [saveRateLimit]: time since the first byte, and the pending resume.
    final rateClock = Stopwatch()..start();
    Timer? resumeLater;
    late final StreamSubscription<List<int>> subscription;
    subscription = upstream.listen(
      (chunk) {
        noteFirstChunk();
        trace.firstByteMs ??= trace.clock.elapsedMilliseconds;
        file?.add(chunk);
        written += chunk.length;
        stream._written = written;
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
        // Slowed for a check: wait until the bytes so far fit the limit.
        final limit = saveRateLimit;
        if (limit != null && limit > 0 && !done.isCompleted) {
          final dueMs = written * 1000 ~/ limit;
          final aheadMs = dueMs - rateClock.elapsedMilliseconds;
          if (aheadMs > 0) {
            subscription.pause();
            resumeLater = Timer(
              Duration(milliseconds: aheadMs),
              subscription.resume,
            );
          }
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
    resumeLater?.cancel();
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
    stream._finishStored(
      saved ? written : null,
      file == null
          ? 'cache file could not be opened'
          : stalled
          ? 'stalled'
          : stream._cachingCanceled
          ? stream._cancelReason
          : !complete
          ? 'upstream error'
          : total >= 0 && written != total
          ? 'cut short'
          : 'cache file could not be written',
    );
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

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final running = [
      for (final stream in {..._streams.values, ..._caching}) stream.stored,
    ];
    _kept.clear();
    cancelCachingExcept(null, 'app closed');
    for (final stream in _streams.values) {
      stream._releaseHeld?.call();
    }
    // Lets the stopped saves report themselves before the log stream ends.
    await Future.wait(running)
        .timeout(const Duration(seconds: 1), onTimeout: () => const []);
    await _lostSaves.close();
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
