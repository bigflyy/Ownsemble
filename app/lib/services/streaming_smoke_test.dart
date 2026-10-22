import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

import '../data/library_store.dart';
import '../media/audio_cache.dart';
import '../media/audio_policy.dart';
import '../media/local_audio.dart';
import '../media/streaming_audio.dart';

Future<void> runStreamingSmoke(LibraryStore store) async {
  final report = <String, Object>{
    'transport': 'aes_mp3_in_ts',
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String, int>{};
  final tone = (await rootBundle.load('assets/preview.ts')).buffer
      .asUint8List();
  final key = List<int>.filled(16, 7);
  final cipher = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
  final encrypted = (await cipher.encrypt(
    tone,
    secretKey: SecretKey(key),
    nonce: List.filled(16, 0),
  )).cipherText;
  server.listen((request) async {
    final path = request.uri.path;
    requests.update(path, (n) => n + 1, ifAbsent: () => 1);
    try {
      if (path == '/audio.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-KEY:METHOD=AES-128,URI="tone.key",IV=0x0\n${List.generate(8, (i) => '#EXTINF:4.048,\npart-$i.ts').join('\n')}\n#EXT-X-ENDLIST\n',
        );
      } else if (path == '/tone.key') {
        request.response.add(key);
      } else {
        if (path != '/part-0.ts') {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        request.response.add(encrypted);
      }
      await request.response.close();
    } catch (_) {
      /* Generated client closed. */
    }
  });
  final folder = Directory('${store.directory.path}/audio');
  final network = AudioCache(
    folder,
    decodeLocalAudio,
    fixturePort: server.port,
  );
  final source = Uri.parse('http://127.0.0.1:${server.port}/audio.m3u8');
  final stream = StreamingAudio(network, source);
  final cache = AudioCache(
    folder,
    decodeLocalAudio,
    fixturePort: server.port,
    resourceLoader: stream.fetch,
  );
  final player = newProofPlayer();
  var nativeError = false, complete = false;
  final logs = player.stream.log.listen((entry) {
    if (['error', 'fatal'].contains(entry.level)) {
      report['decoder_category'] = classifyDecoderFailure(entry.text);
      report['decoder_code'] =
          (report['decoder_code'] as int? ?? 0) | decoderSignalMask(entry.text);
    }
  });
  final errors = player.stream.error.listen((message) {
    report['native_category'] = classifyDecoderFailure(message);
    nativeError = true;
  });
  try {
    await player.setVolume(0);
    final native = player.platform as NativePlayer;
    await native.setProperty('ao', 'null');
    final track = Track(
      '900000000000003_${DateTime.now().millisecondsSinceEpoch}',
      'Generated streaming check',
      'Ownsemble',
      32.384,
    );
    final saved = cache.save(track, source).then((asset) {
      complete = true;
      return asset;
    });
    unawaited(saved.then<void>((_) {}, onError: (Object _) {}));
    final preparation = Stopwatch()..start();
    await stream.prepare();
    report['prepare_ms'] = preparation.elapsedMilliseconds;
    report['prefix_prepared'] = stream.prepared;
    final watch = Stopwatch()..start();
    await openStreamingAudio(player, await stream.open());
    await waitUntil(
      () => nativeError || player.state.position.inMilliseconds > 200,
      'stream_native_start_timeout',
      timeout: const Duration(seconds: 25),
    );
    if (nativeError) throw const ProofFailure('stream_native_error');
    report['start_ms'] = watch.elapsedMilliseconds;
    report['played_before_complete'] = !complete;
    if (complete) throw const ProofFailure('stream_waited_for_complete');
    await player.seek(const Duration(seconds: 20));
    await waitUntil(
      () =>
          nativeError ||
          (player.state.playing &&
              !player.state.buffering &&
              player.state.position.inMilliseconds >= 20200),
      'stream_seek_timeout',
      timeout: const Duration(seconds: 25),
    );
    if (nativeError) throw const ProofFailure('stream_native_error');
    report['seek'] = true;
    final asset = await saved;
    report['complete_validated'] = asset.duration > 31 && asset.bytes > 0;
    report['upstream_once'] = requests.values.every((n) => n == 1);
    await player.stop();
    await stream.close();
    cache.offline = true;
    await cache.verify(asset);
    nativeError = false;
    await openLocalAudio(player, asset.entry);
    await waitUntil(
      () => player.state.position.inMilliseconds >= 200,
      'stream_to_local_start_failed',
      timeout: const Duration(seconds: 10),
    );
    report['same_player_local_reopen'] = true;
    await player.stop();
    await checkLocalPlayer(asset.entry);
    report['offline_play_seek'] = true;
    report['passed'] =
        report['played_before_complete'] == true &&
        report['complete_validated'] == true &&
        report['upstream_once'] == true;
  } catch (e) {
    report.addAll({'passed': false, 'category': categoryOf(e)});
  } finally {
    await File('${store.directory.path}/streaming-smoke.json')
        .writeAsString(jsonEncode(report));
    await logs.cancel();
    await errors.cancel();
    await player.dispose();
    await stream.close(cancel: true);
    await server.close(force: true);
  }
  await File('${store.directory.path}/streaming-smoke.json')
      .writeAsString(jsonEncode(report));
  store.report(
    report['passed'] == true ? 'streaming_passed' : 'streaming_failed',
  );
}
