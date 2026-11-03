import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/sync/background_sync.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/sync_status_bar.dart';
import 'package:ownsemble/vk/vk_sync.dart';

SourceInfo vkSource({
  int songs = 2,
  int gone = 0,
  int? syncedAtMs,
  String? error,
  int id = 1,
  String name = 'VK',
  int color = 1,
}) => SourceInfo(
  id: id,
  kind: TrackSource.vk,
  account: '${41 + id}',
  name: name,
  color: color,
  songCount: songs,
  goneCount: gone,
  lastSyncAtMs: syncedAtMs,
  lastSyncError: error,
);

Track song(int id, String title, {bool gone = false, String? file}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Исполнитель',
  title: title,
  durationSec: 200,
  sourceKey: '42_$id',
  goneAtMs: gone ? 1 : null,
  localPath: file,
);

VkSyncResult result({
  int added = 0,
  int newlyGone = 0,
  int albumsSkipped = 0,
}) => VkSyncResult(
  sourceId: 1,
  listed: 2,
  declared: 2,
  added: added,
  updated: 0,
  back: 0,
  newlyGone: newlyGone,
  albumsSkipped: albumsSkipped,
);

void main() {
  group('several accounts', () {
    final both = [
      vkSource(syncedAtMs: 1000, name: 'Анна'),
      vkSource(id: 2, syncedAtMs: 1000, name: 'Борис', color: 2, songs: 2619),
    ];

    test('a login during a sync syncs again after it', () async {
      final finish = Completer<SyncOutcome>();
      var runs = 0;
      final sync = SyncController(
        sources: const [],
        onLibraryChanged: (_) {},
        runner: (_) {
          runs++;
          return runs == 1
              ? finish.future
              : Future.value(SyncOutcome(sources: both));
        },
      );
      final first = sync.syncNow();
      sync.syncAfterRunning();
      finish.complete(const SyncOutcome(sources: []));
      await first;
      expect(runs, 2);
      expect(sync.syncedSources, hasLength(2));
    });

    test('with no sync running a login syncs at once', () async {
      var runs = 0;
      final sync = SyncController(
        sources: const [],
        onLibraryChanged: (_) {},
        runner: (_) async {
          runs++;
          return const SyncOutcome(sources: []);
        },
      );
      await sync.syncAfterRunning();
      expect(runs, 1);
    });

    test('one expired account of two is not "log in again" for all', () async {
      final sync = SyncController(
        sources: both,
        onLibraryChanged: (_) {},
        runner: (_) async => SyncOutcome(
          sources: both,
          results: [result()],
          errors: const [vkLoginExpired],
        ),
      );
      await sync.syncNow();
      expect(sync.loginExpired, isFalse);
    });

    test('all accounts expired is "log in again"', () async {
      final sync = SyncController(
        sources: both,
        onLibraryChanged: (_) {},
        runner: (_) async => SyncOutcome(
          sources: both,
          errors: const [vkLoginExpired, vkLoginExpired],
        ),
      );
      await sync.syncNow();
      expect(sync.loginExpired, isTrue);
    });

    test('progress runs through the accounts one after another', () {
      const reading = SyncProgress(SyncStage.reading, done: 1, total: 2);
      expect(reading.inAccount(0, 2).fraction, closeTo(0.2125, 0.001));
      expect(reading.inAccount(1, 2).fraction, closeTo(0.7125, 0.001));
    });

    test('an outcome tells each account\'s result apart', () {
      final outcome = SyncOutcome(
        sources: both,
        results: [
          VkSyncResult(
            sourceId: 2,
            listed: 1,
            declared: 1,
            added: 1,
            updated: 0,
            back: 0,
            newlyGone: 0,
          ),
        ],
      );
      expect(outcome.resultOf(2)?.added, 1);
      expect(outcome.resultOf(1), isNull);
    });

    testWidgets('the bar shows both on one line, each with its color', (
      tester,
    ) async {
      final sync = SyncController(
        sources: both,
        runner: null,
        onLibraryChanged: (_) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: SizedBox(
              width: 480,
              child: SyncStatusBar(sync: sync),
            ),
          ),
        ),
      );
      expect(find.text('Анна'), findsOneWidget);
      expect(find.text('Борис'), findsOneWidget);
      expect(find.text('2619 songs'), findsOneWidget);
      expect(find.byType(Tooltip), findsWidgets);
      final dots = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(SyncStatusBar),
              matching: find.byWidgetPredicate(
                (w) => w is Container && w.constraints?.maxWidth == 8,
              ),
            ),
          )
          .map((w) => (w.decoration! as BoxDecoration).color)
          .toSet();
      expect(dots, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('a first sync', () {
    test('runs once more for the album titles it left', () async {
      final outcomes = [
        SyncOutcome(
          sources: [vkSource()],
          results: [result(added: 2, albumsSkipped: 1)],
        ),
        SyncOutcome(sources: [vkSource()], results: [result()]),
      ];
      var runs = 0;
      final sync = SyncController(
        sources: [vkSource()],
        runner: (_) async => outcomes[runs++],
        onLibraryChanged: (_) {},
      );
      final last = await sync.syncNow();
      expect(runs, 2);
      expect(last, same(outcomes[1]));
      expect(sync.running, isFalse);
    });

    test('does not run again once the session is gone', () async {
      var runs = 0;
      late SyncController sync;
      sync = SyncController(
        sources: [vkSource()],
        runner: (_) async {
          runs++;
          // Logging out while the first sync runs.
          sync.runner = null;
          return SyncOutcome(
            sources: [vkSource()],
            results: [result(albumsSkipped: 1)],
          );
        },
        onLibraryChanged: (_) {},
      );
      await sync.syncNow();
      expect(runs, 1);
    });
  });

  group('status text', () {
    final now = DateTime(2026, 10, 30, 15, 0);

    test('sync times read as today, yesterday or a date', () {
      expect(formatSyncTime(DateTime(2026, 10, 30, 9, 5), now), 'today 09:05');
      expect(
        formatSyncTime(DateTime(2026, 10, 29, 23, 59), now),
        'yesterday 23:59',
      );
      expect(
        formatSyncTime(DateTime(2026, 10, 1, 7, 0), now),
        '2026-10-01 07:00',
      );
    });

    test('a source shows songs, gone songs, time and the last changes', () {
      final at = DateTime(2026, 10, 30, 14, 2).millisecondsSinceEpoch;
      expect(
        describeSourceState(
          vkSource(songs: 126, gone: 3, syncedAtMs: at),
          lastResult: result(added: 2, newlyGone: 1),
          now: now,
        ),
        '126 songs · 3 gone from VK · synced today 14:02 · '
        '2 new, 1 newly gone',
      );
      expect(
        describeSourceState(
          vkSource(songs: 126, syncedAtMs: at),
          lastResult: result(),
          now: now,
        ),
        '126 songs · synced today 14:02 · no changes',
      );
      expect(
        describeSourceState(
          vkSource(syncedAtMs: at, error: 'no connection to VK'),
          lastResult: null,
          now: now,
        ),
        'sync failed today 14:02: no connection to VK',
      );
      expect(
        describeSourceState(vkSource(), lastResult: null, now: now),
        '2 songs, not synced yet',
      );
    });
  });

  group('in the app', () {
    late LibraryController library;
    late Completer<SyncOutcome> finish;
    late void Function(SyncProgress) report;
    late int runs;
    late SyncController sync;

    setUp(() {
      library = LibraryController([song(1, 'Первая'), song(2, 'Вторая')]);
      runs = 0;
      sync = SyncController(
        sources: [vkSource()],
        runner: (onProgress) {
          runs++;
          report = onProgress;
          finish = Completer();
          return finish.future;
        },
        onLibraryChanged: (loaded) =>
            library.replaceTracks(loaded.tracks, loaded.index),
      );
    });

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: PlaybackController(
              player: PlayerService(vk: null, muted: true, dataDir: '.'),
              recordPlay: (_) {},
            ),
            sync: sync,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Sync now shows progress, then the new library', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.textContaining('not synced yet'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      expect(runs, 1);
      expect(find.byKey(const ValueKey('sync-progress')), findsOneWidget);
      expect(find.textContaining('syncing...'), findsOneWidget);

      report(const SyncProgress(SyncStage.reading, done: 1, total: 2));
      await tester.pump();
      expect(find.text('Syncing 43%'), findsOneWidget);

      // A second click while syncing starts nothing.
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      expect(sync.syncNow(), same(sync.idle));
      expect(runs, 1);

      final tracks = [
        song(3, 'Новая'),
        song(1, 'Первая'),
        song(2, 'Вторая', gone: true),
      ];
      finish.complete(
        SyncOutcome(
          sources: [
            vkSource(
              songs: 3,
              gone: 1,
              syncedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
          results: [result(added: 1, newlyGone: 1)],
          library: LoadedLibrary(tracks, SearchIndex(tracks)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sync-progress')), findsNothing);
      expect(find.text('Sync now'), findsOneWidget);
      expect(library.all.map((t) => t.title), ['Новая', 'Первая', 'Вторая']);
      expect(find.text('Новая'), findsOneWidget);
      expect(find.textContaining('3 songs · 1 gone from VK'), findsOneWidget);
      expect(find.textContaining('1 new, 1 newly gone'), findsOneWidget);

      // Only the gone song carries the mark.
      final goneRow = find.byKey(const ValueKey('song-2'));
      expect(
        find.descendant(
          of: goneRow,
          matching: find.byKey(const ValueKey('gone-tag')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('gone-tag')), findsOneWidget);
    });

    testWidgets('a sync keeps the search the user typed', (tester) async {
      await pumpApp(tester);
      library.searchText.text = 'втор';
      await tester.pump();
      expect(library.visible.map((t) => t.id), [2]);

      unawaited(sync.syncNow());
      final tracks = [
        song(3, 'Ещё вторая'),
        song(1, 'Первая'),
        song(2, 'Вторая'),
      ];
      finish.complete(
        SyncOutcome(
          sources: [vkSource(songs: 3, syncedAtMs: 1)],
          results: [result(added: 1)],
          library: LoadedLibrary(tracks, SearchIndex(tracks)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(library.visible.map((t) => t.id), [3, 2]);
    });

    testWidgets('a failed sync shows why and leaves the library as it was', (
      tester,
    ) async {
      await pumpApp(tester);
      unawaited(sync.syncNow());
      finish.complete(
        SyncOutcome(
          sources: [
            vkSource(
              syncedAtMs: DateTime.now().millisecondsSinceEpoch,
              error: 'VK login expired, log in again',
            ),
          ],
          errors: ['VK login expired, log in again'],
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('sync failed today'), findsOneWidget);
      expect(find.textContaining('VK login expired'), findsOneWidget);
      expect(library.all, hasLength(2));
      expect(find.text('Sync now'), findsOneWidget);
    });

    testWidgets('without a VK session there is nothing to sync', (
      tester,
    ) async {
      sync = SyncController(
        sources: const [],
        runner: null,
        onLibraryChanged: (_) {},
      );
      await pumpApp(tester);
      expect(find.textContaining('not logged in'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Sync now'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
