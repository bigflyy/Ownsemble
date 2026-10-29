import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

import '../media/audio_cache.dart';
import '../media/audio_policy.dart';
import '../media/hls_mp3.dart';
import '../media/local_audio.dart';
import '../media/streaming_audio.dart';

/// Require native playback from a generated prefix while the response tail stalls.
Future<Map<String, Object>> probeProgressiveStartup() async {
  // Keep the fixture result independent of private catalog or provider state.
  final report = <String, Object>{};
  // Reuse generated MPEG frames rather than reading any saved user audio.
  final transport = (await rootBundle.load('assets/preview.ts')).buffer
      .asUint8List();
  // Remove transport headers while preserving complete encoded audio frames.
  final frames = normalizeHlsMp3(transport)!;
  // Make the response much longer than the initial playable prefix.
  final payload = BytesBuilder(copy: false);
  for (var repetition = 0; repetition < 80; repetition++) {
    payload.add(frames);
  }
  // Advertise the complete size without making its last bytes available yet.
  final bytes = payload.takeBytes();
  // Release the tail on a timer so the regression can report a bounded failure.
  final tail = Completer<void>();
  // Count whether native probing caused duplicate upstream downloads.
  var requests = 0;
  // Distinguish native startup from completion of the upstream body.
  var complete = false;
  // Listen only on loopback for this generated fixture.
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    requests++;
    try {
      request.response.bufferOutput = false;
      request.response.contentLength = bytes.length;
      request.response.add(bytes.sublist(0, 65536));
      await request.response.flush();
      await tail.future;
      request.response.add(bytes.sublist(65536));
      await request.response.close();
      complete = true;
    } catch (_) {
      // Allow the fixture's cancellation check to close its own request.
    }
  });
  // Use production relay and native opening policies with a fixture-only upstream.
  final network = AudioCache(
    Directory.systemTemp,
    decodeLocalAudio,
    fixturePort: server.port,
  );
  // Exercise opaque progressive endpoints as exposed by the current provider.
  final stream = StreamingAudio(
    network,
    Uri.parse('http://127.0.0.1:${server.port}/opaque'),
  );
  // Keep every native sample inaudible even if platform volume changes.
  final player = newProofPlayer();
  // Observe only generated loopback range offsets to distinguish tail probes from decoding.
  final ranges = <int>[];
  // Forward the generated native request through the unchanged production relay.
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // Keep fixture traffic local even when the host defines a network proxy.
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  // Resolve the token-scoped relay only when native opening begins.
  Uri? relay;
  proxy.listen((request) async {
    try {
      // Preserve native range semantics while recording numeric offsets only.
      final range = request.headers.value(HttpHeaders.rangeHeader);
      // Accept only the fixed byte-range shape emitted by this generated player.
      final start = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-').firstMatch(range)?.group(1);
      // Retain at most sixteen numeric offsets for this short fixture.
      if (start != null && ranges.length < 16) ranges.add(int.parse(start));
      // Forward to the already opened generated production relay.
      final forwarded = await client.openUrl(request.method, relay!);
      // Copy only the range header needed by the native fixture.
      if (range != null) forwarded.headers.set(HttpHeaders.rangeHeader, range);
      // Preserve the relay's status and response headers, including length and ranges.
      final response = await forwarded.close();
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        request.response.headers.set(name, values);
      });
      request.response.bufferOutput = false;
      await for (final chunk in response) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    } catch (_) {
      // Allow native disposal to cancel its own generated requests without raw logging.
    }
  });
  // Bound the deliberate stall without depending on the real network.
  final release = Timer(const Duration(seconds: 6), () => tail.complete());
  // Measure production native startup, including format detection and relay open.
  final watch = Stopwatch();
  try {
    await player.setVolume(0);
    // Disable the audio device in addition to setting the fixture volume to zero.
    final native = player.platform as NativePlayer;
    await native.setProperty('ao', 'null');
    watch.start();
    relay = await stream.open();
    await openStreamingAudio(player, relay.replace(port: proxy.port));
    await waitUntil(
      () => player.state.position.inMilliseconds >= 200,
      'stream_native_start_timeout',
      timeout: const Duration(seconds: 12),
    );
    report['silent'] = await native.getProperty('ao') == 'null';
    report.addAll({
      'start_ms': watch.elapsedMilliseconds,
      'played_before_tail': !tail.isCompleted,
      'played_before_complete': !complete,
      'upstream_requests': requests,
      'native_range_starts': ranges,
      'passed':
          !tail.isCompleted &&
          !complete &&
          requests == 1 &&
          report['silent'] == true,
    });
    // Verify an ordinary buffered seek without releasing the deliberately stalled tail.
    await player.seek(const Duration(seconds: 2));
    await waitUntil(
      () => player.state.position.inMilliseconds >= 2200,
      'stream_seek_timeout',
      timeout: const Duration(seconds: 3),
    );
    report['seek_before_tail'] = !tail.isCompleted;
    release.cancel();
    // Finish the same upstream request before testing a later unbuffered seek.
    if (!tail.isCompleted) tail.complete();
    await stream.fetch(stream.source);
    await player.seek(const Duration(seconds: 20));
    await waitUntil(
      () => player.state.position.inMilliseconds >= 20200,
      'stream_seek_timeout',
      timeout: const Duration(seconds: 5),
    );
    report['seek_after_complete'] = true;
    report['passed'] =
        report['passed'] == true && report['seek_before_tail'] == true;
  } catch (error) {
    report.addAll({'passed': false, 'category': categoryOf(error)});
  } finally {
    release.cancel();
    // Release the fixture server even when native initialization fails early.
    if (!tail.isCompleted) tail.complete();
    await player.dispose();
    client.close(force: true);
    await proxy.close(force: true);
    await stream.close(cancel: true);
    await server.close(force: true);
  }
  return report;
}
