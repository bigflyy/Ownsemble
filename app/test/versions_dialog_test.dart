import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/mp3_length.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/vk/vk_client.dart';

SongVersion upload(String key, double seconds, {int listed = 219}) =>
    SongVersion(
      key: key,
      artist: 'Операция Пластилин',
      title: 'Ты и я',
      album: 'Волна',
      listedSec: listed,
      file: FileFacts(bytes: (seconds * 40000).round(), seconds: seconds),
    );

/// A player showing [track] as loaded, without opening any audio.
class _ShowingPlayer extends PlayerService {
  _ShowingPlayer(this.track, {required super.accounts})
    : super(muted: true, dataDir: '.');

  final Track track;

  @override
  Track? get current => track;
  @override
  Stream<Track?> get currentStream => const Stream.empty();
  @override
  Stream<Duration> get positions => const Stream.empty();
}

void main() {
  late LibraryStore store;
  late List<Track> tracks;
  late VersionBook versions;
  late PlayerService player;

  setUp(() async {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Операция Пластилин',
        title: 'Ты и я',
        durationSec: 219,
        addedAt: 2,
      ),
      const NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 236,
        addedAt: 1,
      ),
    ]);
    tracks = store.loadAll();
    versions = VersionBook(
      store: store,
      find: (track, route) async => [
        upload('5_1', 219.2),
        upload('6_1', 226.5, listed: 226),
      ],
      measure: (route) async => const FileFacts(bytes: 9062443, seconds: 226.5),
    );
    player = PlayerService(
      muted: true,
      dataDir: '.',
      accounts: (sourceId) => VkClient(const []),
    )..versions = versions;
  });
  tearDown(() => store.close());

  Track swappedSong() => tracks.firstWhere((t) => t.sourceKey == '1_1');

  Future<void> pumpScreen(WidgetTester tester) async {
    // Wide enough for the Album column, so row tags show their labels.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: LibraryController(tracks, versions: player.versions),
          playback: PlaybackController(player: player, recordPlay: (_) {}),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('only a swapped song is marked, and the mark opens its '
      'versions', (tester) async {
    final song = swappedSong();
    await versions.decide(
      song,
      player.ownRoutesFor(song).single,
      const FileFacts(bytes: 9062443, seconds: 226.5),
    );
    await pumpScreen(tester);
    expect(find.text('suggested version'), findsOneWidget);
    expect(find.byKey(ValueKey('version-tag-${song.id}')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('version-tag-${song.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Versions of Ты и я'), findsOneWidget);
    // VK's current file and the two uploads, the 219.2 s one suggested and
    // in use.
    expect(find.byKey(const ValueKey('version-use-1_1')), findsOneWidget);
    expect(find.textContaining('suggested match'), findsOneWidget);
    expect(find.textContaining("VK's current file"), findsOneWidget);
    expect(find.text('In use'), findsOneWidget);

    // The user picks VK's current file: kept, and the mark says so.
    await tester.tap(find.byKey(const ValueKey('version-use-1_1')));
    await tester.pumpAndSettle();
    expect(versions.choiceFor(song)!.state, VersionState.picked);
    expect(store.versionChoices()[song.id]!.fileKey, '1_1');
    expect(find.text('your version'), findsOneWidget);

    // Back to automatic.
    await tester.tap(find.byKey(ValueKey('version-tag-${song.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('versions-reset')));
    await tester.pumpAndSettle();
    expect(versions.choiceFor(song), isNull);
    expect(store.versionChoices(), isEmpty);
    expect(find.text('your version'), findsNothing);
  });

  testWidgets('a song with no match is marked as a different recording', (
    tester,
  ) async {
    final song = swappedSong();
    versions = VersionBook(
      store: store,
      find: (track, route) async => [upload('6_1', 226.5, listed: 226)],
      measure: (route) async => null,
    );
    player.versions = versions;
    await versions.decide(
      song,
      player.ownRoutesFor(song).single,
      const FileFacts(bytes: 9062443, seconds: 226.5),
    );
    await pumpScreen(tester);
    expect(find.text('different recording'), findsOneWidget);
  });

  testWidgets('every VK song offers its versions, and the dialog searches '
      'at once', (tester) async {
    // M1 (user, 2026-11-06): the item must be there before any swap was
    // found, or it cannot be discovered.
    final searches = <int>[];
    final search = Completer<List<SongVersion>>();
    versions = VersionBook(
      store: store,
      find: (track, route) {
        searches.add(track.id);
        return search.future;
      },
      measure: (route) async => const FileFacts(bytes: 9440000, seconds: 236),
    );
    player.versions = versions;
    final song = tracks.firstWhere((t) => t.sourceKey == '1_2');
    expect(versions.choiceFor(song), isNull);
    await pumpScreen(tester);

    await tester.tap(find.text('Выхода нет'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-versions')));
    await tester.pump();
    expect(find.text('Versions of Выхода нет'), findsOneWidget);
    expect(find.text('Looking for versions on VK...'), findsOneWidget);
    expect(searches, [song.id]);

    search.complete([
      SongVersion(
        key: '7_1',
        artist: 'Сплин',
        title: 'Выхода нет',
        listedSec: 251,
        file: const FileFacts(bytes: 10040000, seconds: 251),
      ),
    ]);
    await tester.pumpAndSettle();
    // VK's current file first; it plays the listed length, so it is the
    // suggested match and in use.
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('version-') &&
          !(w.key! as ValueKey<String>).value.startsWith('version-listen') &&
          !(w.key! as ValueKey<String>).value.startsWith('version-use'),
    );
    expect(
      [for (final w in tester.widgetList(rows)) (w.key! as ValueKey).value],
      ['version-1_2', 'version-7_1'],
    );
    expect(find.text('In use'), findsOneWidget);
    expect(find.textContaining("VK's current file"), findsOneWidget);
  });

  testWidgets('a song with no VK account to ask has no versions item', (
    tester,
  ) async {
    player = PlayerService(
      muted: true,
      dataDir: '.',
      accounts: (sourceId) => null,
    )..versions = versions;
    await pumpScreen(tester);
    await tester.tap(find.text('Выхода нет'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-play-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-versions')), findsNothing);
  });

  for (final side in [true, false]) {
    testWidgets('the ${side ? 'side panel' : 'bottom bar'} player offers '
        "the playing song's versions", (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final song = tracks.firstWhere((t) => t.sourceKey == '1_2');
      final showing = _ShowingPlayer(
        song,
        accounts: (sourceId) => VkClient(const []),
      )..versions = versions;
      final playback = PlaybackController(player: showing, recordPlay: (_) {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: side
                ? NowPlayingPanel(
                    playback: playback,
                    collections: null,
                    thumbnails: false,
                    onDockBottom: () {},
                    onGoToSong: () {},
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DockBar(
                        playback: playback,
                        collections: null,
                        thumbnails: false,
                        canDockSide: true,
                        onDockSide: () {},
                        onGoToSong: () {},
                        compact: false,
                      ),
                    ],
                  ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('versions-button')));
      await tester.pumpAndSettle();
      expect(find.text('Versions of Выхода нет'), findsOneWidget);
    });
  }

  testWidgets('Changed on VK lists the swapped songs', (tester) async {
    // M3 (user, 2026-11-06): swapped songs must be findable.
    await pumpScreen(tester);
    final nav = find.byKey(const ValueKey('nav-changed'));
    expect(nav, findsOneWidget);
    await tester.tap(nav);
    await tester.pumpAndSettle();
    expect(find.textContaining('No song changed on VK'), findsOneWidget);

    // The check after a sync finds Ты и я swapped: the view lists it.
    final song = swappedSong();
    await versions.decide(
      song,
      player.ownRoutesFor(song).single,
      const FileFacts(bytes: 9062443, seconds: 226.5),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ты и я'), findsOneWidget);
    expect(find.text('Выхода нет'), findsNothing);
    expect(find.text('suggested version'), findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('1')), findsOneWidget);

    // Back to automatic: it leaves the view.
    versions.reset(song);
    await tester.pumpAndSettle();
    expect(find.text('Ты и я'), findsNothing);
    expect(find.textContaining('No song changed on VK'), findsOneWidget);
  });
}
