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
import 'package:ownsemble/storage/cover_store.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/cover_tile.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/ui/sidebar.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/ui/type_jump.dart';

/// A player that accepts songs without opening any audio, so the panel shows
/// a song as it does in the app.
class _StartedPlayer extends PlayerService {
  _StartedPlayer({super.storage}) : super(vk: null, muted: true, dataDir: '.');

  Track? _track;
  final _changes = StreamController<Track?>.broadcast();
  final played = <int>[];
  final seekOffsets = <Duration>[];
  double? lastVolume;
  bool? lastMuted;
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
  Stream<Track?> get currentStream => _changes.stream;

  @override
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    _track = track;
    played.add(track.id);
    _changes.add(track);
    return const PlayTiming(ok: true, cached: true, resolveMs: 0, toSoundMs: 1);
  }

  @override
  Future<void> playOrPause() async => pauseToggles++;
  @override
  Future<void> seekBy(Duration offset) async => seekOffsets.add(offset);
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setVolume(double volume) async => lastVolume = volume;
  @override
  Future<void> setMuted(bool mute) async => lastMuted = mute;
}

/// A cover store with nothing stored that never answers, so tiles stay at
/// their loading color and no test reaches the network.
class _SilentCovers extends CoverStore {
  _SilentCovers() : super(dataDir: '.');

  @override
  String? storedPath(String url) => null;

  @override
  CoverRequest? fetch(String url, void Function(String? path) onDone) => null;
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
          // Песня 5 has no cover, like a song without an album on VK.
          coverUrl: i == 5 ? null : 'https://img.example/$i.jpg?size=135',
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
      CoverScope(
        store: _SilentCovers(),
        child: ListenableBuilder(
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
      ),
    );
    await tester.pump();
  }

  testWidgets('the first frame shows the restored song, paused at its place, '
      'before the player is ready', (tester) async {
    final player = PlayerService(vk: null, muted: true, dataDir: '.');
    final track = store.loadAll()[1];
    player.restore(track, const Duration(seconds: 42));
    await pumpShell(tester, player: player);
    expect(player.isReady, isFalse);
    final panel = find.byType(NowPlayingPanel);
    expect(
      find.descendant(of: panel, matching: find.text(track.title)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('0:42')),
      findsOneWidget,
    );
    final play = tester.widget<IconButton>(
      find.byKey(const ValueKey('play-pause')),
    );
    expect(play.onPressed, isNotNull);
    expect(play.tooltip, 'Play (Space)');
  });

  group('keyboard', () {
    late _StartedPlayer player;
    late PlaybackController playback;

    Future<void> withControl(
      WidgetTester tester,
      Future<void> Function() keys,
    ) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await keys();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    Future<void> pumpPlaying(WidgetTester tester) async {
      player = _StartedPlayer();
      await pumpShell(tester, player: player);
      playback = tester
          .widget<LibraryScreen>(find.byType(LibraryScreen))
          .playback;
      await playback.playFrom(library.visible, 1);
      await tester.pump();
    }

    testWidgets('Space works right after the start, nothing typed', (
      tester,
    ) async {
      await pumpPlaying(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(player.pauseToggles, 1);
      expect(library.searchText.text, isEmpty);
    });

    testWidgets('Left and Right seek by 5 s', (tester) async {
      await pumpPlaying(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(player.seekOffsets, [seekKeyStep, -seekKeyStep]);
    });

    testWidgets('a used key stops: arrows leave the focus where it is', (
      tester,
    ) async {
      await pumpPlaying(tester);
      final before = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, before);
    });

    testWidgets('a held arrow steps the volume but seeks only once', (
      tester,
    ) async {
      await pumpPlaying(tester);
      await playback.setVolume(50);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      expect(playback.volume, 60);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(playback.volume, 55);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(player.seekOffsets, hasLength(1));
    });

    testWidgets('Ctrl+Right and Ctrl+Left change the song', (tester) async {
      await pumpPlaying(tester);
      await withControl(tester, () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      });
      expect(player.played, [ids[1], ids[2]]);
      expect(player.seekOffsets, isEmpty);
      await withControl(tester, () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      });
      // 20 s in, Previous restarts the song.
      expect(player.played, [ids[1], ids[2]]);
    });

    testWidgets('Ctrl+M, Ctrl+S and Ctrl+R go by the key, not the layout', (
      tester,
    ) async {
      await pumpPlaying(tester);
      await withControl(tester, () async {
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyV,
          physicalKey: PhysicalKeyboardKey.keyM,
        );
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyK,
          physicalKey: PhysicalKeyboardKey.keyS,
        );
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyP,
          physicalKey: PhysicalKeyboardKey.keyR,
        );
      });
      expect(playback.mutedByUser, isTrue);
      expect(player.lastMuted, isTrue);
      expect(playback.shuffle, isTrue);
      expect(playback.repeat.name, 'list');
    });

    testWidgets('in the search box the keys edit text; Esc leaves it', (
      tester,
    ) async {
      await pumpPlaying(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await withControl(tester, () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      });
      expect(player.seekOffsets, isEmpty);
      expect(player.lastVolume, isNull);
      expect(playback.mutedByUser, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(player.seekOffsets, [seekKeyStep]);
    });

    testWidgets('in an open menu the arrows choose', (tester) async {
      await pumpPlaying(tester);
      await tester.tap(find.text('Песня 0'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(player.seekOffsets, isEmpty);
      expect(player.lastVolume, isNull);
    });

    testWidgets('a slider reached with Tab keeps the arrows', (tester) async {
      // Started before the screen is built, so the panel shows its sliders.
      player = _StartedPlayer();
      await player.play(store.loadAll()[1]);
      await pumpShell(tester, player: player);
      // The render widget inside the Slider, below the Slider's own Focus.
      final inside = find.descendant(
        of: find.byKey(const ValueKey('volume')),
        matching: find.byType(Semantics),
      );
      Focus.of(tester.element(inside.last)).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused?.findAncestorWidgetOfExactType<Slider>(), isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(player.seekOffsets, isEmpty);
    });

    group('type to jump', () {
      /// Types [text] on the list, the way Windows delivers a letter: a key
      /// with its text. Cyrillic has no logical key of its own, so one key
      /// stands for all of them; only the text counts.
      Future<void> typeOnList(WidgetTester tester, String text) async {
        for (final character in text.split('')) {
          await tester.sendKeyEvent(
            character == ' '
                ? LogicalKeyboardKey.space
                : LogicalKeyboardKey.keyA,
            character: character,
          );
        }
        await tester.pump();
      }

      Finder jumpPill() => find.byKey(const ValueKey('jump-pill'));

      String pillText(WidgetTester tester) => tester
          .widget<Text>(
            find.descendant(of: jumpPill(), matching: find.byType(Text)),
          )
          .textSpan!
          .toPlainText();

      /// Whether the song row of song [index] has the jump's outline.
      bool outlined(WidgetTester tester, int index) {
        final row = find.byKey(ValueKey('song-${ids[index]}'));
        final material = tester.widget<Material>(
          find.descendant(of: row, matching: find.byType(Material)).first,
        );
        final shape = material.shape! as RoundedRectangleBorder;
        return shape.side != BorderSide.none;
      }

      testWidgets('letters jump without filtering, also in Cyrillic', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'песня 3');
        expect(library.visible, hasLength(6));
        expect(library.searchText.text, isEmpty);
        expect(library.jump.row, 3);
        expect(outlined(tester, 3), isTrue);
        expect(outlined(tester, 1), isFalse);
        expect(pillText(tester), 'песня 3  1 of 1');
        await tester.pump(TypeJump.resetAfter);
      });

      testWidgets('the row outlives the text and its pill', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'п');
        expect(jumpPill(), findsOneWidget);
        await tester.pump(TypeJump.resetAfter);
        await tester.pump();
        expect(jumpPill(), findsNothing);
        expect(outlined(tester, 0), isTrue);
      });

      testWidgets('no match says so and outlines nothing', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'пя');
        expect(library.jump.row, isNull);
        expect(outlined(tester, 0), isFalse);
        expect(pillText(tester), 'пя  no match');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(library.jump.row, 0);
        await tester.pump(TypeJump.resetAfter);
      });

      testWidgets('during a jump Down and Up move, held too, and not the '
          'volume', (tester) async {
        await pumpPlaying(tester);
        await playback.setVolume(50);
        await typeOnList(tester, 'п');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(library.jump.row, 1);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        expect(library.jump.row, 3);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(library.jump.row, 2);
        expect(playback.volume, 50);
        await tester.pump(TypeJump.resetAfter);
      });

      testWidgets('once the text is gone Up is the volume again', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await playback.setVolume(50);
        await typeOnList(tester, 'п');
        await tester.pump(TypeJump.resetAfter);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(playback.volume, 55);
        expect(library.jump.row, 0);
      });

      testWidgets('Space joins letters, alone it stays play and pause', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
        expect(player.pauseToggles, 1);
        expect(library.jump.isTyping, isFalse);
        await typeOnList(tester, 'песня 4');
        expect(player.pauseToggles, 1);
        expect(library.jump.row, 4);
        await tester.pump(TypeJump.resetAfter);
        await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
        expect(player.pauseToggles, 2, reason: 'the text is gone');
      });

      testWidgets('Enter plays the row and ends the jump', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'песня 4');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(player.played, [ids[1], ids[4]]);
        expect(library.jump.row, isNull);
        expect(library.jump.isTyping, isFalse);
      });

      testWidgets('Enter with no match plays nothing', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'я');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(player.played, [ids[1]]);
        await tester.pump(TypeJump.resetAfter);
      });

      testWidgets('Esc ends the jump first, then clears the search', (
        tester,
      ) async {
        await pumpPlaying(tester);
        library.searchText.text = 'песня';
        await tester.pump();
        await typeOnList(tester, 'п');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(library.jump.row, isNull);
        expect(library.searchText.text, 'песня');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(library.searchText.text, isEmpty);
      });

      testWidgets('a click on a row ends the jump', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'п');
        await tester.tap(find.byKey(ValueKey('song-${ids[3]}')));
        await tester.pump();
        expect(library.jump.row, isNull);
        expect(player.played, [ids[1], ids[3]]);
      });

      testWidgets('going to the search box ends the jump, letters stay '
          'out of it', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'п');
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(library.jump.row, isNull);
        expect(library.jump.isTyping, isFalse);
        await typeOnList(tester, 'п');
        expect(library.jump.isTyping, isFalse);
      });

      testWidgets('a change of the list ends the jump', (tester) async {
        await pumpPlaying(tester);
        await typeOnList(tester, 'п');
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        expect(library.jump.row, isNull);
        library.showView(LibraryView.songs);
        await tester.pump();
        await typeOnList(tester, 'п');
        library.searchText.text = 'песня 1';
        await tester.pump();
        expect(library.jump.row, isNull);
      });

      testWidgets('with Ctrl or Alt held letters are not typed', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await withControl(tester, () async {
          await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: 'q');
        });
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: 'q');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        expect(library.jump.isTyping, isFalse);
      });

      testWidgets('Shift letters are typed', (tester) async {
        await pumpPlaying(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'П');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(library.jump.row, 0);
        await tester.pump(TypeJump.resetAfter);
      });

      testWidgets('not under a dialog, not on a later page', (tester) async {
        await pumpPlaying(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.f1);
        await tester.pumpAndSettle();
        await typeOnList(tester, 'п');
        expect(library.jump.isTyping, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        library.showView(const LibraryView(ViewKind.artists));
        await tester.pump();
        await typeOnList(tester, 'п');
        expect(library.jump.isTyping, isFalse);
      });

      testWidgets('a row out of sight scrolls to a third down; a row in '
          'sight does not scroll', (tester) async {
        final many = store.ensureSource(
          TrackSource.vk,
          account: '2',
          name: 'VK',
        );
        store.upsertAll(many, [
          for (var i = 0; i < 300; i++)
            NewTrack(
              sourceKey: '2_$i',
              artist: 'Filler',
              title: 'Filler $i',
              durationSec: 200,
              addedAt: -i - 1,
            ),
          const NewTrack(
            sourceKey: '2_last',
            artist: 'Finish',
            title: 'Zebra',
            durationSec: 200,
            addedAt: -1000,
          ),
        ]);
        library = LibraryController(store.loadAll(), collections: collections);
        await pumpPlaying(tester);
        final inSight = library.visible.indexWhere((t) => t.title == 'Песня 4');
        await typeOnList(tester, 'песня 4');
        expect(library.jump.row, inSight);
        expect(library.scroll.offset, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);

        final middle = library.visible.indexWhere(
          (t) => t.title == 'Filler 150',
        );
        await typeOnList(tester, 'filler 150');
        await tester.pump();
        final height = library.scroll.position.viewportDimension;
        expect(library.scroll.offset, middle * rowHeight - height / 3);
        expect(
          find.byKey(ValueKey('song-${library.visible[middle].id}')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);

        await typeOnList(tester, 'zebra');
        await tester.pump();
        expect(
          library.scroll.offset,
          library.scroll.position.maxScrollExtent,
          reason: 'the last row cannot be a third down',
        );
        await tester.pump(TypeJump.resetAfter);
      });
    });

    group('places', () {
      /// A library long enough to scroll, songs named Filler 0 to Filler 299
      /// after the 6 Песня songs.
      void addManySongs() {
        final many = store.ensureSource(
          TrackSource.vk,
          account: '2',
          name: 'VK',
        );
        store.upsertAll(many, [
          for (var i = 0; i < 300; i++)
            NewTrack(
              sourceKey: '2_$i',
              artist: 'Filler',
              title: 'Filler $i',
              album: i == 150 ? 'Редкий альбом' : null,
              durationSec: 200,
              addedAt: -i - 1,
            ),
        ]);
        library = LibraryController(
          store.loadAll(),
          collections: collections,
          readSetting: (key) => saved[key],
          writeSetting: (key, value) => saved[key] = value,
        );
      }

      int rowOf(String title) =>
          library.visible.indexWhere((t) => t.title == title);

      /// Scrolls song [title] on screen and plays it with a click.
      Future<void> clickSong(WidgetTester tester, String title) async {
        final row = rowOf(title);
        if (library.scroll.hasClients) {
          library.scroll.jumpTo(
            (row * rowHeight).clamp(0, library.scroll.position.maxScrollExtent),
          );
          await tester.pump();
        }
        final track = library.visible[row];
        await tester.tap(find.byKey(ValueKey('song-${track.id}')));
        await tester.pump();
      }

      Future<void> pressCtrlL(WidgetTester tester) async {
        await withControl(
          tester,
          () => tester.sendKeyEvent(LogicalKeyboardKey.keyL),
        );
        await tester.pump();
      }

      Future<void> pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        await tester.pump();
      }

      Future<void> clickMouseButton(WidgetTester tester, int button) async {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: button,
        );
        await gesture.down(tester.getCenter(find.byType(ListView).at(1)));
        await gesture.up();
        await tester.pump();
        await tester.pump();
      }

      testWidgets('Ctrl+L opens the list the song was played from, shows the '
          'row and outlines it', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        await clickSong(tester, 'Filler 150');
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();

        await pressCtrlL(tester);
        expect(library.view, LibraryView.songs);
        final row = rowOf('Filler 150');
        expect(library.jump.row, row);
        final height = library.scroll.position.viewportDimension;
        expect(library.scroll.offset, row * rowHeight - height / 3);
        expect(find.textContaining('Filler 150'), findsWidgets);
        expect(
          find.byKey(ValueKey('song-${library.visible[row].id}')),
          findsOneWidget,
        );
      });

      testWidgets('the search it was played from comes back', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        library.searchText.text = 'filler 15';
        await tester.pump();
        await clickSong(tester, 'Filler 150');
        library.searchText.clear();
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();

        await pressCtrlL(tester);
        expect(library.view, LibraryView.songs);
        expect(library.searchText.text, 'filler 15');
        expect(library.visible.length, lessThan(20));
        expect(library.jump.row, rowOf('Filler 150'));
      });

      testWidgets('a list that lost the song gives way to All songs', (
        tester,
      ) async {
        await pumpPlaying(tester);
        final song = library.visible[3];
        final stackId = collections.createStack('Стопка');
        collections.addToStack(stackId, song);
        final stack = LibraryView(ViewKind.stack, stackId: stackId);
        library.showView(stack);
        await tester.pump();
        final entry = library.entryIdAt(0)!;
        await tester.tap(find.byKey(ValueKey('entry-$entry')));
        await tester.pump();
        collections.removeStackEntry(entry);
        await tester.pump();

        await pressCtrlL(tester);
        expect(library.view, LibraryView.songs);
        expect(library.jump.row, rowOf(song.title));
      });

      testWidgets('with repeats the row that played is the one found', (
        tester,
      ) async {
        await pumpPlaying(tester);
        final song = library.visible[3];
        final other = library.visible[4];
        final stackId = collections.createStack('Стопка');
        collections.addToStack(stackId, song);
        collections.addToStack(stackId, other);
        collections.addToStack(stackId, song);
        library.showView(LibraryView(ViewKind.stack, stackId: stackId));
        await tester.pump();
        expect(library.visible.map((t) => t.id), [song.id, other.id, song.id]);
        await tester.tap(find.byKey(ValueKey('entry-${library.entryIdAt(2)}')));
        await tester.pump();
        library.showView(LibraryView.songs);
        await tester.pump();

        await pressCtrlL(tester);
        expect(library.jump.row, 2);
      });

      testWidgets('a click on the title does the same, in both docks', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await clickSong(tester, 'Песня 3');
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('go-to-song')));
        await tester.pump();
        await tester.pump();
        expect(library.view, LibraryView.songs);
        expect(library.jump.row, rowOf('Песня 3'));

        await tester.tap(find.byKey(const ValueKey('dock-bottom')));
        await tester.pump();
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('go-to-song')));
        await tester.pump();
        await tester.pump();
        expect(library.view, LibraryView.songs);
        expect(library.jump.row, rowOf('Песня 3'));
      });

      testWidgets('nothing playing: Ctrl+L does nothing', (tester) async {
        await pumpShell(tester, player: _StartedPlayer());
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        await pressCtrlL(tester);
        expect(library.view, const LibraryView(ViewKind.history));
        expect(library.jump.row, isNull);
      });

      testWidgets('a row already in sight is only outlined: no scroll, and '
          'no place to go back to', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        await clickSong(tester, 'Filler 150');
        final before = library.scroll.offset;

        await pressCtrlL(tester);
        expect(library.jump.row, rowOf('Filler 150'));
        expect(library.scroll.offset, before);
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(
          library.jump.row,
          rowOf('Filler 150'),
          reason: 'nothing to undo',
        );
        expect(library.scroll.offset, before);
      });

      testWidgets('Ctrl+L from the search box leaves it, so Enter plays', (
        tester,
      ) async {
        await pumpPlaying(tester);
        await clickSong(tester, 'Песня 3');
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);

        await pressCtrlL(tester);
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<EditableText>(),
          isNull,
        );
        expect(library.jump.row, rowOf('Песня 3'));
      });

      testWidgets('the list it was played from outlives a restart', (
        tester,
      ) async {
        addManySongs();
        await pumpPlaying(tester);
        library.searchText.text = 'filler 15';
        await tester.pump();
        await clickSong(tester, 'Filler 150');

        final tracks = store.loadAll();
        final next = LibraryController(
          tracks,
          collections: collections,
          readSetting: (key) => saved[key],
          writeSetting: (key, value) => saved[key] = value,
        );
        addTearDown(next.dispose);
        next.goToSong(tracks.firstWhere((t) => t.title == 'Filler 150'));
        expect(next.searchText.text, 'filler 15');
        expect(next.visible.length, lessThan(20));
      });

      testWidgets('Alt+Left and Alt+Right walk views, searches and the '
          'scroll offset', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        library.scroll.jumpTo(3000);
        await tester.pump();

        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        library.showView(const LibraryView(ViewKind.downloads));
        await tester.pump();

        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.view, const LibraryView(ViewKind.history));
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.view, LibraryView.songs);
        expect(library.scroll.offset, 3000);
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.view, LibraryView.songs, reason: 'nothing further back');
        expect(library.scroll.offset, 3000);

        await pressAlt(tester, LogicalKeyboardKey.arrowRight);
        expect(library.view, const LibraryView(ViewKind.history));
        await pressAlt(tester, LogicalKeyboardKey.arrowRight);
        expect(library.view, const LibraryView(ViewKind.downloads));
        await pressAlt(tester, LogicalKeyboardKey.arrowRight);
        expect(library.view, const LibraryView(ViewKind.downloads));
      });

      testWidgets('a search is a place; its letters are not', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        library.scroll.jumpTo(3000);
        await tester.pump();

        for (final text in ['f', 'fi', 'fil', 'fill']) {
          library.searchText.text = text;
          await tester.pump();
        }
        library.scroll.jumpTo(500);
        await tester.pump();
        library.searchText.clear();
        await tester.pump();
        expect(library.scroll.offset, 0);

        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.searchText.text, 'fill');
        expect(library.scroll.offset, 500);
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.searchText.text, isEmpty);
        expect(library.scroll.offset, 3000);
        await pressAlt(tester, LogicalKeyboardKey.arrowRight);
        expect(library.searchText.text, 'fill');
        expect(library.searchText.selection.baseOffset, 4);
      });

      testWidgets('a new search typed over the old one is a new place', (
        tester,
      ) async {
        addManySongs();
        await pumpPlaying(tester);
        library.searchText.text = 'filler';
        await tester.pump();
        library.searchText.text = 'песня';
        await tester.pump();
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.searchText.text, 'filler');
      });

      testWidgets('going to the song is a place to come back from', (
        tester,
      ) async {
        addManySongs();
        await pumpPlaying(tester);
        await clickSong(tester, 'Filler 150');
        library.scroll.jumpTo(100);
        await tester.pump();

        await pressCtrlL(tester);
        expect(library.scroll.offset, greaterThan(100));
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.scroll.offset, 100);
        expect(library.jump.row, isNull, reason: 'the outline stays behind');
      });

      testWidgets('the same click on a view again is not a place', (
        tester,
      ) async {
        await pumpPlaying(tester);
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.view, LibraryView.songs);
      });

      testWidgets('the mouse side buttons go back and forward', (tester) async {
        addManySongs();
        await pumpPlaying(tester);
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();
        await clickMouseButton(tester, kBackMouseButton);
        expect(library.view, LibraryView.songs);
        await clickMouseButton(tester, kForwardMouseButton);
        expect(library.view, const LibraryView(ViewKind.history));
      });

      testWidgets('going back works from the search box, not under a dialog', (
        tester,
      ) async {
        await pumpPlaying(tester);
        library.showView(const LibraryView(ViewKind.history));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.f1);
        await tester.pumpAndSettle();
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        await pressCtrlL(tester);
        expect(library.view, const LibraryView(ViewKind.history));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await tester.tap(find.byType(TextField));
        await tester.pump();
        await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
        expect(library.view, LibraryView.songs);
      });
    });

    testWidgets('F1 and the toolbar button list the shortcuts', (tester) async {
      await pumpPlaying(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shortcuts-help')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shortcuts-help')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('keyboard-help')));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + M'), findsOneWidget);
    });
  });

  group('the view is kept between runs', () {
    LibraryController restart() => LibraryController(
      store.loadAll(),
      collections: collections,
      readSetting: (key) => saved[key],
      writeSetting: (key, value) => saved[key] = value,
    );

    test('History comes back with its songs listed', () {
      collections.recordPlay(store.loadAll().first);
      restart().showView(const LibraryView(ViewKind.history));
      final second = restart();
      expect(second.view, const LibraryView(ViewKind.history));
      expect(second.visible, hasLength(1));
    });

    test('a Stack comes back; a deleted one falls back to all songs', () {
      final stackId = collections.createStack('Вечер');
      restart().showView(LibraryView(ViewKind.stack, stackId: stackId));
      expect(restart().view.stackId, stackId);
      saved[LibraryController.viewSetting] = 'stack:999999';
      expect(restart().view, LibraryView.songs);
    });

    test('nothing or nonsense saved means all songs', () {
      expect(restart().view, LibraryView.songs);
      saved[LibraryController.viewSetting] = 'sideways';
      expect(restart().view, LibraryView.songs);
    });
  });

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

  group('maximized cover', () {
    const openCover = ValueKey('open-cover');
    const viewer = ValueKey('cover-viewer');

    /// The screen with a song playing. The fake player reports its song
    /// only when the screen is built, so it starts before that.
    Future<_StartedPlayer> shellPlaying(WidgetTester tester, int id) async {
      final player = _StartedPlayer();
      await player.play(library.all.firstWhere((track) => track.id == id));
      await pumpShell(tester, player: player);
      return player;
    }

    TrackTile shownTile(WidgetTester tester) => tester.widget<TrackTile>(
      find.descendant(of: find.byKey(viewer), matching: find.byType(TrackTile)),
    );

    testWidgets('a click on the side panel cover opens it; Esc closes it', (
      tester,
    ) async {
      await shellPlaying(tester, ids[1]);
      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();
      expect(shownTile(tester).biggest, isTrue);
      expect(shownTile(tester).track.id, ids[1]);
      expect(shownTile(tester).size, 900 - 2 * 32, reason: 'fills the window');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(viewer), findsNothing);
    });

    testWidgets('a click anywhere closes it, on the cover too', (tester) async {
      await shellPlaying(tester, ids[1]);
      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(viewer), findsNothing);

      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TrackTile).last);
      await tester.pumpAndSettle();
      expect(find.byKey(viewer), findsNothing);
    });

    testWidgets('the bottom bar cover opens it too', (tester) async {
      await shellPlaying(tester, ids[1]);
      await tester.tap(find.byKey(const ValueKey('dock-bottom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();
      expect(shownTile(tester).track.id, ids[1]);
    });

    testWidgets('Esc closes the cover and leaves the search text', (
      tester,
    ) async {
      await shellPlaying(tester, ids[1]);
      library.searchText.text = 'Песня';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(viewer), findsNothing);
      expect(library.searchText.text, 'Песня');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(library.searchText.text, isEmpty);
    });

    testWidgets('Space still pauses behind the cover', (tester) async {
      final player = await shellPlaying(tester, ids[1]);
      await tester.tap(find.byKey(openCover));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(player.pauseToggles, 1);
      expect(find.byKey(viewer), findsOneWidget);
    });

    testWidgets('a row opens it from the right-click menu; its click plays', (
      tester,
    ) async {
      final player = _StartedPlayer();
      await pumpShell(tester, player: player);
      await tester.tap(
        find.byKey(ValueKey('song-${ids[3]}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-view-cover')));
      await tester.pumpAndSettle();
      expect(shownTile(tester).track.id, ids[3]);
      expect(player.played, isEmpty, reason: 'looking at it plays nothing');
    });

    testWidgets('a song without a cover has nothing to open', (tester) async {
      await shellPlaying(tester, ids[5]);
      await tester.tap(
        find.byKey(ValueKey('song-${ids[5]}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-view-cover')), findsNothing);
      expect(find.byKey(openCover), findsNothing);
    });
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

    await tester.tap(find.byType(TextField));
    await tester.pump();
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

  group('column headers', () {
    double leftOf(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dx;

    testWidgets('sit above the columns they name', (tester) async {
      await pumpShell(tester);
      final header = find.byKey(const ValueKey('list-header'));
      expect(header, findsOneWidget);
      final title = find.descendant(of: header, matching: find.text('Title'));
      final album = find.descendant(of: header, matching: find.text('Album'));
      final time = find.descendant(of: header, matching: find.text('Time'));

      expect(leftOf(tester, title), leftOf(tester, find.text('Песня 0')));
      expect(leftOf(tester, album), leftOf(tester, find.text('Альбом').first));
      expect(
        tester.getTopRight(time).dx,
        tester.getTopRight(find.text('3:20').first).dx,
      );
      expect(
        tester.getBottomLeft(header).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Песня 0')).dy),
      );
    });

    testWidgets('stay in place when the list scrolls', (tester) async {
      await pumpShell(tester, size: const Size(1400, 330));
      final header = find.byKey(const ValueKey('list-header'));
      final before = tester.getTopLeft(header);
      library.scroll.jumpTo(40);
      await tester.pump();
      expect(tester.getTopLeft(header), before);
    });

    testWidgets('are left out of an empty list', (tester) async {
      await pumpShell(tester);
      await tester.enterText(find.byType(TextField), 'нет такой песни');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('list-header')), findsNothing);
    });
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
