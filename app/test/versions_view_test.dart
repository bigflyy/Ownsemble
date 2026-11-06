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

/// A song's versions open as a place in the list, like an album, with the
/// app's own rows (plan 03, user 2026-11-06: the old pop-up "shouldnt look
/// like something from outside").
void main() {
  late LibraryStore store;
  late List<Track> tracks;
  late VersionBook versions;
  late PlayerService player;
  late LibraryController library;

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
      find: (track, route, progress) async => [
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
  Track plainSong() => tracks.firstWhere((t) => t.sourceKey == '1_2');

  Future<void> pumpScreen(WidgetTester tester) async {
    // Wide enough for the Album column, so row tags show their labels.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    library = LibraryController(tracks, versions: player.versions);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          playback: PlaybackController(player: player),
        ),
      ),
    );
    await tester.pump();
  }

  /// The row of upload [key] of [song]'s versions.
  Finder versionRow(Track song, String key) => find.byKey(
    ValueKey('song-${versions.versionTrack(song, upload(key, 1)).id}'),
  );

  /// The version keys of the rows shown, top to bottom.
  List<String> shownKeys() => [
    for (final track in library.visible) library.versionOf(track)!.key,
  ];

  /// Whether the row of [key] carries the tag [label].
  bool hasTag(Track song, String key, String label) => find
      .descendant(
        of: versionRow(song, key),
        matching: find.byKey(ValueKey('version-tag-$label')),
      )
      .evaluate()
      .isNotEmpty;

  testWidgets('the mark opens the versions as a list; the menu uses one '
      'and goes back to automatic', (tester) async {
    final song = swappedSong();
    await versions.decide(
      song,
      player.ownRoutesFor(song).single,
      const FileFacts(bytes: 9062443, seconds: 226.5),
    );
    await pumpScreen(tester);
    expect(find.text('suggested version'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('version-tag-${song.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Versions of Ты и я'), findsOneWidget);
    expect(find.text('3 versions'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-back')), findsOneWidget);
    // VK's file first, then the one that plays, then the rest.
    expect(shownKeys(), ['1_1', '5_1', '6_1']);
    expect(hasTag(song, '1_1', "VK's file now"), isTrue);
    expect(hasTag(song, '5_1', 'in use'), isTrue);
    expect(hasTag(song, '5_1', 'suggested'), isTrue);
    expect(hasTag(song, '1_1', 'in use'), isFalse);
    // Real lengths in the Time column, as on every song row.
    expect(
      find.descendant(of: versionRow(song, '1_1'), matching: find.text('3:47')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: versionRow(song, '5_1'), matching: find.text('3:39')),
      findsOneWidget,
    );
    expect(find.textContaining('your library lists 3:39'), findsOneWidget);
    expect(find.textContaining("VK's file now plays 3:47"), findsOneWidget);
    expect(
      find.textContaining('Plays the suggested 3:39 upload'),
      findsOneWidget,
    );

    // Right click VK's file: Use this version.
    await tester.tap(versionRow(song, '1_1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-use-version')));
    await tester.pumpAndSettle();
    expect(versions.choiceFor(song)!.state, VersionState.picked);
    expect(store.versionChoices()[song.id]!.fileKey, '1_1');
    expect(find.textContaining('now plays this version'), findsOneWidget);
    expect(hasTag(song, '1_1', 'in use'), isTrue);
    expect(hasTag(song, '5_1', 'in use'), isFalse);

    // Back to automatic, from any row's menu.
    await tester.tap(versionRow(song, '6_1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-versions-reset')));
    await tester.pumpAndSettle();
    expect(versions.choiceFor(song), isNull);
    expect(store.versionChoices(), isEmpty);

    // Back returns to the list it came from.
    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.songs);
    expect(find.text('Выхода нет'), findsOneWidget);
  });

  testWidgets('a song with no match is marked as a different recording', (
    tester,
  ) async {
    final song = swappedSong();
    versions = VersionBook(
      store: store,
      find: (track, route, progress) async => [
        upload('6_1', 226.5, listed: 226),
      ],
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

  testWidgets('the search starts when the menu opens; uploads show as VK '
      'answers, lengths as they are measured', (tester) async {
    // M1 (user, 2026-11-06): every VK song offers its versions.
    final searches = <int>[];
    final search = Completer<void>();
    final found = [
      const SongVersion(
        key: '7_1',
        artist: 'Сплин',
        title: 'Выхода нет',
        listedSec: 251,
        file: FileFacts(bytes: 10040000, seconds: 251),
      ),
    ];
    versions = VersionBook(
      store: store,
      find: (track, route, progress) async {
        searches.add(track.id);
        progress?.call(
          [
            const SongVersion(
              key: '7_1',
              artist: 'Сплин',
              title: 'Выхода нет',
              listedSec: 251,
            ),
          ],
          {'7_1'},
        );
        await search.future;
        return found;
      },
      measure: (route) async => const FileFacts(bytes: 9440000, seconds: 236),
    );
    player.versions = versions;
    final song = plainSong();
    await pumpScreen(tester);

    await tester.tap(find.text('Выхода нет'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // Asked before "Versions" is clicked.
    expect(searches, [song.id]);
    await tester.tap(find.byKey(const ValueKey('menu-versions')));
    await tester.pump();
    expect(find.text('Versions of Выхода нет'), findsOneWidget);
    expect(shownKeys(), ['1_2', '7_1']);
    expect(hasTag(song, '7_1', 'measuring'), isTrue);
    expect(find.textContaining('Measuring files: 0 of 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('versions-searching')), findsOneWidget);

    search.complete();
    await tester.pumpAndSettle();
    expect(searches, [song.id]);
    expect(hasTag(song, '7_1', 'measuring'), isFalse);
    // No choice: VK's file plays, and it is in use.
    expect(hasTag(song, '1_2', 'in use'), isTrue);
    expect(
      find.descendant(of: versionRow(song, '7_1'), matching: find.text('4:11')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('versions-refresh')), findsOneWidget);
    // Kept: the next time it opens at once.
    expect(store.foundVersions(song.id)?.versions.single.key, '7_1');
  });

  testWidgets('a list found before opens at once, without asking VK', (
    tester,
  ) async {
    var searches = 0;
    versions = VersionBook(
      store: store,
      find: (track, route, progress) async {
        searches++;
        return const [];
      },
      measure: (route) async => const FileFacts(bytes: 9440000, seconds: 236),
    );
    player.versions = versions;
    final song = plainSong();
    store.saveFoundVersions(song.id, [upload('8_1', 236, listed: 236)]);
    await pumpScreen(tester);
    await tester.tap(find.text('Выхода нет'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-versions')));
    await tester.pump();
    expect(shownKeys(), ['1_2', '8_1']);
    expect(find.byKey(const ValueKey('versions-searching')), findsNothing);
    await tester.pumpAndSettle();
    expect(searches, 0);
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
    testWidgets('the ${side ? 'side panel' : 'bottom bar'} player opens '
        "the playing song's versions", (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final song = plainSong();
      final opened = <Track>[];
      final showing = _ShowingPlayer(
        song,
        accounts: (sourceId) => VkClient(const []),
      )..versions = versions;
      final playback = PlaybackController(player: showing);
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
                    onOpenVersions: opened.add,
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
                        onOpenVersions: opened.add,
                      ),
                    ],
                  ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('versions-button')));
      await tester.pump();
      expect(opened.map((t) => t.id), [song.id]);
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
