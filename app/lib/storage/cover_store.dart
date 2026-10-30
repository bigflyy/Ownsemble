import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// One waiting tile's interest in a cover. [cancel] drops it, for a row that
/// scrolled away before its cover came.
class CoverRequest {
  CoverRequest._(this._store, this._job, this._onDone);

  final CoverStore _store;
  final _CoverJob _job;
  final void Function(String? path) _onDone;

  void cancel() => _store._cancel(this);
}

/// A cover waiting for a download, with the tiles that want it.
class _CoverJob {
  _CoverJob(this.key, this.url);

  final String key;
  final String url;
  final requests = <CoverRequest>{};
}

/// A link's cover file name: its path and query hashed, without the host.
///
/// VK serves the same cover from a different image server on almost every
/// request, so the host says nothing about the image. FNV-1a, 64 bits.
String? coverKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  var hash = 0xcbf29ce484222325;
  for (final unit in '${uri.path}?${uri.query}'.codeUnits) {
    hash = (hash ^ unit) * 0x100000001b3;
  }
  final high = (hash >>> 32).toRadixString(16).padLeft(8, '0');
  final low = (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '$high$low';
}

/// Cover images on disk: `covers/<key>.jpg` in the data folder.
///
/// A cover is downloaded the first time a tile asks for it and kept, so it
/// works offline afterwards. Rows ask from the build path, so [storedPath]
/// answers from a set in memory and never touches the disk. At most
/// [maxDownloads] run at once and the newest request goes first: after a
/// scroll, what is on screen now matters more than what was on screen before.
class CoverStore {
  CoverStore({
    required String dataDir,
    this.maxDownloads = 4,
    this.retryAfter = const Duration(minutes: 10),
    this.offlinePause = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _dir = Directory(p.join(dataDir, 'covers')),
       _now = clock ?? DateTime.now {
    _http.connectionTimeout = const Duration(seconds: 6);
    _http.idleTimeout = const Duration(seconds: 5);
  }

  /// Longest time one download may take.
  static const downloadLimit = Duration(seconds: 15);

  /// A larger answer is not a cover.
  static const maxBytes = 4 * 1024 * 1024;

  final int maxDownloads;

  /// How long a cover that failed is not asked for again.
  final Duration retryAfter;

  /// How long no download starts after the network itself failed.
  final Duration offlinePause;

  final Directory _dir;
  final DateTime Function() _now;
  final _http = HttpClient();
  final _stored = <String>{};
  final _waiting = <String, _CoverJob>{};
  final _running = <String, _CoverJob>{};
  final _retryAt = <String, DateTime>{};
  DateTime? _pausedUntil;
  bool _loaded = false;

  /// How many covers are on disk.
  int get storedCount => _stored.length;

  /// Lists the stored covers. Requests made before this finishes wait for it.
  Future<void> load() async {
    await _dir.create(recursive: true);
    await for (final entry in _dir.list()) {
      final name = p.basename(entry.path);
      if (name.endsWith('.jpg')) {
        _stored.add(name.substring(0, name.length - '.jpg'.length));
      }
    }
    _loaded = true;
    _pump();
  }

  /// The cover's file if it is on disk.
  String? storedPath(String url) {
    final key = coverKey(url);
    return key != null && _stored.contains(key) ? _pathOf(key) : null;
  }

  /// Whether asking for [url] now would be pointless: it failed recently or
  /// the network is down.
  bool isUnavailable(String url) {
    final key = coverKey(url);
    if (key == null) return true;
    final now = _now();
    final paused = _pausedUntil;
    if (paused != null && now.isBefore(paused)) return true;
    final retry = _retryAt[key];
    return retry != null && now.isBefore(retry);
  }

  /// Asks for the cover at [url]. [onDone] gets its file, or null if it could
  /// not be had, unless the request is canceled first.
  CoverRequest? fetch(String url, void Function(String? path) onDone) {
    final key = coverKey(url);
    if (key == null) return null;
    final job = _running[key] ?? _waiting.remove(key) ?? _CoverJob(key, url);
    final request = CoverRequest._(this, job, onDone);
    job.requests.add(request);
    // Taken out and put back: the newest request stands at the end.
    if (!_running.containsKey(key)) _waiting[key] = job;
    _pump();
    return request;
  }

  void close() => _http.close(force: true);

  String _pathOf(String key) => p.join(_dir.path, '$key.jpg');

  void _cancel(CoverRequest request) {
    final job = request._job;
    job.requests.remove(request);
    // A running download finishes: the cover is small and will be wanted.
    if (job.requests.isEmpty) _waiting.remove(job.key);
  }

  void _pump() {
    if (!_loaded) return;
    while (_running.length < maxDownloads && _waiting.isNotEmpty) {
      final job = _waiting.remove(_waiting.keys.last)!;
      if (_stored.contains(job.key)) {
        _finish(job, _pathOf(job.key));
      } else if (isUnavailable(job.url)) {
        _finish(job, null);
      } else {
        _running[job.key] = job;
        unawaited(_download(job));
      }
    }
  }

  Future<void> _download(_CoverJob job) async {
    String? path;
    try {
      final bytes = await _get(job.url).timeout(downloadLimit);
      if (bytes != null) {
        final target = File(_pathOf(job.key));
        final partial = File('${target.path}.part');
        await partial.writeAsBytes(bytes);
        await partial.rename(target.path);
        _stored.add(job.key);
        path = target.path;
      } else {
        _retryAt[job.key] = _now().add(retryAfter);
      }
    } on FileSystemException {
      _retryAt[job.key] = _now().add(retryAfter);
    } catch (_) {
      // No answer at all: the other covers would fail the same slow way.
      _retryAt[job.key] = _now().add(retryAfter);
      _pausedUntil = _now().add(offlinePause);
    }
    _running.remove(job.key);
    _finish(job, path);
    _pump();
  }

  /// The image at [url], or null if the server answered with anything else.
  Future<Uint8List?> _get(String url) async {
    final request = await _http.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) return null;
    }
    final whole = bytes.takeBytes();
    final complete =
        response.contentLength < 0 || whole.length == response.contentLength;
    return complete && _looksLikeImage(whole) ? whole : null;
  }

  /// Whether [bytes] start like a JPEG, PNG or WebP file, so an error page
  /// sent with status 200 is never stored as a cover.
  static bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    final jpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    final png = bytes[0] == 0x89 && bytes[1] == 0x50;
    final webp =
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45;
    return jpeg || png || webp;
  }

  void _finish(_CoverJob job, String? path) {
    for (final request in job.requests.toList()) {
      request._onDone(path);
    }
  }
}
