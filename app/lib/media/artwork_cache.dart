import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'audio_policy.dart';
import 'artwork_policy.dart';
export 'artwork_policy.dart';
import '../contracts/certificate_verifier.dart';

class ArtworkResponse {
  final Uint8List bytes;
  final String mime;
  final Uri? redirect;
  const ArtworkResponse(this.bytes, this.mime, {this.redirect});
}

class _ArtworkJob {
  final Uri source;
  final int generation;
  final result = Completer<String>();
  final consumers = <bool Function()>[];
  final protected = <String>{};
  int priority;
  bool cancelled = false;
  HttpClientRequest? request;
  _ArtworkJob(this.source, this.generation, this.priority);
  bool get wanted => !cancelled && consumers.any((needed) => needed());
}

class ArtworkCache {
  final Directory directory;
  final Future<ArtworkResponse> Function(Uri)? fetch;
  final bool Function()? networkAllowed;
  final _pending = <Uri, _ArtworkJob>{};
  final _known = <Uri, String>{};
  final _waiting = <_ArtworkJob>[];
  final _active = <_ArtworkJob>{};
  final CertificateVerifier _certificate;
  HttpClient? _client;
  Future<void> _publicationTail = Future.value();
  int _generation = 0;
  bool _closed = false;
  ArtworkCache(
    this.directory, {
    this.fetch,
    this.networkAllowed,
    CertificateVerifier certificateVerifier = const StrictCertificateVerifier(),
  }) : _certificate = certificateVerifier;

  File? localFile(String? key) {
    if (key == null || !RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(key)) {
      return null;
    }
    final file = File('${directory.path}/$key');
    return FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file
        ? file
        : null;
  }

  Future<String> obtain(
    Uri source, {
    Set<String> protectedKeys = const {},
    bool Function()? needed,
    int priority = 0,
  }) {
    if (!allowedArtwork(source)) {
      return Future.error(const ProofFailure('artwork_destination_rejected'));
    }
    final old = _known[source];
    if (localFile(old) != null) return Future.value(old);
    final job = _pending.putIfAbsent(source, () {
      final fresh = _ArtworkJob(source, _generation, priority);
      _waiting.add(fresh);
      return fresh;
    });
    job.consumers.add(needed ?? () => true);
    job.protected.addAll(protectedKeys);
    if (priority > job.priority) job.priority = priority;
    scheduleMicrotask(_pump);
    return job.result.future;
  }

  void prune() {
    for (final job in _waiting.toList()) {
      if (!job.wanted || job.generation != _generation || _closed) {
        _waiting.remove(job);
        _forget(job);
        job.cancelled = true;
        job.result.completeError(const ProofFailure('cancelled'));
      }
    }
    for (final job in _active) {
      if (!job.wanted || job.generation != _generation || _closed) {
        job.cancelled = true;
        job.request?.abort();
        _forget(job);
      }
    }
  }

  void _forget(_ArtworkJob job) {
    if (identical(_pending[job.source], job)) _pending.remove(job.source);
  }

  void _pump() {
    prune();
    while (_active.length < 4 && _waiting.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _waiting.length; i++) {
        if (_waiting[i].priority > _waiting[best].priority) best = i;
      }
      final job = _waiting.removeAt(best);
      _active.add(job);
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ArtworkJob job) async {
    try {
      job.result.complete(await _download(job));
    } catch (error, stack) {
      job.result.completeError(
        job.cancelled ? const ProofFailure('cancelled') : error,
        stack,
      );
    } finally {
      _active.remove(job);
      _forget(job);
      _pump();
    }
  }

  void _check(_ArtworkJob job) {
    if (_closed || job.generation != _generation || !job.wanted) {
      throw const ProofFailure('cancelled');
    }
    if (networkAllowed?.call() == false) {
      throw const ProofFailure('offline_network_blocked');
    }
  }

  Future<String> _download(_ArtworkJob job) async {
    _check(job);
    var uri = job.source;
    ArtworkResponse? result;
    for (var hop = 0; hop < 4; hop++) {
      _check(job);
      if (!allowedArtwork(uri)) {
        throw const ProofFailure('artwork_destination_rejected');
      }
      result = await (fetch?.call(uri) ?? _fetch(uri, job));
      if (result.redirect == null) break;
      uri = result.redirect!;
      result = null;
    }
    if (result == null) throw const ProofFailure('artwork_redirect_budget');
    _check(job);
    final bytes = result.bytes;
    if (bytes.isEmpty ||
        bytes.length > 2 * 1024 * 1024 ||
        ![
          'image/png',
          'image/jpeg',
          'image/webp',
        ].contains(result.mime.toLowerCase().split(';').first)) {
      throw const ProofFailure('artwork_invalid');
    }
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width <= 0 ||
            descriptor.height <= 0 ||
            descriptor.width > 8192 ||
            descriptor.height > 8192 ||
            descriptor.width * descriptor.height > 16000000) {
          throw const ProofFailure('artwork_dimensions');
        }
        final codec = await descriptor.instantiateCodec(
          targetWidth: descriptor.width < 300 ? descriptor.width : 300,
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
    } catch (_) {
      throw const ProofFailure('artwork_decode_failed');
    }
    // Fetch/decode at most four images together; serialize only atomic disk
    // publication and quota work so identical bytes cannot race on .part files.
    final publication = _publicationTail.then((_) => _publish(bytes, job));
    _publicationTail = publication.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final key = await publication;
    _known[job.source] = key;
    if (_known.length > 8192) _known.remove(_known.keys.first);
    return key;
  }

  Future<String> _publish(Uint8List bytes, _ArtworkJob job) async {
    _check(job);
    directory.createSync(recursive: true);
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const ProofFailure('artwork_cache_path');
    }
    final key = '${sha256.convert(bytes)}.img';
    if (localFile(key) == null) {
      final partial = File('${directory.path}/$key.part');
      await partial.writeAsBytes(bytes, flush: true);
      _check(job);
      await partial.rename('${directory.path}/$key');
    }
    await _trim({...job.protected, key});
    return key;
  }

  Future<ArtworkResponse> _fetch(Uri uri, _ArtworkJob job) async {
    final client = _client ??= (HttpClient()
      ..badCertificateCallback = _certificate.accept
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 4
      ..findProxy = (_) => 'DIRECT');
    HttpClientRequest request;
    try {
      request = await client.getUrl(uri);
    } on HandshakeException {
      if (!await _certificate.verify(uri.host)) rethrow;
      request = await client.getUrl(uri);
    }
    job.request = request;
    try {
      _check(job);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Ownsemble/0.1');
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        if (location == null) throw const ProofFailure('artwork_http_failed');
        // Discard the untrusted redirect body without occupying a pooled socket.
        request.abort();
        return ArtworkResponse(
          Uint8List(0),
          '',
          redirect: uri.resolve(location),
        );
      }
      if (response.statusCode != 200 ||
          response.contentLength > 2 * 1024 * 1024) {
        throw const ProofFailure('artwork_http_failed');
      }
      final out = BytesBuilder(copy: false);
      await for (final part in response.timeout(const Duration(seconds: 6))) {
        out.add(part);
        if (out.length > 2 * 1024 * 1024) {
          throw const ProofFailure('artwork_size_budget');
        }
      }
      return ArtworkResponse(
        out.takeBytes(),
        response.headers.contentType?.mimeType ?? '',
      );
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  Future<void> _trim(Set<String> protected) async {
    final files = directory
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              RegExp(r'^[a-f0-9]{64}\.img$')
                  .hasMatch(f.uri.pathSegments.last) &&
              FileSystemEntity.typeSync(f.path, followLinks: false) ==
                  FileSystemEntityType.file,
        )
        .toList();
    files.sort(
      (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
    );
    var total = files.fold<int>(0, (n, f) => n + f.lengthSync());
    for (final file in files) {
      if (total <= 128 * 1024 * 1024) break;
      if (protected.contains(file.uri.pathSegments.last)) continue;
      final size = file.lengthSync();
      try {
        await file.delete();
        total -= size;
      } catch (_) {
        /* An open image may be retried later. */
      }
    }
  }

  void cancel() {
    _generation++;
    _client?.close(force: true);
    _client = null;
    prune();
  }

  void close() {
    _closed = true;
    cancel();
  }
}
