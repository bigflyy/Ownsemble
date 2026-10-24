import 'package:ownsemble/platform/media_kit_playback.dart';
import 'package:ownsemble/media/local_audio.dart';
import 'package:ownsemble/contracts/music_browser.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/library_scanner.dart';
import 'package:ownsemble/provider/vk_provider.dart';
import 'package:ownsemble/services/app_controller.dart';

List<Track> songs(int start, int count) => List.generate(
  count,
  (index) => Track('1_${start + index}', 'Generated', 'Fixture', 60),
);

class SyncPlayer extends PlatformPlayer {
  SyncPlayer() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> setVolume(double volume) async {}
}

class SyncProvider extends VkProvider {
  final calls = <({bool fromTop, bool head, List<String> checkpoint})>[];
  final results = <SyncResult>[];
  bool fail = false;
  SyncProvider()
    : super(
        browserFactory: const UnsupportedMusicBrowserFactory(),
        loadAdapter: () async => '',
        status: (_) {},
        changed: () {},
      ) {
    connected = true;
  }
  @override
  Future<SyncResult> sync(
    void Function(List<Track>) merge, {
    required bool fromTop,
    bool newestOnly = false,
    List<String> checkpoint = const [],
  }) async {
    calls.add((fromTop: fromTop, head: newestOnly, checkpoint: checkpoint));
    if (fail) throw const ProofFailure('music_page_timeout');
    final result = results.removeAt(0);
    merge(
      result.head.map((id) => Track(id, 'Generated', 'Fixture', 60)).toList(),
    );
    return result;
  }

  @override
  Future<void> disconnect() async {}
}

void main() {
  final known = songs(1, 128).map((t) => t.id).toList();

  Future<(ScanOutcome, int, List<Track>)> check(
    List<List<Track>> pages, {
    List<String>? checkpoint,
    int stepSeconds = 1,
    bool busy = false,
  }) async {
    var time = Duration.zero, page = 0, advances = 0;
    final merged = <Track>[];
    final result = await LibraryScanner(
      newestOnly: true,
      checkpoint: checkpoint ?? known,
      quietLimit: const Duration(seconds: 5),
      hardLimit: const Duration(seconds: 15),
      read: () async => pages[page.clamp(0, pages.length - 1)],
      merge: merged.addAll,
      cancelled: () => false,
      progress: (_) {},
      elapsed: () => time,
      advance: (_, _) async {
        advances++;
        page++;
        time += Duration(seconds: stepSeconds);
        return busy;
      },
    ).run();
    return (result, advances, merged);
  }

  test(
    'unchanged 2633-song library stops at first known block without scrolling',
    () async {
      final (result, advances, merged) = await check([songs(1, 40)]);
      expect(result.reason, 'known_head');
      expect(result.count, 40);
      expect(result.continueSweep, isFalse);
      expect(advances, 0);
      expect(merged.length, 40);
    },
  );

  test(
    'new head entries merge before an overlap split across virtual windows',
    () async {
      final (result, advances, merged) = await check([
        [...songs(1000, 4), ...songs(1, 6)],
        songs(5, 18),
      ]);
      expect(result.reason, 'known_head');
      expect(advances, 1);
      expect(result.head.take(4), songs(1000, 4).map((t) => t.id));
      expect(
        merged.map((t) => t.id),
        containsAll(songs(1000, 4).map((t) => t.id)),
      );
    },
  );

  test(
    'one familiar row and shuffled known rows cannot terminate the check',
    () async {
      final scrambled = [for (var i = 1; i <= 30; i += 2) songs(i, 1).single];
      final (result, _, _) = await check(
        [scrambled],
        busy: true,
        stepSeconds: 3,
      );
      expect(result.reason, 'time_budget');
      expect(result.continueSweep, isFalse);
    },
  );

  test('a large unmatched new prefix has a strict 256-row cap and never continues a full sweep', () async {
    final (result, advances, merged) = await check([songs(1000, 300)]);
    expect(result.reason, 'head_budget');
    expect(result.count, 256);
    expect(result.head.length, 128);
    expect(merged.length, 256);
    expect(advances, 0);
    expect(result.continueSweep, isFalse);
  });

  test('stuck pagination is bounded by pages as well as time', () async {
    final (result, advances, _) = await check([songs(1000, 20)], busy: true);
    expect(result.reason, 'page_budget');
    expect(advances, 8);
    expect(result.continueSweep, isFalse);
  });

  test('legacy catalog seeds its head without walking the old tail', () async {
    final (result, advances, _) = await check([songs(1, 40)], checkpoint: []);
    expect(result.reason, 'head_seeded');
    expect(advances, 0);
  });

  test('a small library waits for a quiet boundary before seeding a short checkpoint', () async {
    final (result, advances, _) = await check([songs(1, 3)], checkpoint: []);
    expect(result.reason, 'head_seeded');
    expect(advances, 5);
    expect(result.head.length, 3);
  });

  group('persistent coordinator', () {
    late Directory directory;
    late LibraryStore store;
    late SyncProvider provider;
    late AppController controller;
    AppController open() {
      store = LibraryStore(directory);
      provider = SyncProvider();
      return AppController(
        store,
        playbackPlayer: MediaKitPlayback(Player(platformPlayer: SyncPlayer())),
        decodeAudio: decodeLocalAudio,
        musicProvider: provider,
      );
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ownsemble-incremental-',
      );
      controller = open();
      store.merge(songs(1, 2633));
      store.saveSyncHead(known);
    });
    tearDown(() async {
      await controller.shutdown();
      await directory.delete(recursive: true);
    });

    test(
      'startup scheduler uses the persisted checkpoint instead of a full sweep',
      () async {
        store.setSetting('auto_sync', true);
        provider.results.add(
          SyncResult(
            40,
            false,
            reason: 'known_head',
            head: known.take(40).toList(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(provider.calls.single.head, isTrue);
        expect(provider.calls.single.checkpoint, known);
        final report = jsonDecode(
          File('${directory.path}/sync-status.json').readAsStringSync(),
        ) as Map;
        expect(report['manual'], isFalse);
        expect(report['mode'], 'head');
      },
    );

    test('head checkpoint survives an app restart and the next automatic refresh stays incremental', () async {
      final newHead = [...songs(3000, 3).map((t) => t.id), ...known.take(30)];
      provider.results.add(
        SyncResult(33, false, reason: 'known_head', head: newHead),
      );
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isTrue);
      expect(provider.calls.single.checkpoint, known);
      expect(store.count, 2636);
      await controller.shutdown();
      controller = open();
      provider.results.add(
        SyncResult(33, false, reason: 'known_head', head: newHead),
      );
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isTrue);
      expect(provider.calls.single.fromTop, isTrue);
      expect(provider.calls.single.checkpoint, newHead);
      expect(store.count, 2636);
      final report = jsonDecode(
        File('${directory.path}/sync-status.json').readAsStringSync(),
      ) as Map;
      expect(report['mode'], 'head');
      expect(report['new_tracks'], 0);
      expect(report.containsKey('head'), isFalse);
    });

    test('no overlap or a failed refresh cannot replace the last successful checkpoint', () async {
      provider.results.add(
        SyncResult(
          256,
          false,
          reason: 'head_budget',
          head: songs(3000, 128).map((t) => t.id).toList(),
        ),
      );
      await controller.refresh(full: false);
      expect(store.syncHead, known);
      provider.fail = true;
      await controller.refresh(full: false);
      expect(store.syncHead, known);
      expect(store.count, 2761);
    });

    test('manual full scan continues in slices, then returns to short automatic checks', () async {
      provider.results.addAll([
        SyncResult(128, true, reason: 'time_budget', head: known),
        const SyncResult(40, false),
        SyncResult(
          40,
          false,
          reason: 'known_head',
          head: known.take(40).toList(),
        ),
      ]);
      await controller.refresh();
      await controller.refresh(full: false);
      await controller.refresh(full: false);
      expect(provider.calls.map((c) => c.head), [false, false, true]);
      expect(provider.calls.map((c) => c.fromTop), [true, false, true]);
      expect(store.syncHead, known.take(40).toList());
    });

    test('initial import persists pending discovery across restart without losing rows', () async {
      await controller.shutdown();
      await directory.delete(recursive: true);
      controller = open();
      provider.results.add(
        SyncResult(128, true, reason: 'time_budget', head: known),
      );
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isFalse);
      expect(store.setting('initial_sync_pending'), isTrue);
      await controller.shutdown();
      controller = open();
      provider.results.add(SyncResult(128, false, head: known));
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isFalse);
      // Preserve unresolved coverage when the provider supplied no explicit end witness.
      expect(store.setting('initial_sync_pending'), isTrue);
      expect(store.setting('initial_sync_paused'), isTrue);
      expect(store.count, 128);
    });

    test('a quiet initial scan remains pending and pauses broad retries across restart', () async {
      await controller.shutdown();
      await directory.delete(recursive: true);
      controller = open();
      provider.results.add(
        SyncResult(
          40,
          false,
          reason: 'quiet_boundary',
          head: known.take(40).toList(),
        ),
      );
      await controller.refresh(full: false);
      expect(store.setting('initial_sync_pending'), isTrue);
      expect(store.setting('initial_sync_paused'), isTrue);
      expect(store.setting('coverage'), 'partial');
      await controller.shutdown();
      controller = open();
      provider.results.add(
        SyncResult(
          40,
          false,
          reason: 'head_seeded',
          head: known.take(40).toList(),
        ),
      );
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isTrue);
      expect(store.setting('initial_sync_pending'), isTrue);
      expect(store.count, 40);
    });

    test('verified provider end completes initial discovery, survives restart and preserves historical rows', () async {
      // Preserve saved rows outside the current personal listing and its shorter size.
      store.setSetting('initial_sync_pending', true);
      store.setSetting('initial_sync_paused', true);
      provider.results.addAll([
        SyncResult(128, true, reason: 'time_budget', head: known),
        SyncResult(2616, false, reason: 'provider_end', head: known),
      ]);
      await controller.refresh();
      await controller.refresh(full: false);
      expect(store.setting('initial_sync_pending'), isFalse);
      expect(store.setting('initial_sync_paused'), isFalse);
      expect(store.setting('coverage'), 'complete');
      expect(store.setting('provider_library_count'), 2616);
      expect(controller.message, contains('2616 in verified VK listing'));
      expect(store.count, 2633);
      expect(store.syncHead, known);
      await controller.shutdown();
      controller = open();
      // A successful head poll must preserve the previous dated full-coverage witness.
      provider.results.add(
        SyncResult(
          12,
          false,
          reason: 'known_head',
          head: known.take(12).toList(),
        ),
      );
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isTrue);
      expect(store.setting('coverage'), 'complete');
      expect(store.setting('provider_library_count'), 2616);
      expect(store.count, 2633);
    });

    test('verified empty library does not repeat initial full import on every poll', () async {
      await controller.shutdown();
      await directory.delete(recursive: true);
      controller = open();
      // Persist an explicit zero-member provider end without manufacturing local rows.
      provider.results.add(const SyncResult(0, false, reason: 'provider_end'));
      await controller.refresh(full: false);
      expect(store.setting('initial_sync_pending'), isFalse);
      await controller.shutdown();
      controller = open();
      provider.results.add(const SyncResult(0, false, reason: 'provider_end'));
      await controller.refresh(full: false);
      expect(provider.calls.single.head, isTrue);
      expect(store.count, 0);
    });

    test('an incomplete full scan cannot replace a successful incremental checkpoint', () async {
      provider.results.add(
        SyncResult(
          3,
          false,
          reason: 'quiet_boundary',
          head: songs(9000, 3).map((track) => track.id).toList(),
        ),
      );
      await controller.refresh();
      expect(store.syncHead, known);
      expect(store.count, 2636);
      expect(store.setting('coverage'), 'partial');
    });

    test(
      'invalid checkpoint data is ignored without altering catalog or Piles',
      () {
        store.setSetting('sync_head', {
          'version': 1,
          'ids': ['1_1', '1_1'],
        });
        expect(store.syncHead, isEmpty);
        expect(() => store.saveSyncHead(['bad']), throwsA(isA<ProofFailure>()));
        expect(store.count, 2633);
        expect(store.piles().length, 1);
      },
    );
  });
}
