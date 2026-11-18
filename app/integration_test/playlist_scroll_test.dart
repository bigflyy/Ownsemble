// Speed check of plan 08 C5: a playlist the account made is a reorderable
// list (rows dragged by a handle), and its scrolling must still hold 60 fps.
// The same 3000 rows are scrolled twice in one window: as the reorderable
// list, and as the plain list (a search that every row matches turns the
// handles off), so the two numbers differ only in the list.
//
//   OWNSEMBLE_BACKGROUND_WINDOW=1 flutter drive --profile -d windows \
//       --driver=test_driver/integration_test.dart \
//       --target=integration_test/playlist_scroll_test.dart
//
// Profile mode, off-screen window, no VK and no data folder: the playlist
// comes from the fake VK of the widget tests (test/playlist_edits_support.dart)
// and the library is in memory. Prints frame counts and times only.

import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/playlists.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';

import '../test/catalog_support.dart' show ShowingPlayer;
import '../test/playlist_edits_support.dart';

// ignore: avoid_print
void say(String line) => print(line);

/// Rows in the made playlist: more than a screen many times over.
const songCount = 3000;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final frames = <FrameTiming>[];
  SchedulerBinding.instance.addTimingsCallback(frames.addAll);

  /// Waits on real time while frames go on, until [condition] holds.
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition,
    String what,
  ) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > const Duration(seconds: 30)) {
        fail('timed out waiting for $what');
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Scrolls [scroll] at [pixelsPerSecond] for [seconds], one jump per
  /// frame (as the speed gate's scroll part does), and sums up the frames.
  Future<Map<String, num>> scrollRun(
    WidgetTester tester,
    ScrollController scroll,
    int pixelsPerSecond, {
    int seconds = 4,
  }) async {
    scroll.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 300));
    frames.clear();
    final startUs = Timeline.now;
    final done = Completer<void>();
    void onFrame(Duration _) {
      final elapsed = (Timeline.now - startUs) / 1e6;
      final position = scroll.position;
      final target = min(elapsed * pixelsPerSecond, position.maxScrollExtent);
      position.jumpTo(target);
      if (elapsed >= seconds || target >= position.maxScrollExtent) {
        done.complete();
      } else {
        SchedulerBinding.instance.scheduleFrameCallback(onFrame);
      }
    }

    SchedulerBinding.instance.scheduleFrameCallback(onFrame);
    SchedulerBinding.instance.scheduleFrame();
    await done.future;
    final endUs = Timeline.now;
    // Timings arrive in batches: let the last one in.
    await tester.pump(const Duration(milliseconds: 300));
    final taken = [
      for (final frame in frames)
        if (frame.timestampInMicroseconds(FramePhase.buildStart) >= startUs &&
            frame.timestampInMicroseconds(FramePhase.buildStart) <= endUs)
          frame,
    ];
    const budgetMs = 1000 / 60;
    final buildMs = [
      for (final f in taken) f.buildDuration.inMicroseconds / 1000,
    ]..sort();
    final rasterMs = [
      for (final f in taken) f.rasterDuration.inMicroseconds / 1000,
    ]..sort();
    num at(List<double> sorted, double share) => sorted.isEmpty
        ? 0
        : sorted[min(sorted.length - 1, (sorted.length * share).floor())];
    final spanSeconds = (endUs - startUs) / 1e6;
    return {
      'frames': taken.length,
      'fps': taken.length / spanSeconds,
      'buildP50Ms': at(buildMs, 0.5),
      'buildP99Ms': at(buildMs, 0.99),
      'buildMaxMs': buildMs.isEmpty ? 0 : buildMs.last,
      'rasterP50Ms': at(rasterMs, 0.5),
      'rasterP99Ms': at(rasterMs, 0.99),
      'overBudget': [
        for (final f in taken)
          if (f.buildDuration.inMicroseconds / 1000 > budgetMs ||
              f.rasterDuration.inMicroseconds / 1000 > budgetMs)
            f,
      ].length,
    };
  }

  String show(Map<String, num> run) => [
    for (final MapEntry(:key, :value) in run.entries)
      '$key ${value is double ? value.toStringAsFixed(1) : value}',
  ].join(', ');

  testWidgets('a made playlist of $songCount songs scrolls at 60 fps with '
      'its drag handles', (tester) async {
    final store = LibraryStore.open(':memory:');
    final source = store.ensureSource(
      TrackSource.vk,
      account: '10000',
      name: 'Мой VK',
    );
    final vk = EditVk();
    for (var id = 1; id <= songCount; id++) {
      vk.song(10000, id, trackId: 100000 + id);
      vk.library.add('10000_$id');
    }
    store.upsertAll(source, [
      for (var id = 1; id <= songCount; id++)
        NewTrack(
          sourceKey: '10000_$id',
          artist: 'Исполнитель ${id % 97}',
          title: 'Песня $id',
          durationSec: 200,
          addedAt: id,
          vkTrackId: 100000 + id,
        ),
    ]);
    vk.made('Большой', [
      for (var id = 1; id <= songCount; id++) vk.known['10000_$id']!,
    ]);
    final library = LibraryController(store.loadAll());
    final sources = ValueNotifier(store.sources());
    final playback = PlaybackController(player: ShowingPlayer());
    final catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? vk.call : null,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
      onAdded: playback.adoptAdded,
    );
    final playlists = VkPlaylists(
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? vk.call : null,
      outside: OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong),
    );
    library.vkLists = playlists;
    addTearDown(() {
      catalog.dispose();
      store.close();
    });

    await tester.pumpWidget(
      SourcesScope(
        sources: sources,
        child: MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: playback,
            catalog: catalog,
            playlists: playlists,
            settings: ShellSettings.inMemory(),
          ),
        ),
      ),
    );
    unawaited(playlists.refresh());
    await waitUntil(
      tester,
      () => playlists.songsOf('10000_${vk.playlists.first.id}').isNotEmpty,
      'the playlist read',
    );
    await tester.tap(find.byKey(const ValueKey('nav-playlists')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('list-card-Большой')));
    await waitUntil(
      tester,
      () =>
          library.visible.length == songCount &&
          find.byKey(const ValueKey('playlist-reorder')).evaluate().isNotEmpty,
      'the playlist place with its handles',
    );
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final rows = (size.height / rowHeight).floor();
    say(
      'window ${size.width.round()}x${size.height.round()} '
      '(about $rows rows), refresh '
      '${tester.view.display.refreshRate.toStringAsFixed(0)} Hz',
    );

    final reorder = {
      for (final speed in [1500, 6000, 20000])
        speed: await scrollRun(tester, library.scroll, speed),
    };

    // A search every row matches: the same rows, the plain list.
    library.searchText.text = 'Исполнитель';
    await waitUntil(
      tester,
      () =>
          library.visible.length == songCount &&
          find.byKey(const ValueKey('playlist-reorder')).evaluate().isEmpty,
      'the plain list under a search',
    );
    final plain = {
      for (final speed in [1500, 6000, 20000])
        speed: await scrollRun(tester, library.scroll, speed),
    };

    for (final speed in reorder.keys) {
      say('$speed px/s reorderable: ${show(reorder[speed]!)}');
      say('$speed px/s plain:       ${show(plain[speed]!)}');
    }
    for (final speed in reorder.keys) {
      final run = reorder[speed]!;
      final base = plain[speed]!;
      expect(
        run['fps']!,
        greaterThanOrEqualTo(min(60, base['fps']!) * 0.95),
        reason: '$speed px/s: the reorderable list keeps the frame rate',
      );
      expect(
        run['overBudget']!,
        lessThanOrEqualTo(max(2, run['frames']! * 0.01)),
        reason: '$speed px/s: frames over the 60 fps budget',
      );
    }
  });
}
