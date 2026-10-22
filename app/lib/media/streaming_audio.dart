import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'audio_cache.dart';
import 'audio_policy.dart';
import 'hls_mp3.dart';

/// One approved upstream download shared by the player and complete cache.
/// Native playback sees only token-scoped loopback URLs, never account URLs.
class StreamingAudio {
  final AudioCache network;
  final Uri source;
  final String userAgent;
  final _resources = <Uri, _Resource>{};
  final _routes = <String, Uri>{};
  final _segments = <String, _Segment>{};
  final _decoded = <String, _Resource>{};
  Future<String>? _manifestFuture;
  final _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  HttpServer? _server;
  Future<Uri>? _opening;
  bool _closed = false, _prepared = false;
  bool get prepared => _prepared;
  int _bytes = 0;
  StreamingAudio(this.network, this.source, {this.userAgent = 'Ownsemble/0.1'});

  bool get downloadComplete {
    if (!source.path.toLowerCase().endsWith('.m3u8')) {
      return _resources[source]?.finished == true &&
          _resources[source]?.failure == null;
    }
    return _routes.isNotEmpty &&
        _routes.values.every(
          (uri) =>
              _resources[uri]?.finished == true &&
              _resources[uri]?.failure == null,
        );
  }

  Future<Uint8List> fetch(
    Uri uri, {
    String userAgent = 'Ownsemble/0.1',
    int limit = 100 * 1024 * 1024,
  }) async {
    final bytes = await _resource(uri).done;
    if (bytes.length > limit) throw const ProofFailure('audio_size_budget');
    return bytes;
  }

  _Resource _resource(Uri uri) {
    if (_closed) throw const ProofFailure('cancelled');
    if (_resources.length >= 2050 && !_resources.containsKey(uri)) {
      throw const ProofFailure('hls_segment_budget');
    }
    return _resources.putIfAbsent(uri, () {
      final resource = _Resource();
      resource.done = network
          .fetch(
            uri,
            userAgent: userAgent,
            onHeaders: resource.headers,
            onChunk: (chunk) {
              _bytes += chunk.length;
              if (_bytes > 100 * 1024 * 1024) {
                throw const ProofFailure('audio_size_budget');
              }
              resource.append(chunk);
            },
          )
          .then(
            (bytes) {
              resource.finish();
              return bytes;
            },
            onError: (Object error, StackTrace stack) {
              resource.finish(error);
              Error.throwWithStackTrace(error, stack);
            },
          );
      // A player can cancel before the complete-cache consumer attaches.
      unawaited(resource.done.then<void>((_) {}, onError: (Object _) {}));
      return resource;
    });
  }

  String _route(Uri uri, String extension) =>
      _routes.entries
          .where((e) => e.value == uri)
          .map((e) => e.key)
          .firstOrNull ??
      (() {
        final path = '/$_token/${_routes.length}.$extension';
        _routes[path] = uri;
        return path;
      })();

  /// Warm at most two packed-audio segments, without exposing a player URL.
  /// Called only for a selected track while source identity is being checked.
  Future<void> prepare() async {
    if (!source.path.toLowerCase().endsWith('.m3u8')) return;
    await _manifest();
    for (final path in _segments.keys.take(2)) {
      await _servedResource(path, _routes[path]!).done;
    }
    _prepared = _segments.isNotEmpty;
  }

  Future<Uri> open() => _opening ??= _open();
  Future<Uri> _open() async {
    if (_closed) throw const ProofFailure('cancelled');
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      unawaited(_serve(request));
    });
    final hls = source.path.toLowerCase().endsWith('.m3u8');
    final path = hls
        ? '/$_token/audio.m3u8'
        : _route(
            source,
            source.path.toLowerCase().endsWith('.m4a') ? 'm4a' : 'mp3',
          );
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server!.port,
      path: path,
    );
  }

  Future<String> _manifest() => _manifestFuture ??= _buildManifest();
  Future<String> _buildManifest() async {
    var uri = source;
    HlsPlan? plan;
    for (var depth = 0; depth < 4; depth++) {
      plan = parseHls(
        utf8.decode(await fetch(uri, limit: 2 * 1024 * 1024)),
        uri,
      );
      if (plan.variant == null) break;
      uri = plan.variant!;
    }
    if (plan == null || plan.variant != null) {
      throw const ProofFailure('hls_master_depth');
    }
    final segments = <_Segment>[];
    Uri? key;
    String? iv;
    var sequence = BigInt.zero;
    var segmentStart = 0.0;
    double? segmentDuration;
    for (final line in plan.lines) {
      if (line.text.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = BigInt.parse(line.text.split(':').last);
      } else if (line.text.startsWith('#EXT-X-KEY:')) {
        final format = RegExp(r'KEYFORMAT="([^"]+)"')
            .firstMatch(line.text)
            ?.group(1);
        if (format != null && format != 'identity') {
          throw const ProofFailure('hls_encryption_unsupported');
        }
        key = line.resource;
        iv = RegExp(r'(?:[:,])IV=([^,]+)').firstMatch(line.text)?.group(1);
      } else if (line.text.startsWith('#EXTINF:')) {
        segmentDuration = double.tryParse(
          line.text.substring(8).split(',').first,
        );
        if (segmentDuration == null ||
            !segmentDuration.isFinite ||
            segmentDuration <= 0) {
          throw const ProofFailure('hls_segment_duration_invalid');
        }
      } else if (line.resourceKind == 'segment') {
        if (segmentDuration == null) {
          throw const ProofFailure('hls_segment_duration_invalid');
        }
        segments.add(
          _Segment(
            line.resource!,
            key,
            iv,
            sequence,
            (segmentStart * 90000).round(),
          ),
        );
        segmentStart += segmentDuration;
        segmentDuration = null;
        sequence += BigInt.one;
      }
    }
    if (!plan.lines.any((line) => line.resourceKind == 'init')) {
      final first = await _segmentBytes(segments.first);
      if (first != null) {
        var index = 0;
        final output = <String>[];
        for (final line in plan.lines) {
          if (line.text.startsWith('#EXT-X-KEY:')) continue;
          if (line.resourceKind != 'segment') {
            output.add(line.text);
            continue;
          }
          final path = '/$_token/segment-$index.mp3';
          _routes[path] = line.resource!;
          _segments[path] = segments[index++];
          if (index == 1) {
            final resource = _Resource();
            resource.headers(first.length);
            resource.append(first);
            resource.finish();
            resource.done = Future.value(first);
            _decoded[path] = resource;
          }
          output.add(path);
        }
        return output.join(String.fromCharCode(10)) + String.fromCharCode(10);
      }
    }
    return '${plan.lines.map((line) {
      if (line.resource == null) return line.text;
      final path = _route(line.resource!, switch (line.resourceKind) {
        'key' => 'key',
        'init' => 'mp4',
        _ => 'ts',
      });
      return line.resourceKind == 'segment' ? path : line.text.replaceFirst(RegExp('URI="[^"]+"'), 'URI="$path"');
    }).join('\n')}\n';
  }

  Future<Uint8List?> _segmentBytes(_Segment segment) async {
    final bytes = await fetch(segment.uri);
    final plain = await decryptHlsSegment(
      bytes,
      sequence: segment.sequence,
      key: segment.key == null ? null : await fetch(segment.key!),
      iv: segment.iv,
    );
    final frames = normalizeHlsMp3(plain);
    return frames == null ? null : packHlsMp3Segment(frames, segment.timestamp);
  }

  _Resource _servedResource(String path, Uri uri) {
    final segment = _segments[path];
    if (segment == null) return _resource(uri);
    return _decoded.putIfAbsent(path, () {
      final resource = _Resource();
      resource.done = _segmentBytes(segment)
          .then((bytes) {
            if (bytes == null) {
              throw const ProofFailure('hls_transport_changed');
            }
            resource.headers(bytes.length);
            resource.append(bytes);
            resource.finish();
            return bytes;
          })
          .catchError((Object error, StackTrace stack) {
            resource.finish(error);
            Error.throwWithStackTrace(error, stack);
          });
      unawaited(resource.done.then<void>((_) {}, onError: (Object _) {}));
      return resource;
    });
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (_closed ||
          !['GET', 'HEAD'].contains(request.method) ||
          request.headers.value('host') != '127.0.0.1:${_server!.port}' ||
          request.uri.hasQuery) {
        request.response.statusCode = 404;
        return;
      }
      if (request.uri.path == '/$_token/audio.m3u8') {
        final bytes = utf8.encode(await _manifest());
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.contentLength = bytes.length;
        if (request.method == 'GET') request.response.add(bytes);
        return;
      }
      final uri = _routes[request.uri.path];
      if (uri == null) {
        request.response.statusCode = 404;
        return;
      }
      final resource = _servedResource(request.uri.path, uri);
      await resource.headersReady.future;
      var length = resource.length, start = 0;
      int? end;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          request.response.statusCode = 416;
          return;
        }
        start = int.parse(match.group(1)!);
        end = int.tryParse(match.group(2)!);
        if (length == null && start > 0) {
          length = (await resource.done).length;
        }
      }
      if (length != null) {
        end = end == null ? length - 1 : min(end, length - 1);
        if (start >= length || start > end) {
          request.response.statusCode = 416;
          return;
        }
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = end - start + 1;
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
        }
      }
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      if (request.method == 'HEAD') return;
      await for (final chunk in resource.read(start, end)) {
        request.response.add(chunk);
        await request.response.flush();
      }
    } catch (_) {
      // Raw upstream/native errors may contain temporary URLs. No logging.
      try {
        request.response.statusCode = 502;
      } catch (_) {
        /* Response started. */
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Client cancelled. */
      }
    }
  }

  Future<void> close({bool cancel = false}) async {
    _closed = true;
    if (cancel) network.cancel();
    for (final resource in [..._resources.values, ..._decoded.values]) {
      resource.finish(const ProofFailure('cancelled'));
    }
    await _server?.close(force: true);
    _resources.clear();
    _routes.clear();
    _decoded.clear();
    _segments.clear();
  }
}

class _Resource {
  final chunks = <Uint8List>[];
  final headersReady = Completer<void>();
  late Future<Uint8List> done;
  Completer<void> _changed = Completer<void>();
  int? length;
  bool finished = false;
  Object? failure;
  void headers(int count) {
    if (count >= 0) length = count;
    if (!headersReady.isCompleted) headersReady.complete();
  }

  void append(Uint8List chunk) {
    chunks.add(chunk);
    _wake();
  }

  void _wake() {
    final previous = _changed;
    _changed = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  void finish([Object? error]) {
    if (finished) return;
    finished = true;
    failure = error;
    if (!headersReady.isCompleted) headersReady.complete();
    _wake();
  }

  Stream<List<int>> read(int start, int? end) async* {
    var index = 0, position = 0;
    while (true) {
      while (index < chunks.length) {
        final chunk = chunks[index++], next = position + chunk.length;
        if (next > start && (end == null || position <= end)) {
          final a = max(0, start - position),
              b = end == null
                  ? chunk.length
                  : min(chunk.length, end - position + 1);
          if (b > a) yield Uint8List.sublistView(chunk, a, b);
        }
        position = next;
        if (end != null && position > end) return;
      }
      if (finished) {
        if (failure != null) throw failure!;
        return;
      }
      await _changed.future.timeout(const Duration(seconds: 35));
    }
  }
}

class _Segment {
  final Uri uri;
  final Uri? key;
  final String? iv;
  final BigInt sequence;
  final int timestamp;
  _Segment(this.uri, this.key, this.iv, this.sequence, this.timestamp);
}
