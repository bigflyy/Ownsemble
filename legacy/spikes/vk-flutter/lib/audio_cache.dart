import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'proof_core.dart';
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

class AudioCache {
  final Directory directory;
  final DecodeAudio decode;
  final int? fixturePort;
  final void Function(String)? onTransport;
  bool offline = false;
  int networkRequests = 0;
  AudioCache(this.directory, this.decode, {this.fixturePort, this.onTransport});

  Future<Uint8List> fetch(
    Uri source, {
    String userAgent = 'OwnsembleFlutterProof/0.1',
    int limit = 100 * 1024 * 1024,
  }) async {
    if (offline) throw const ProofFailure('offline_network_blocked');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 25);
    try {
      var uri = source;
      for (var hop = 0; hop < 6; hop++) {
        if (!allowedAudio(uri, fixturePort: fixturePort)) {
          throw const ProofFailure('audio_destination_rejected');
        }
        if (userAgent.length > 512 || userAgent.contains(RegExp(r'[\r\n]'))) {
          throw const ProofFailure('user_agent_invalid');
        }
        networkRequests++;
        final request = await client.getUrl(uri);
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
          await response.drain<void>();
          continue;
        }
        if (response.statusCode != 200) {
          throw const ProofFailure('audio_http_failed');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final part in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes.add(part);
          if (bytes.length > limit) {
            throw const ProofFailure('audio_size_budget');
          }
        }
        if (bytes.isEmpty) throw const ProofFailure('audio_empty');
        return bytes.takeBytes();
      }
      throw const ProofFailure('audio_redirect_budget');
    } on ProofFailure {
      rethrow;
    } catch (_) {
      throw const ProofFailure('audio_network_failed');
    } finally {
      client.close(force: true);
    }
  }

  Future<CachedAudio> save(
    Track track,
    Uri source, {
    String userAgent = 'OwnsembleFlutterProof/0.1',
  }) async {
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(track.id)) {
      throw const ProofFailure('invalid_music_metadata');
    }
    await directory.create(recursive: true);
    final staging = Directory('${directory.path}/${track.id}.partial');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    try {
      var entry = 'audio.mp3';
      if (source.path.toLowerCase().endsWith('.m3u8')) {
        var uri = source;
        HlsPlan? plan;
        for (var depth = 0; depth < 4; depth++) {
          plan = parseHls(
            utf8.decode(
              await fetch(uri, userAgent: userAgent, limit: 2 * 1024 * 1024),
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
        entry =
            await materializeHlsAudio(
              staging,
              output,
              onTransport: onTransport,
            ) ??
            entry;
      } else {
        if (!RegExp(
          r'\.(?:mp3|m4a|wav)$',
          caseSensitive: false,
        ).hasMatch(source.path)) {
          throw const ProofFailure('audio_format_unsupported');
        }
        entry = source.path.toLowerCase().endsWith('.wav')
            ? 'audio.wav'
            : source.path.toLowerCase().endsWith('.m4a')
            ? 'audio.m4a'
            : 'audio.mp3';
        await File(
          '${staging.path}/$entry',
        ).writeAsBytes(await fetch(source, userAgent: userAgent), flush: true);
      }
      final duration = await decode('${staging.path}/$entry');
      if (duration <= 0 ||
          (track.duration > 0 && duration < track.duration - 5)) {
        throw const ProofFailure('audio_incomplete');
      }
      if (entry != 'audio.m3u8' &&
          source.path.toLowerCase().endsWith('.m3u8')) {
        // The complete normalized MP3 passed strict decoding. Publish that one
        // asset; generated transport segments and keys are no longer needed.
        await for (final item in staging.list()) {
          if (item is File && item.uri.pathSegments.last != entry) {
            await item.delete();
          }
        }
      }
      final integrity = await _integrity(staging);
      await File('${staging.path}/integrity.json')
          .writeAsString(jsonEncode(integrity.$3), flush: true);
      final published = Directory('${directory.path}/${track.id}');
      if (await published.exists()) {
        throw const ProofFailure('cache_already_exists');
      }
      await staging.rename(published.path);
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

  Future<void> verify(CachedAudio asset) async {
    final folder = File(asset.entry).parent;
    final expected = jsonDecode(
      await File('${folder.path}/integrity.json').readAsString(),
    );
    final actual = await _integrity(folder);
    if (actual.$1 != asset.digest ||
        actual.$2 != asset.bytes ||
        jsonEncode(actual.$3) != jsonEncode(expected)) {
      throw const ProofFailure('cache_integrity_failed');
    }
    await decode(asset.entry);
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
      if (duration <= 0 ||
          track.duration > 0 && duration < track.duration - 5) {
        throw const ProofFailure('audio_incomplete');
      }
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
