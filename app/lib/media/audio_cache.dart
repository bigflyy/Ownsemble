import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../contracts/certificate_verifier.dart';

import 'audio_policy.dart';
import 'hls_mp3.dart';

class CachedAudio {
  final String id, entry, digest;
  final int bytes;
  final double duration;
  const CachedAudio(
    this.id,
    this.entry,
    this.digest,
    this.bytes,
    this.duration,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'entry': entry,
    'digest': digest,
    'bytes': bytes,
    'duration': duration,
  };
}

typedef DecodeAudio = Future<double> Function(String path);
typedef AudioResourceLoader = Future<Uint8List> Function(
  Uri source, {
  required String userAgent,
  required int limit,
});

class AudioCache {
  final CertificateVerifier _platformCertificate;
  final Directory directory;
  final DecodeAudio decode;
  final int? fixturePort;
  final void Function(String)? onTransport;
  final bool Function()? cancelled;
  final void Function(int)? onProgress;
  final void Function(String)? onStage;
  final AudioResourceLoader? resourceLoader;
  int transferred = 0;
  bool _cancelled = false;
  HttpClient? _client;
  Timer? _idleClose;
  int _activeFetches = 0;
  void cancel() {
    _cancelled = true;
    _idleClose?.cancel();
    _client?.close(force: true);
    _client = null;
  }

  bool offline = false;
  int networkRequests = 0;
  AudioCache(
    this.directory,
    this.decode, {
    this.fixturePort,
    this.onTransport,
    this.cancelled,
    this.onProgress,
    this.onStage,
    this.resourceLoader,
    CertificateVerifier certificateVerifier = const StrictCertificateVerifier(),
  }) : _platformCertificate = certificateVerifier;

  Future<Uint8List> fetch(
    Uri source, {
    String userAgent = 'Ownsemble/0.1',
    int limit = 100 * 1024 * 1024,
    void Function(int)? onHeaders,
    void Function(Uint8List)? onChunk,
  }) async {
    if (_cancelled || cancelled?.call() == true) {
      throw const ProofFailure('cancelled');
    }
    if (offline) throw const ProofFailure('offline_network_blocked');
    if (!allowedAudio(source, fixturePort: fixturePort)) {
      throw AudioDestinationFailure(source, redirect: false);
    }
    if (resourceLoader != null) {
      return resourceLoader!(source, userAgent: userAgent, limit: limit);
    }
    // Share this download's TLS connections across manifest/key/segments.
    // Every hop still passes the destination guard; no account cookies/headers
    // are attached. Stop closes the pool, and idle pools expire after 2 seconds.
    _idleClose?.cancel();
    final client = _client ??= (HttpClient()
      ..badCertificateCallback = _platformCertificate.accept
      ..connectionTimeout = const Duration(seconds: 25)
      ..findProxy = (_) => 'DIRECT');
    _activeFetches++;
    try {
      var uri = source;
      for (var hop = 0; hop < 6; hop++) {
        if (!allowedAudio(uri, fixturePort: fixturePort)) {
          throw AudioDestinationFailure(uri, redirect: hop > 0);
        }
        if (userAgent.length > 512 || userAgent.contains(RegExp(r'[\r\n]'))) {
          throw const ProofFailure('user_agent_invalid');
        }
        networkRequests++;
        HttpClientRequest request;
        try {
          request = await client.getUrl(uri);
        } on HandshakeException {
          if (!await _platformCertificate.verify(uri.host)) rethrow;
          if (_cancelled || cancelled?.call() == true) {
            throw const ProofFailure('cancelled');
          }
          request = await client.getUrl(uri);
        }
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) {
            throw const ProofFailure('audio_redirect_invalid');
          }
          uri = uri.resolve(location);
          await response.drain<void>().timeout(const Duration(seconds: 30));
          continue;
        }
        if (response.statusCode != 200) {
          throw ProofFailure('audio_http_failed', code: response.statusCode);
        }
        onHeaders?.call(response.contentLength);
        final bytes = BytesBuilder(copy: false);
        await for (final part in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (cancelled?.call() == true) throw const ProofFailure('cancelled');
          bytes.add(part);
          transferred += part.length;
          onProgress?.call(transferred);
          if (bytes.length > limit) {
            throw const ProofFailure('audio_size_budget');
          }
          onChunk?.call(Uint8List.fromList(part));
        }
        if (bytes.isEmpty) throw const ProofFailure('audio_empty');
        return bytes.takeBytes();
      }
      throw const ProofFailure('audio_redirect_budget');
    } on ProofFailure {
      rethrow;
    } catch (error) {
      if (_cancelled || cancelled?.call() == true) {
        throw const ProofFailure('cancelled');
      }
      throw ProofFailure(switch (error) {
        HandshakeException() =>
          error.toString().toLowerCase().contains('certificate_verify_failed')
              ? 'audio_certificate_failed'
              : 'audio_tls_failed',
        SocketException() => 'audio_socket_failed',
        HttpException() => 'audio_connection_failed',
        TimeoutException() => 'audio_network_timeout',
        _ => 'audio_network_failed',
      }, code: error is SocketException ? error.osError?.errorCode : null);
    } finally {
      _activeFetches--;
      if (_activeFetches == 0 && identical(_client, client) && !_cancelled) {
        _idleClose = Timer(const Duration(seconds: 2), () {
          client.close();
          if (identical(_client, client)) _client = null;
        });
      }
    }
  }

  Future<CachedAudio> save(
    Track track,
    Uri source, {
    String userAgent = 'Ownsemble/0.1',
    String? recordingEvidence,
    bool preserveExisting = false,
  }) async {
    if (recordingEvidence != null &&
        !recordingEvidenceKinds.contains(recordingEvidence)) {
      throw const ProofFailure('audio_identity_unverified');
    }
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(track.id)) {
      throw const ProofFailure('invalid_music_metadata');
    }
    await directory.create(recursive: true);
    final staging = Directory('${directory.path}/${track.id}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    try {
      onStage?.call('receiving');
      var entry = 'audio.mp3';
      // Reuse opaque source bytes after classification instead of requesting them twice.
      final initialBytes = !hasAudioFilename(source)
          ? await fetch(source, userAgent: userAgent)
          : null;
      // Detect opaque endpoint format from shared bytes, never from signed query values.
      final hls =
          source.path.toLowerCase().endsWith('.m3u8') ||
          initialBytes != null && isHlsPrefix(initialBytes);
      // Materialize HLS resources only after positively identifying a manifest.
      if (hls) {
        var uri = source;
        HlsPlan? plan;
        for (var depth = 0; depth < 4; depth++) {
          plan = parseHls(
            utf8.decode(
              depth == 0 && initialBytes != null
                  ? initialBytes
                  : await fetch(
                      uri,
                      userAgent: userAgent,
                      limit: 2 * 1024 * 1024,
                    ),
            ),
            uri,
          );
          if (plan.variant == null) break;
          uri = plan.variant!;
        }
        if (plan == null || plan.variant != null) {
          throw const ProofFailure('hls_master_depth');
        }
        final names = <Uri, String>{};
        final output = <String>[];
        var total = 0;
        for (final line in plan.lines) {
          final resource = line.resource;
          if (resource == null) {
            output.add(line.text);
            continue;
          }
          var name = names[resource];
          if (name == null) {
            final ext = line.resourceKind == 'key'
                ? 'key'
                : line.resourceKind == 'init'
                ? 'mp4'
                : 'ts';
            name = 'part-${names.length}.$ext';
            final bytes = await fetch(resource, userAgent: userAgent);
            total += bytes.length;
            if (total > 100 * 1024 * 1024) {
              throw const ProofFailure('audio_size_budget');
            }
            if (line.resourceKind == 'key' && bytes.length != 16) {
              throw const ProofFailure('hls_key_invalid');
            }
            await File('${staging.path}/$name')
                .writeAsBytes(bytes, flush: true);
            names[resource] = name;
          }
          output.add(
            line.resourceKind == 'segment'
                ? name
                : line.text.replaceFirst(RegExp(r'URI="[^"]+"'), 'URI="$name"'),
          );
        }
        entry = 'audio.m3u8';
        await File('${staging.path}/$entry')
            .writeAsString('${output.join('\n')}\n', flush: true);
        onStage?.call('materializing');
        entry =
            await materializeHlsAudio(
              staging,
              output,
              onTransport: onTransport,
            ) ??
            entry;
      } else {
        // Keep opaque progressive audio under a local name; full decoding still gates publication.
        entry = source.path.toLowerCase().endsWith('.wav')
            ? 'audio.wav'
            : source.path.toLowerCase().endsWith('.m4a')
            ? 'audio.m4a'
            : 'audio.mp3';
        await File('${staging.path}/$entry').writeAsBytes(
          initialBytes ?? await fetch(source, userAgent: userAgent),
          flush: true,
        );
      }
      onStage?.call('decoding');
      final duration = await decode('${staging.path}/$entry');
      verifyRecordingDuration(duration, track.duration);
      if (entry != 'audio.m3u8' && hls) {
        // The complete normalized MP3 passed strict decoding. Publish that one
        // asset; generated transport segments and keys are no longer needed.
        await for (final item in staging.list()) {
          if (item is File && item.uri.pathSegments.last != entry) {
            await item.delete();
          }
        }
      }
      onStage?.call('publishing');
      if (recordingEvidence != null) {
        await File('${staging.path}/recording.json').writeAsString(
          jsonEncode({
            'version': 1,
            'id': track.id,
            'evidence': recordingEvidence,
            'expected_duration': track.duration,
          }),
          flush: true,
        );
      }
      final integrity = await _integrity(staging);
      await File('${staging.path}/integrity.json')
          .writeAsString(jsonEncode(integrity.$3), flush: true);
      final published = Directory('${directory.path}/${track.id}');
      if (_cancelled || cancelled?.call() == true) {
        throw const ProofFailure('cancelled');
      }
      if (await published.exists()) {
        if (!preserveExisting) throw const ProofFailure('cache_already_exists');
        await _replacePreserving(published, staging, track.id);
      } else {
        await staging.rename(published.path);
      }
      return CachedAudio(
        track.id,
        '${published.path}/$entry',
        integrity.$1,
        integrity.$2,
        duration,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _replacePreserving(
    Directory published,
    Directory staging,
    String id,
  ) async {
    final root = Directory(await directory.resolveSymbolicLinks()).uri;
    if (await FileSystemEntity.type(published.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Directory(await published.resolveSymbolicLinks()).uri !=
            root.resolve('$id/')) {
      throw const ProofFailure('cache_path_invalid');
    }
    final quarantine = Directory('${directory.path}/quarantine');
    await quarantine.create();
    if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Directory(await quarantine.resolveSymbolicLinks()).uri !=
            root.resolve('quarantine/')) {
      throw const ProofFailure('cache_path_invalid');
    }
    final backup = await published.rename(
      '${quarantine.path}/$id-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      if (_cancelled || cancelled?.call() == true) {
        throw const ProofFailure('cancelled');
      }
      await staging.rename(published.path);
    } catch (_) {
      if (!await published.exists()) await backup.rename(published.path);
      rethrow;
    }
  }

  Future<(String, int, Map<String, String>)> _integrity(
    Directory folder,
  ) async {
    final files = await folder
        .list()
        .where((e) => e is File && !e.path.endsWith('integrity.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    final digests = <String, String>{};
    var bytes = 0;
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      digests[name] = (await sha256.bind(file.openRead()).first).toString();
      bytes += await file.length();
    }
    return (
      sha256.convert(utf8.encode(jsonEncode(digests))).toString(),
      bytes,
      digests,
    );
  }

  Future<void> verify(
    CachedAudio asset, {
    Track? expectedTrack,
    bool requireIdentity = false,
  }) async {
    if (expectedTrack != null && expectedTrack.id != asset.id) {
      throw const ProofFailure('audio_identity_mismatch');
    }
    final folder = File(asset.entry).parent;
    if (requireIdentity) {
      final receipt = File('${folder.path}/recording.json');
      if (!receipt.existsSync()) {
        throw const ProofFailure('cache_identity_unverified');
      }
      try {
        final proof = jsonDecode(await receipt.readAsString());
        if (proof is! Map ||
            proof['version'] != 1 ||
            proof['id'] != asset.id ||
            !recordingEvidenceKinds.contains(proof['evidence'])) {
          throw const ProofFailure('audio_identity_mismatch');
        }
      } on ProofFailure {
        rethrow;
      } catch (_) {
        throw const ProofFailure('cache_identity_unverified');
      }
    }
    final expected = jsonDecode(
      await File('${folder.path}/integrity.json').readAsString(),
    );
    final actual = await _integrity(folder);
    if (actual.$1 != asset.digest ||
        actual.$2 != asset.bytes ||
        jsonEncode(actual.$3) != jsonEncode(expected)) {
      throw const ProofFailure('cache_integrity_failed');
    }
    final duration = await decode(asset.entry);
    if (expectedTrack != null) {
      verifyRecordingDuration(duration, expectedTrack.duration);
    }
  }

  Future<CachedAudio> importLocal(
    Track track,
    File source,
    String expectedHash,
  ) async {
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(track.id)) {
      throw const ProofFailure('invalid_music_metadata');
    }
    if ((await sha256.bind(source.openRead()).first).toString() !=
        expectedHash) {
      throw const ProofFailure('legacy_hash_mismatch');
    }
    final target = Directory('${directory.path}/${track.id}');
    if (await target.exists()) throw const ProofFailure('cache_already_exists');
    final staging = Directory('${directory.path}/${track.id}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      final name = source.path.endsWith('.m4a') ? 'audio.m4a' : 'audio.mp3';
      await source.copy('${staging.path}/$name');
      final duration = await decode('${staging.path}/$name');
      verifyRecordingDuration(duration, track.duration);
      final integrity = await _integrity(staging);
      await File('${staging.path}/integrity.json')
          .writeAsString(jsonEncode(integrity.$3), flush: true);
      await staging.rename(target.path);
      return CachedAudio(
        track.id,
        '${target.path}/$name',
        integrity.$1,
        integrity.$2,
        duration,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }
}
