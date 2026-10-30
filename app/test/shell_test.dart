import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/ui/sidebar.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/theme.dart';

/// A player that accepts songs without opening any audio, so the panel shows
/// a song as it does in the app.
class _StartedPlayer extends PlayerService {
  _StartedPlayer({super.storage}) : super(vk: null, muted: true, dataDir: '.');

  Track? _track;
  final played = <int>[];
  var pauseToggles = 0;

  @override
  bool get isReady => true;
  @override
  Track? get current => _track;
  @override
  bool get currentLoaded => true;
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Duration get position => const Duration(seconds: 20);
  @override
  Duration get duration => const Duration(seconds: 200);

  @override
  Future<PlayTiming> play(Track track) async {
    _track = track;
    played.add(track.id);
    return const PlayTiming(ok: true, cached: true, resolveMs: 0, toSoundMs: 1);
  }

  @override
  Future<void> playOrPause() async => pauseToggles++;
}

void main() {
  late LibraryStore store;
  late CollectionsController collections;
  late LibraryController library;
  late ShellSettings settings;
  late Map<String, String?> saved;
  late List<int> ids;

  setUp(() {
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    ids = store.upsertAll(vk, [
      for (var i = 0; i < 6; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Исполнитель $i',
          title: 'Песня $i',
          album: i.isEven ? 'Альбом' : null,
          durationSec: 200,
          addedAt: 100 - i,
        ),
    ]);
    store.saveAudioFile(ids[2], 'cache/a.mp3', 10, pinned: true);
    collections = CollectionsController(store);
    library = LibraryController(store.loadAll(), collections: collections);
    saved = {};
    settings = ShellSettings(
      read: (key) => saved[key],
      write: (key, value) => saved[key] = value,
    );
  });
  tearDown(() => store.close());

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    PlayerService? player,
  }) async {
    final playback = PlaybackController(
      player: player ?? PlayerService(vk: null, muted: true, dataDir: '.'),
      recordPlay: collections.recordPlay,
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          theme: buildTheme(settings.dark ? OwnColors.dark : OwnColors.light),
          home: LibraryScreen(
            library: library,
            playback: playback,
            collections: collections,
            settings: settings,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String heading(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byType(LibraryScreen),
          matching: find.byWidgetPredicate(
            (w) => w is Text && w.style?.fontSize == 26,
          ),
        ),
      )
      .data!;

  testWidgets('the sidebar switches views; later views say what they hold', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(heading(tester), 'All songs');
    expect(find.text('6 songs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-downloads')));
    await tester.pump();
    expect(heading(tester), 'Downloads');
    expect(library.visible.map((t) => t.id), [ids[2]]);

    await tester.tap(find.byKey(const ValueKey('nav-history')));
    await tester.pump();
    expect(find.text('Songs you play show up here.'), findsOneWidget);
    collections.recordPlay(library.byId(ids[0])!);
    collections.recordPlay(library.byId(ids[1])!);
    collections.recordPlay(library.byId(ids[0])!);
    await tester.pump();
    expect(library.visible.map((t) => t.id), [ids[0], ids[1], ids[0]]);

    await tester.tap(find.byKey(const ValueKey('nav-charts')));
    await tester.pump();
    expect(find.textContaining('Planned after the MVP'), findsOneWidget);
    expect(find.text('later'), findsNWidgets(3));
  });

  testWidgets('search works inside the view, repeats included', (tester) async {
    collections
      ..recordPlay(library.byId(ids[3])!)
      ..recordPlay(library.byId(ids[4])!)
      ..recordPlay(library.byId(ids[3])!);
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('nav-history')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'песня 3');
    await tester.pump();
    expect(library.visible.map((t) => t.id), [ids[3], ids[3]]);
    expect(find.text('2 of 3 songs'), findsOneWidget);
  });

  testWidgets('a new Stack from the right-click menu; the same song can go '
      'on top again and one entry can be removed', (tester) async {
    await pumpShell(tester);
    Future<void> rightClick(int id) async {
      await tester.tap(
        find.byKey(ValueKey('song-$id')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
    }

    await rightClick(ids[1]);
    await tester.tap(find.byKey(const ValueKey('new-stack')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-stack-name')),
      ' Вечер у моря ',
    );
    await tester.tap(find.byKey(const ValueKey('new-stack-create')));
    await tester.pumpAndSettle();
    final stack = collections.stacks.single;
    expect(stack.name, 'Вечер у моря');
    expect(find.text('Вечер у моря'), findsOneWidget, reason: 'in sidebar');

    await rightClick(ids[4]);
    await tester.tap(find.byKey(ValueKey('stack-${stack.id}')));
    await tester.pumpAndSettle();
    await rightClick(ids[1]);
    await tester.tap(find.byKey(ValueKey('stack-${stack.id}')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('nav-stack-${stack.id}')));
    await tester.pump();
    expect(heading(tester), 'Вечер у моря');
    expect(library.visible.map((t) => t.id), [ids[1], ids[4], ids[1]]);

    // Remove the top entry: the older entry of the same song stays.
    final top = library.entryIdAt(0)!;
    await tester.tap(
      find.byKey(ValueKey('entry-$top')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-remove-from-stack')));
    await tester.pumpAndSettle();
    expect(library.visible.map((t) => t.id), [ids[4], ids[1]]);
  });

  testWidgets('theme, thumbnails, rail and dock are kept as settings', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.text('Now playing'.toUpperCase()), findsOneWidget);
    expect(
      OwnColors.of(tester.element(find.byType(LibraryScreen))).isDark,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('toggle-theme')));
    await tester.pumpAndSettle();
    expect(saved['ui.theme'], 'light');
    expect(
      OwnColors.of(tester.element(find.byType(LibraryScreen))).isDark,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('toggle-thumbnails')));
    await tester.pump();
    expect(saved['ui.thumbnails'], 'off');
    expect(
      find.descendant(
        of: find.byKey(ValueKey('song-${ids[0]}')),
        matching: find.text('1'),
      ),
      findsOneWidget,
      reason: 'row numbers instead of tiles',
    );

    await tester.tap(find.byKey(const ValueKey('toggle-rail')));
    await tester.pump();
    expect(saved['ui.rail'], 'on');
    expect(find.text('Ownsemble'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dock-bottom')));
    await tester.pump();
    expect(saved['ui.dock'], 'bottom');
    expect(find.text('Now playing'.toUpperCase()), findsNothing);
    expect(find.byKey(const ValueKey('dock-side')), findsOneWidget);
  });

  testWidgets('a narrow window uses the bottom bar and the rail', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(900, 700));
    expect(find.text('Now playing'.toUpperCase()), findsNothing);
    expect(
      find.byKey(const ValueKey('dock-side')),
      findsNothing,
      reason: 'no room for the side panel',
    );
    expect(find.byKey(const ValueKey('play-pause')), findsOneWidget);

    await pumpShell(tester, size: const Size(700, 600));
    expect(find.text('Ownsemble'), findsNothing, reason: 'rail');
    expect(find.byKey(const ValueKey('toggle-rail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right click queues a song; Play next goes first', (
    tester,
  ) async {
    await pumpShell(tester);
    final playback = tester
        .widget<LibraryScreen>(find.byType(LibraryScreen))
        .playback;
    Future<void> queueSong(int id, String menuKey) async {
      await tester.tap(
        find.byKey(ValueKey('song-$id')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(menuKey)));
      await tester.pumpAndSettle();
    }

    await queueSong(ids[3], 'menu-add-to-queue');
    await queueSong(ids[4], 'menu-play-next');
    expect(
      [for (final t in playback.queue.queued) t.title],
      ['Песня 4', 'Песня 3'],
    );
  });

  testWidgets('Up next opens from a button, shows queued songs before the '
      'list and removes them', (tester) async {
    final songs = library.visible;
    final playback = PlaybackController(
      player: _StartedPlayer(),
      recordPlay: collections.recordPlay,
    );
    await playback.playFrom(songs, 0);
    await playback.addToQueue(songs[3]);
    await playback.addToQueue(songs[4]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: playback,
            builder: (context, _) =>
                UpNextButton(playback: playback, thumbnails: false),
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget, reason: 'the queued count');

    String titleOf(String key) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;

    await tester.tap(find.byKey(const ValueKey('up-next-open')));
    await tester.pumpAndSettle();
    expect(titleOf('queued-0'), 'Песня 3');
    expect(titleOf('queued-1'), 'Песня 4');
    expect(titleOf('up-next-0'), 'Песня 1', reason: 'the list follows');

    await tester.tap(find.byKey(const ValueKey('queued-remove-0')));
    await tester.pumpAndSettle();
    expect(titleOf('queued-0'), 'Песня 4', reason: 'the open list updates');
    expect(find.byKey(const ValueKey('queued-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('queued-0')));
    await tester.pumpAndSettle();
    expect(playback.queue.current?.title, 'Песня 4', reason: 'plays now');
    expect(playback.queue.queued, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // Bug of 2026-10-30: "Cannot play: ..." covered the whole window bottom
  // for 4 s, so a click on the seek bar under it did nothing.
  group('save progress', () {
    late AudioStorage storage;
    late Track song;

    Future<void> showPlaying(WidgetTester tester) async {
      final player = _StartedPlayer(storage: storage);
      await player.play(song);
      await pumpShell(tester, player: player);
    }

    /// How much of the row's icon is filled, from what its clip keeps.
    double fillOf(WidgetTester tester, Finder icon) {
      final clip = tester.widget<ClipRect>(
        find.descendant(of: icon, matching: find.byType(ClipRect)),
      );
      return 1 - clip.clipper!.getClip(const Size(100, 100)).top / 100;
    }

    double? band(WidgetTester tester) => tester
        .widget<Slider>(find.byKey(const ValueKey('seek')))
        .secondaryTrackValue;

    setUp(() {
      storage = AudioStorage(dataDir: '.', store: store);
      song = library.all.firstWhere((t) => t.id == ids[0]);
    });

    testWidgets('a song saved while streaming: the row\'s cloud and the seek '
        'bar\'s band follow it', (tester) async {
      await showPlaying(tester);
      final saving = find.byKey(ValueKey('filling-${song.id}'));
      expect(saving, findsNothing, reason: 'not saving yet');
      expect(band(tester), 0);

      final save = Completer<int?>();
      storage.noteSaving(song, save.future);
      await tester.pump();
      expect(fillOf(tester, saving), 0);

      storage.noteProgress(song, 40, 100);
      await tester.pump();
      expect(fillOf(tester, saving), closeTo(0.4, 0.001));
      expect(band(tester), closeTo(0.4 * 200, 0.001));

      // Stored: the plain cached mark, and the whole bar is saved.
      save.complete(100);
      storage.recordStored(song, 'cache/a.mp3', 100);
      await tester.pump();
      await tester.pump();
      expect(saving, findsNothing);
      expect(
        find.byKey(
          ValueKey('mark-${song.id}-${Icons.cloud_done_outlined.codePoint}'),
        ),
        findsOneWidget,
      );
      expect(band(tester), 200);
    });

    testWidgets('a canceled save takes the band back to nothing', (
      tester,
    ) async {
      await showPlaying(tester);
      final save = Completer<int?>();
      storage.noteSaving(song, save.future);
      storage.noteProgress(song, 40, 100);
      await tester.pump();
      save.complete(null);
      await tester.pump();
      await tester.pump();
      expect(band(tester), 0);
      expect(find.byKey(ValueKey('filling-${song.id}')), findsNothing);
    });

    testWidgets('a download fills the row\'s mark and the Download button', (
      tester,
    ) async {
      await showPlaying(tester);
      final release = Completer<void>();
      final download = storage.download(song, () async {
        await release.future;
        return null;
      });
      storage.noteProgress(song, 30, 100);
      await tester.pump();
      expect(
        fillOf(tester, find.byKey(ValueKey('filling-${song.id}'))),
        closeTo(0.3, 0.001),
      );
      expect(
        fillOf(tester, find.byKey(const ValueKey('download'))),
        closeTo(0.3, 0.001),
      );
      release.complete();
      await expectLater(download, throwsA(isA<StateError>()));
      await tester.pump();
      expect(find.byKey(ValueKey('filling-${song.id}')), findsNothing);
    });
  });

  testWidgets('Space types in text fields and plays or pauses elsewhere', (
    tester,
  ) async {
    final player = _StartedPlayer();
    await pumpShell(tester, player: player);

    // The search box has the focus when the app opens.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.pauseToggles, 0, reason: 'typing in the search box');

    await tester.tap(find.byKey(ValueKey('song-${ids[1]}')));
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.pauseToggles, 1, reason: 'no text field has the focus');

    // Any other text field counts too: the New Stack dialog.
    await tester.tap(
      find.byKey(ValueKey('song-${ids[1]}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-stack')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.pauseToggles, 1, reason: 'typing a Stack name');
  });

  testWidgets('messages never cover the player or the sidebar', (tester) async {
    for (final size in const [Size(1400, 900), Size(900, 700)]) {
      await pumpShell(tester, size: size);
      ScaffoldMessenger.of(tester.element(find.byType(LibraryScreen)))
          .showSnackBar(const SnackBar(content: Text('Cannot play: test')));
      await tester.pumpAndSettle();
      // The visible card; the SnackBar's own box includes its margins.
      final message = tester.getRect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      for (final part in [
        find.byType(Sidebar),
        find.byType(NowPlayingPanel),
        find.byType(DockBar),
      ]) {
        if (part.evaluate().isEmpty) continue;
        expect(
          message.overlaps(tester.getRect(part)),
          isFalse,
          reason:
              '$size: the message covers ${part.describeMatch(Plurality.one)}',
        );
      }
      ScaffoldMessenger.of(tester.element(find.byType(LibraryScreen)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }
  });
}
