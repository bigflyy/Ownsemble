import 'package:ownsemble/platform/media_kit_playback.dart';
import 'package:ownsemble/media/local_audio.dart';
import 'package:ownsemble/contracts/music_browser.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/artwork_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/vk_provider.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/playback_queue.dart';

class EnrichmentPlayer extends PlatformPlayer {
  EnrichmentPlayer() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
}

class EnrichmentProvider extends VkProvider {
  final result = Completer<Map<String, dynamic>>();
  EnrichmentProvider()
    : super(
        browserFactory: const UnsupportedMusicBrowserFactory(),
        loadAdapter: () async => '',
        status: (_) {},
        changed: () {},
      ) {
    connected = true;
  }
  @override
  Future<Map<String, dynamic>> inspectMetadata(
    Track track, {
    bool force = false,
    bool includeLyrics = true,
    bool Function()? cancelled,
  }) => result.future;
  @override
  Future<void> disconnect() async {}
  @override
  Uri? artworkSource(String id) =>
      Uri.parse('https://test.userapi.com/generated.png');
}

class EnrichmentController extends AppController {
  final preparing = Completer<CachedAudio>();
  bool playRequested = false;
  String? lastRequested;
  EnrichmentController(
    super.store,
    EnrichmentProvider provider, {
    super.metadataTimeout,
    super.artworkCache,
  }) : super(
         musicProvider: provider,
         playbackPlayer: MediaKitPlayback(
           Player(platformPlayer: EnrichmentPlayer()),
         ),
         decodeAudio: decodeLocalAudio,
       );
  @override
  Future<CachedAudio> ensureAsset(Track track, {bool playback = false}) {
    playRequested = true;
    lastRequested = track.id;
    return preparing.future;
  }
}

class VisibleMetadataProvider extends VkProvider {
  final requests = <String>[];
  final modes = <bool>[];
  final gates = <String, Completer<Map<String, dynamic>>>{};
  final sources = <String, Uri>{};
  VisibleMetadataProvider()
    : super(
        browserFactory: const UnsupportedMusicBrowserFactory(),
        loadAdapter: () async => '',
        status: (_) {},
        changed: () {},
      ) {
    connected = true;
  }
  @override
  Uri? artworkSource(String id) => sources[id];
  @override
  Future<Map<String, dynamic>> inspectMetadata(
    Track track, {
    bool force = false,
    bool includeLyrics = true,
    bool Function()? cancelled,
  }) async {
    requests.add(track.id);
    modes.add(includeLyrics);
    final data =
        await (gates[track.id] = Completer<Map<String, dynamic>>()).future;
    if (cancelled?.call() == true) throw const ProofFailure('cancelled');
    if (data['artworkURL'] is String) {
      sources[track.id] = Uri.parse(data['artworkURL']);
    }
    return data;
  }

  @override
  Future<void> disconnect() async {}
}

class MetadataConnectionProbe extends VkProvider {
  MetadataConnectionProbe()
    : super(
        browserFactory: const UnsupportedMusicBrowserFactory(),
        loadAdapter: () async => '',
        status: (_) {},
        changed: () {},
      );
  @override
  Future<void> connect() async =>
      throw const ProofFailure('generated_connection_probe');
}

void main() {
  test('fresh offline check uses the last accepted recording rather than another queued song', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-offline-target-',
    );
    final store = LibraryStore(folder)
      ..merge([
        const Track('1_1', 'Generated accepted', 'Fixture', 12),
        const Track('1_2', 'Generated queued', 'Fixture', 12),
      ]);
    store.saveAsset(const CachedAudio('1_1', 'unused-a.mp3', 'a', 3, 12));
    store.saveAsset(const CachedAudio('1_2', 'unused-b.mp3', 'b', 3, 12));
    store.setSetting('acceptance_sample_id', '1_1');
    final controller = EnrichmentController(store, EnrichmentProvider());
    controller.queue.replace([const QueueEntry('1_2')], 0);
    controller.offline = true;
    final task = controller.checkOfflineControls();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final requested = controller.lastRequested;
    controller.preparing.completeError(const ProofFailure('cancelled'));
    await task;
    expect(requested, '1_1');
    expect(controller.current?.id, '1_2');
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('a disconnected metadata lookup reaches connection before requiring an existing music document', () async {
    final provider = MetadataConnectionProbe();
    await expectLater(
      provider.inspectMetadata(
        const Track('1_2', 'Generated', 'Fixture', 12),
        includeLyrics: false,
      ),
      throwsA(
        isA<ProofFailure>().having(
          (error) => error.category,
          'category',
          'generated_connection_probe',
        ),
      ),
    );
  });
  test('visible old rows get bounded metadata without lyrics and skipped rows do not queue lookups', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-visible-meta-',
    );
    final store = LibraryStore(folder)
      ..merge([
        for (var i = 1; i <= 12; i++)
          Track('1_$i', 'Generated $i', 'Fixture', 12),
      ]);
    final provider = VisibleMetadataProvider();
    final artwork = ArtworkCache(
      Directory('${folder.path}/artwork'),
      fetch: (_) async => ArtworkResponse(Uint8List(0), 'image/png'),
    );
    final controller = AppController(
      store,
      musicProvider: provider,
      artworkCache: artwork,
      playbackPlayer: MediaKitPlayback(
        Player(platformPlayer: EnrichmentPlayer()),
      ),
      decodeAudio: decodeLocalAudio,
    );
    final owners = {for (var i = 1; i <= 12; i++) i: Object()};
    controller.loading = true;
    controller.watchArtwork('1_1', owners[1]!);
    await Future<void>.delayed(Duration.zero);
    expect(provider.requests, isEmpty);
    controller.loading = false;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(provider.requests, ['1_1']);
    for (var i = 2; i <= 10; i++) {
      controller.watchArtwork('1_$i', owners[i]!);
      controller.unwatchArtwork('1_$i', owners[i]!);
    }
    controller.unwatchArtwork('1_1', owners[1]!);
    controller.watchArtwork('1_12', owners[12]!);
    provider.gates['1_1']!.complete({'album': 'Abandoned generated album'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.requests, ['1_1', '1_12']);
    expect(provider.modes, [false, false]);
    provider.gates['1_12']!.complete({
      'album': 'Destination generated album',
      'artworkURL': 'https://test.userapi.com/destination.png',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(store.metadata('1_1'), isEmpty);
    expect(store.metadata('1_12')['album'], 'Destination generated album');
    expect(controller.current, isNull);
    controller.unwatchArtwork('1_12', owners[12]!);
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('a stalled artwork request cannot hold up Play', () async {
    final folder = await Directory.systemTemp.createTemp('ownsemble-art-play-');
    final store = LibraryStore(folder)
      ..merge([const Track('1_2', 'Generated', 'Fixture', 12)]);
    final gate = Completer<ArtworkResponse>();
    var requested = false;
    final artwork = ArtworkCache(
      Directory('${folder.path}/artwork'),
      fetch: (_) {
        requested = true;
        return gate.future;
      },
    );
    final controller = EnrichmentController(
      store,
      EnrichmentProvider(),
      artworkCache: artwork,
    );
    final owner = Object();
    controller.watchArtwork('1_2', owner);
    await Future<void>.delayed(Duration.zero);
    expect(requested, isTrue);
    final play = controller.playRows(store.rows(), 0);
    await Future<void>.delayed(Duration.zero);
    expect(controller.playRequested, isTrue);
    expect(controller.loading, isTrue);
    await controller.stopPlayback();
    controller.preparing.completeError(const ProofFailure('cancelled'));
    await play;
    controller.unwatchArtwork('1_2', owner);
    gate.complete(ArtworkResponse(Uint8List(0), 'image/png'));
    await Future<void>.delayed(Duration.zero);
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('repaired-recording check selects its saved identity rather than the current next song', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-repair-check-',
    );
    final store = LibraryStore(folder)
      ..merge([
        const Track('1_1', 'Generated requested', 'Fixture', 100),
        const Track('1_2', 'Generated next', 'Fixture', 120),
      ]);
    store.setSetting('recording_repair_sample_id', '1_1');
    final controller = EnrichmentController(store, EnrichmentProvider());
    controller.queue.replace([const QueueEntry('1_2')], 0);
    final task = controller.checkRepairedControls();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.lastRequested, '1_1');
    controller.preparing.completeError(const ProofFailure('cancelled'));
    await task;
    expect(controller.current?.id, '1_2');
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('fixed repair targets the mismatched cache without changing the selected queue song', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-targeted-repair-',
    );
    final store = LibraryStore(folder)
      ..merge([
        const Track('1_1', 'Generated requested', 'Fixture', 100),
        const Track('1_2', 'Generated next', 'Fixture', 120),
      ]);
    store.saveAsset(
      const CachedAudio('1_1', 'unused-generated.mp3', 'fixture', 3, 120),
    );
    final controller = EnrichmentController(store, EnrichmentProvider());
    controller.queue.replace([const QueueEntry('1_2')], 0);
    final task = controller.repairMismatchedCache();
    await Future<void>.delayed(Duration.zero);
    expect(controller.lastRequested, '1_1');
    expect(controller.current?.id, '1_2');
    controller.preparing.complete(
      const CachedAudio('1_1', 'unused-generated.mp3', 'fixture', 3, 100),
    );
    final report = await task;
    expect(report['phase'], 'failed');
    expect(report.toString(), isNot(contains('Generated')));
    expect(store.count, 2);
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test(
    'an unverified legacy cache is blocked offline without deleting its audio',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-legacy-block-',
      );
      final store = LibraryStore(folder)
        ..merge([const Track('1_2', 'Generated', 'Fixture', 12)]);
      final legacyCache = AudioCache(
        Directory('${folder.path}/audio'),
        (_) async => 12,
        resourceLoader: (_, {required userAgent, required limit}) async =>
            Uint8List.fromList([1, 2, 3]),
      );
      final old = await legacyCache.save(
        store.track('1_2')!,
        Uri.parse('https://test.vkuseraudio.ru/old.mp3'),
      );
      store.saveAsset(old);
      final controller = AppController(
        store,
        playbackPlayer: MediaKitPlayback(
          Player(platformPlayer: EnrichmentPlayer()),
        ),
        decodeAudio: decodeLocalAudio,
        musicProvider: EnrichmentProvider(),
      );
      controller.offline = true;
      try {
        expect(controller.rows.single.offline, isFalse);
        controller.browse('offline');
        expect(controller.rows, isEmpty);
        await expectLater(
          controller.ensureAsset(store.track('1_2')!),
          throwsA(
            isA<ProofFailure>().having(
              (failure) => failure.category,
              'category',
              'cache_identity_unverified',
            ),
          ),
        );
        expect(File(old.entry).readAsBytesSync(), [1, 2, 3]);
        expect(store.asset('1_2'), isNotNull);
      } finally {
        await controller.shutdown();
        legacyCache.cancel();
        await folder.delete(recursive: true);
      }
    },
  );
  test('leaving a cover releases only its own demand and returning can retry immediately', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-cover-demand-',
    );
    final store = LibraryStore(folder)
      ..merge([const Track('1_2', 'Generated', 'Fixture', 180)]);
    final gates = <Completer<ArtworkResponse>>[];
    final cache = ArtworkCache(
      Directory('${folder.path}/artwork'),
      fetch: (_) {
        final gate = Completer<ArtworkResponse>();
        gates.add(gate);
        return gate.future;
      },
    );
    final controller = EnrichmentController(
      store,
      EnrichmentProvider(),
      artworkCache: cache,
    );
    final first = Object(), second = Object();
    await controller.loadArtwork('1_2', visibleOnly: true);
    expect(controller.metadataSummary()['pending_artwork'], 0);
    controller.watchArtwork('1_2', first);
    controller.watchArtwork('1_2', second);
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 1);
    controller.unwatchArtwork('1_2', first);
    expect(controller.metadataSummary()['pending_artwork'], 1);
    controller.unwatchArtwork('1_2', second);
    gates.first.complete(ArtworkResponse(Uint8List(0), 'image/png'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.metadataSummary()['pending_artwork'], 0);
    controller.watchArtwork('1_2', first);
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 2);
    controller.unwatchArtwork('1_2', first);
    gates.last.complete(ArtworkResponse(Uint8List(0), 'image/png'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('timed-out metadata stops loading and ignores a later result', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-enrichment-timeout-',
    );
    final store = LibraryStore(folder)
      ..merge([const Track('1_2', 'Generated', 'Fixture', 180)]);
    final provider = EnrichmentProvider();
    final controller = EnrichmentController(
      store,
      provider,
      metadataTimeout: const Duration(milliseconds: 20),
    );
    await controller.enrichTrack('1_2');
    expect(controller.enriching('1_2'), isFalse);
    expect(controller.metadataErrors['1_2'], 'metadata_request_timeout');
    provider.result.complete({'album': 'Late generated album'});
    await Future<void>.delayed(Duration.zero);
    expect(store.metadata('1_2')['album'], isNull);
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test('metadata text quality diagnostics expose counts without recording text', () async {
    // Keep every recording and the database generated for this privacy regression.
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-text-quality-',
    );
    // Construct Cyrillic and replacement characters without shell encoding dependencies.
    final title = String.fromCharCodes([1050, 1088, 1072, 1081]);
    // Mark a damaged generated value without exposing any real catalog content.
    final replacement = String.fromCharCode(65533);
    // Exercise numeric quality counters on all three relevant text shapes.
    final store = LibraryStore(folder)
      ..merge([
        Track('17_1', title, 'Fixture', 60),
        Track('17_2', replacement, 'Fixture', 60),
        const Track('17_3', '???', 'Fixture', 60),
      ]);
    // Reuse the actual application-owned summary with a generated provider.
    final controller = EnrichmentController(store, EnrichmentProvider());
    try {
      // Keep titles and artists internal while reporting only bounded aggregate counts.
      final summary = controller.metadataSummary();
      expect(summary['cyrillic_titles'], 1);
      expect(summary['replacement_metadata'], 1);
      expect(summary['question_mark_metadata'], 1);
      expect(summary.toString().contains(title), isFalse);
      expect(summary.toString().contains('Fixture'), isFalse);
    } finally {
      await controller.shutdown();
      await folder.delete(recursive: true);
    }
  });

  test(
    'metadata diagnostics expose counts without titles, lyrics or source URLs',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-enrichment-summary-',
      );
      final store = LibraryStore(
        folder,
      )..merge([const Track('1_2', 'PRIVATE_GENERATED_TITLE', 'Fixture', 180)]);
      final controller = EnrichmentController(store, EnrichmentProvider());
      store.mergeMetadata('1_2', {
        'album': 'PRIVATE_GENERATED_ALBUM',
        'uploadedAt': 1514764800,
      });
      store.saveLyrics('1_2', {
        'text': 'PRIVATE_GENERATED_LYRICS',
      }, state: 'available');
      final summary = controller.metadataSummary();
      expect(summary['import_dates'], 1);
      expect(summary['albums'], 1);
      expect(summary['lyrics_cached'], 1);
      expect(summary.toString().contains('PRIVATE_GENERATED'), isFalse);
      await controller.shutdown();
      await folder.delete(recursive: true);
    },
  );
  test('an immediate connection failure clears its loading state so details can retry', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-enrichment-retry-',
    );
    final store = LibraryStore(folder)
      ..merge([const Track('1_2', 'Generated', 'Fixture', 180)]);
    final provider = EnrichmentProvider()..connected = false;
    final controller = EnrichmentController(store, provider);
    await controller.enrichTrack('1_2');
    expect(controller.enriching('1_2'), isFalse);
    provider.connected = true;
    provider.result.complete({'album': 'Recovered generated album'});
    await controller.enrichTrack('1_2');
    expect(store.metadata('1_2')['album'], 'Recovered generated album');
    await controller.shutdown();
    await folder.delete(recursive: true);
  });
  test(
    'a hung metadata request does not hold up ordinary playback preparation',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-enrichment-',
      );
      final store = LibraryStore(folder)
        ..merge([const Track('1_2', 'Generated', 'Fixture', 180)]);
      final controller = EnrichmentController(store, EnrichmentProvider());
      // Use the controller's own provider gate; no browser or credentials involved.
      final request = controller.enrichTrack('1_2');
      final play = controller.playRows(store.rows(), 0);
      await Future<void>.delayed(Duration.zero);
      expect(controller.playRequested, isTrue);
      expect(controller.loading, isTrue);
      await controller.stopPlayback();
      controller.preparing.completeError(const ProofFailure('cancelled'));
      await play;
      (controller.provider as EnrichmentProvider).result.complete({
        'album': 'Generated album',
      });
      await request;
      expect(store.metadata('1_2')['album'], 'Generated album');
      await controller.shutdown();
      await folder.delete(recursive: true);
    },
  );

  test(
    'late enrichment after shutdown cannot write into the closed database',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-enrichment-',
      );
      final store = LibraryStore(folder)
        ..merge([const Track('1_2', 'Generated', 'Fixture', 180)]);
      final provider = EnrichmentProvider();
      final controller = EnrichmentController(store, provider);
      final request = controller.enrichTrack('1_2');
      await controller.shutdown();
      provider.result.complete({'album': 'Generated album'});
      await expectLater(request, completes);
      await folder.delete(recursive: true);
    },
  );
}
