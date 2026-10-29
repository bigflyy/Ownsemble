import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';

import 'controller_ports_test.dart' show PortablePlayback;
import 'support/fixture_provider.dart';

/// Redirect only the generated approved source to the isolated local test server.
class GeneratedAudioClient implements HttpClient {
  // Delegate socket behavior without modifying production destination or TLS policy.
  final HttpClient delegate;
  // Restrict generated upstream requests to this one fixture listener.
  final int port;

  /// Keep all requests inside the test process while exercising real streaming IO.
  GeneratedAudioClient(this.delegate, this.port);

  /// Rewrite only the synthetic provider host; local relay requests remain local.
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => delegate.getUrl(
    uri.host == 'generated.vkuseraudio.net'
        ? Uri.parse('http://127.0.0.1:$port${uri.path}')
        : uri,
  );

  /// Forward the cache's normal certificate callback without disabling its policy.
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) {
    delegate.badCertificateCallback = value;
  }

  /// Preserve normal bounded connection behavior in the generated transport.
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;

  /// Keep loopback fixtures independent from machine proxy configuration.
  @override
  set findProxy(String Function(Uri)? value) => delegate.findProxy = value;

  /// Release only this test's sockets during ordinary cancellation.
  @override
  void close({bool force = false}) => delegate.close(force: force);

  /// Fail unexpected client operations instead of silently adding test capabilities.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Resolve an exact generated recording without any browser or account data.
class GeneratedSourceProvider extends FixtureProvider {
  /// Keep connection consent and private-session logic outside this cache regression.
  GeneratedSourceProvider() {
    connected = true;
  }

  /// Bind the synthetic source to the requested recording using the production contract.
  @override
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) async => ResolvedAudio(
    Uri.parse('https://generated.vkuseraudio.net/audio.mp3'),
    'Generated',
    recordingId: track.id,
    evidence: 'metadata_row',
  );
}

/// Read an actual relay prefix while producing no physical audio output.
class PrefixPlayback extends PortablePlayback {
  // Retain only generated prefix bytes to reject accidental use of the legacy file.
  List<int>? prefix;
  // Count generated relay opens separately from local cache replay.
  int streamOpens = 0;

  /// Acknowledge playback only after the new source has supplied real initial bytes.
  @override
  Future<void> openStream(Uri uri, {bool play = true}) async {
    streamOpens++;
    // Use the same isolated HTTP override for this generated local player request.
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    // Read one prefix without waiting for the deliberately held response tail.
    final response = await (await client.getUrl(uri)).close();
    prefix = await response.first;
    position = const Duration(milliseconds: 250);
    playing = play;
    changes.add(playing);
  }
}

/// Verify early streaming when an existing cache requires online identity replacement.
void main() {
  test('unverified saved audio streams its exact replacement before download completion', () async {
    // Preserve all generated files in an isolated application-like directory.
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-legacy-stream-',
    );
    // Hold the response tail to expose an accidental full-download prerequisite.
    final tail = Completer<void>();
    // Signal that the selected replacement's prefix has arrived.
    final prefixSent = Completer<void>();
    // Use a real local server, without contacting a provider or exposing audio URLs.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 8;
      request.response.add([1, 2, 3, 4]);
      await request.response.flush();
      // Signal the first received generated request only once.
      if (!prefixSent.isCompleted) prefixSent.complete();
      await tail.future;
      request.response.add([5, 6, 7, 8]);
      await request.response.close();
    });
    // Create the underlying client before installing the test-only redirect override.
    final sockets = HttpClient()..findProxy = (_) => 'DIRECT';
    // Keep one stable recording identity across the legacy and replacement assets.
    const track = Track('17_1', 'Generated old recording', 'Fixture', 10);
    // Prepare an intentionally unverified legacy cache with different generated bytes.
    final legacyCache = AudioCache(
      Directory('${folder.path}/audio'),
      (_) async => 10,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList([9, 9, 9, 9]),
    );
    // Keep the old asset in place until the exact new recording passes complete validation.
    final legacy = await legacyCache.save(
      track,
      Uri.parse('https://generated.vkuseraudio.net/legacy.mp3'),
    );
    // Register the preexisting asset without manufacturing an identity receipt.
    final store = LibraryStore(folder)
      ..merge([track])
      ..saveAsset(legacy);
    // Use an actual controller with a silent generated playback engine.
    final player = PrefixPlayback();
    // Retain startup completion independently of the held whole-download promise.
    var started = false;
    try {
      await HttpOverrides.runZoned(() async {
        // Run the actual cache/revalidation/relay policy rather than overriding ensureAsset.
        final controller = AppController(
          store,
          playbackPlayer: player,
          musicProvider: GeneratedSourceProvider(),
          decodeAudio: (_) async => 10,
          diagnosticStore: DiagnosticStore.memory(),
        );
        // Preserve the complete-download future for cleanup after either test outcome.
        Future<void>? playing;
        try {
          controller.queue.replace([QueueEntry(track.id)], 0);
          playing = controller.playCurrent().then((_) => started = true);
          await prefixSent.future.timeout(const Duration(seconds: 3));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(
            started,
            isTrue,
            reason:
                'Legacy replacement must not wait for the held whole-file tail',
          );
          expect(player.prefix, [1, 2, 3, 4]);
          expect(File(legacy.entry).readAsBytesSync(), [9, 9, 9, 9]);
          expect(
            File('${File(legacy.entry).parent.path}/recording.json')
                .existsSync(),
            isFalse,
          );
          // Finish publication after early playback and legacy preservation were proven.
          tail.complete();
          // Retain the newly verified replacement for an ordinary cached replay.
          final repaired = await controller.ensureAsset(track);
          // A completed relay cannot hide the valid local cache on the next Play.
          final streamOpens = player.streamOpens;
          await controller.playCurrent();
          expect(player.opened.last, repaired.entry);
          expect(player.streamOpens, streamOpens);
        } finally {
          // Release generated network work even when the intended regression fails.
          if (!tail.isCompleted) tail.complete();
          await playing;
          await controller.shutdown();
        }
      }, createHttpClient: (_) => GeneratedAudioClient(sockets, server.port));
    } finally {
      legacyCache.cancel();
      sockets.close(force: true);
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  });
}
