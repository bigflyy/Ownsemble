import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/theme.dart';

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
  }) async {
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
            playback: PlaybackController(
              player: PlayerService(vk: null, muted: true, dataDir: '.'),
              recordPlay: collections.recordPlay,
            ),
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
}
