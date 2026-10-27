import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';
import 'package:ownsemble/services/playback_queue.dart';

import 'controller_ports_test.dart' show PortablePlayback;
import 'legacy_cache_streaming_test.dart' show GeneratedAudioClient;
import 'support/fixture_provider.dart';

class FixtureHttpOverrides extends HttpOverrides {}

class RecoveringSourceProvider extends FixtureProvider
    implements RejectedSourceRecovery {
  bool rejected = false;
  int resolutions = 0, rejections = 0;
  final identities = <String>[];
  Future<ResolvedAudio>? recoveryResponse;
  final recoveryStarted = Completer<void>();
  RecoveringSourceProvider() {
    connected = true;
  }
  @override
  bool rejectSource(String id, Uri source) {
    rejections++;
    if (rejected || source.path != '/reference.mp3') return false;
    rejected = true;
    return true;
  }

  @override
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) async {
    resolutions++;
    identities.add(track.id);
    if (rejected && track.id == '17_1') {
      if (!recoveryStarted.isCompleted) recoveryStarted.complete();
      if (recoveryResponse != null) return recoveryResponse!;
    }
    return ResolvedAudio(
      Uri.parse(
        'https://generated.vkuseraudio.net/${rejected ? 'current' : 'reference'}.mp3',
      ),
      'Generated',
      recordingId: track.id,
      evidence: rejected ? 'metadata_row' : 'exact_reload',
    );
  }
}

class SilentRelayPlayback extends PortablePlayback {
  @override
  Future<void> openStream(Uri uri, {bool play = true}) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final response = await (await client.getUrl(uri)).close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw const ProofFailure('decoder_open_failed');
      }
      await response.first;
      position = const Duration(milliseconds: 250);
      playing = play;
      changes.add(playing);
    } finally {
      client.close(force: true);
    }
  }
}

class CleanupGatePlayback extends SilentRelayPlayback {
  final Future<void> decodingStarted;
  final failedOpen = Completer<void>();
  CleanupGatePlayback(this.decodingStarted);
  @override
  Future<void> openStream(Uri uri, {bool play = true}) async {
    await decodingStarted;
    failedOpen.complete();
    throw AudioDestinationFailure(
      Uri.parse('https://vk.com/generated-not-media'),
      redirect: true,
    );
  }
}

Future<void> deleteGeneratedFolder(Directory folder) async {
  // A cancelled native decode can finish its staging-file cleanup after its waiter.
  for (var attempt = 0; ; attempt++) {
    try {
      await folder.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}

Future<void> withGeneratedRecovery(
  Future<void> Function(AppController, RecoveringSourceProvider, LibraryStore)
  run, {
  SilentRelayPlayback? player,
  Future<double> Function(String)? decode,
  bool rejectReference = true,
  Duration referenceDelay = Duration.zero,
  Duration startupTimeout = const Duration(seconds: 3),
}) async {
  final folder = await Directory.systemTemp.createTemp(
    'ownsemble-recovery-ownership-',
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path == '/reference.mp3') {
      await Future<void>.delayed(referenceDelay);
    }
    if (rejectReference && request.uri.path == '/reference.mp3') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'https://vk.com/generated-not-media',
      );
    } else {
      request.response.contentLength = 8;
      request.response.add([1, 2, 3, 4, 5, 6, 7, 8]);
    }
    await request.response.close();
  });
  final baseHttp = HttpOverrides.current ?? FixtureHttpOverrides();
  final clients = <HttpClient>[];
  final store = LibraryStore(folder)
    ..merge([
      const Track('17_1', 'Generated', 'Fixture', 10),
      const Track('17_2', 'Other', 'Fixture', 10),
      const Track('17_3', 'Third', 'Fixture', 10),
    ])
    ..setSetting('auto_sync', false);
  final provider = RecoveringSourceProvider();
  try {
    await HttpOverrides.runZoned(
      () async {
        final controller = AppController(
          store,
          playbackPlayer: player ?? SilentRelayPlayback(),
          musicProvider: provider,
          decodeAudio: decode ?? (_) async => 10,
          startupTimeout: startupTimeout,
          diagnosticStore: DiagnosticStore.memory(),
        );
        controller.queue.replace([const QueueEntry('17_1', 7)], 0);
        try {
          await run(controller, provider, store);
        } finally {
          await controller.shutdown();
        }
      },
      createHttpClient: (context) {
        final client = baseHttp.createHttpClient(context)
          ..findProxy = (_) => 'DIRECT';
        clients.add(client);
        return GeneratedAudioClient(client, server.port);
      },
    );
  } finally {
    for (final client in clients) {
      client.close(force: true);
    }
    await server.close(force: true);
    await deleteGeneratedFolder(folder);
  }
}

void main() {
  test(
    'Stop cancels recovery and late completion cannot replace a newer song',
    () async {
      final late = Completer<ResolvedAudio>();
      await withGeneratedRecovery((controller, provider, store) async {
        provider.recoveryResponse = late.future;
        final oldPlay = controller.playCurrent(diagnostic: true);
        await provider.recoveryStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await controller.stopPlayback(diagnostic: true);
        await oldPlay.timeout(const Duration(seconds: 1));
        controller.queue.replace([const QueueEntry('17_2')], 0);
        await controller.playCurrent(diagnostic: true);
        late.complete(
          ResolvedAudio(
            Uri.parse('https://generated.vkuseraudio.net/current.mp3'),
            'Generated',
            recordingId: '17_1',
            evidence: 'metadata_row',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller.current!.id, '17_2');
        expect(controller.player.state.playing, isTrue);
        expect(store.asset('17_1'), isNull);
        expect(provider.identities, ['17_1', '17_1', '17_2']);
      });
    },
  );

  test('source recovery consumes the original startup budget', () async {
    final late = Completer<ResolvedAudio>();
    await withGeneratedRecovery(
      (controller, provider, store) async {
        provider.recoveryResponse = late.future;
        final play = controller.playCurrent(diagnostic: true);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          expect(provider.recoveryStarted.isCompleted, isTrue);
          expect(
            controller.loading,
            isFalse,
            reason: 'A 250ms first attempt cannot reset the 600ms deadline',
          );
          await play.timeout(const Duration(seconds: 1));
        } finally {
          late.completeError(const ProofFailure('cancelled'));
        }
      },
      startupTimeout: const Duration(milliseconds: 600),
      referenceDelay: const Duration(milliseconds: 250),
    );
  });

  test('failed current discovery retains the original destination rejection', () async {
    await withGeneratedRecovery((controller, provider, store) async {
      provider.recoveryResponse = Future<ResolvedAudio>.error(
        const ProofFailure('music_search_unsupported'),
      );
      // Attach a handler before the deliberately delayed first transport fails.
      unawaited(
        provider.recoveryResponse!.then<void>((_) {}, onError: (Object _) {}),
      );
      await controller.playCurrent(diagnostic: true);
      expect(provider.resolutions, 2);
      expect(
        store.rows().firstWhere((row) => row.track.id == '17_1').error,
        'audio_destination_rejected',
      );
      expect(controller.player.state.playing, isFalse);
    });
  });

  test('queue diagnostic restores original duplicate occurrences after source recovery', () async {
    await withGeneratedRecovery((controller, provider, store) async {
      store.trackError('17_2', 'audio_restricted');
      store.trackError('17_3', 'audio_restricted');
      controller.queue.replace(const [
        QueueEntry('17_2', 55),
        QueueEntry('17_2', 56),
        QueueEntry('17_3', 57),
      ], 1);
      controller.queue.setShuffle(true);
      final original = controller.queue.toJson();
      await controller.volume(0);
      await controller.checkQueueStartup(shuffled: true);
      expect(provider.resolutions, 2);
      expect(controller.queue.toJson(), original);
      expect(controller.player.state.playing, isFalse);
      expect(store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'], 0);
    });
  });

  test(
    'a stalled first download cannot remove the shared startup deadline',
    () async {
      final decodingStarted = Completer<void>();
      final releaseDecode = Completer<double>();
      final player = CleanupGatePlayback(decodingStarted.future);
      await withGeneratedRecovery(
        (controller, provider, store) async {
          final playing = controller.playCurrent(diagnostic: true);
          try {
            await player.failedOpen.future.timeout(const Duration(seconds: 2));
            await Future<void>.delayed(const Duration(milliseconds: 700));
            expect(
              controller.loading,
              isFalse,
              reason: 'The original 400ms deadline includes stalled cleanup',
            );
            expect(
              store.rows().firstWhere((row) => row.track.id == '17_1').error,
              'player_start_timeout',
            );
          } finally {
            if (!releaseDecode.isCompleted) releaseDecode.complete(10);
            await playing;
          }
        },
        player: player,
        rejectReference: false,
        startupTimeout: const Duration(milliseconds: 400),
        decode: (_) {
          if (!decodingStarted.isCompleted) decodingStarted.complete();
          return releaseDecode.future;
        },
      );
    },
  );

  for (final currentAvailable in [true, false]) {
    test(
      'rejected reference retries the same recording once, current available=$currentAvailable',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'ownsemble-source-recovery-',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        server.listen((request) async {
          requests.add(request.uri.path);
          if (request.uri.path == '/reference.mp3' || !currentAvailable) {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'https://vk.com/generated-not-media',
            );
          } else {
            request.response.contentLength = 8;
            request.response.add([1, 2, 3, 4, 5, 6, 7, 8]);
          }
          await request.response.close();
        });
        final baseHttp = HttpOverrides.current ?? FixtureHttpOverrides();
        final clients = <HttpClient>[];
        const track = Track('17_1', 'Generated', 'Fixture', 10);
        final store = LibraryStore(folder)
          ..merge([track])
          ..setSetting('auto_sync', false);
        final provider = RecoveringSourceProvider();
        final player = SilentRelayPlayback();
        try {
          await HttpOverrides.runZoned(
            () async {
              final controller = AppController(
                store,
                playbackPlayer: player,
                musicProvider: provider,
                decodeAudio: (_) async => 10,
                diagnosticStore: DiagnosticStore.memory(),
              );
              controller.queue.replace([const QueueEntry('17_1', 7)], 0);
              final queue = controller.queue.toJson();
              try {
                await controller
                    .playCurrent(diagnostic: true)
                    .timeout(const Duration(seconds: 5));
                expect(provider.resolutions, 2);
                expect(provider.rejections, 1);
                expect(provider.identities, ['17_1', '17_1']);
                expect(requests, ['/reference.mp3', '/current.mp3']);
                expect(controller.queue.toJson(), queue);
                expect(player.state.playing, currentAvailable);
                expect(controller.loading, isFalse);
                expect(
                  store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'],
                  0,
                );
                if (currentAvailable) {
                  expect(store.rows().single.error, isNull);
                } else {
                  expect(
                    store.rows().single.error,
                    'audio_destination_rejected',
                  );
                  expect(store.asset(track.id), isNull);
                }
              } finally {
                await controller.shutdown();
              }
            },
            createHttpClient: (context) {
              final client = baseHttp.createHttpClient(context)
                ..findProxy = (_) => 'DIRECT';
              clients.add(client);
              return GeneratedAudioClient(client, server.port);
            },
          );
        } finally {
          for (final client in clients) {
            client.close(force: true);
          }
          await server.close(force: true);
          await deleteGeneratedFolder(folder);
        }
      },
    );
  }
}
