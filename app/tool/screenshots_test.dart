// Renders the main window with made-up songs to PNG files, with the real
// fonts, so the look can be checked without opening the app on screen.
//
// Run from app/ (writes into the folder given, default build/screenshots):
//   flutter test tool/screenshots_test.dart \
//       --dart-define=OWNSEMBLE_SHOTS=<folder>

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:path/path.dart' as p;

const shotsDir = String.fromEnvironment(
  'OWNSEMBLE_SHOTS',
  defaultValue: 'build/screenshots',
);

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File(file).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    await loadFont('Golos Text', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
        'assets/fonts/GolosText-$w.ttf',
    ]);
    // The test runs flutter_tester from bin/cache/artifacts/engine/<os>.
    final icons = p.normalize(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        '..',
        '..',
        'material_fonts',
        'materialicons-regular.otf',
      ),
    );
    if (File(icons).existsSync()) await loadFont('MaterialIcons', [icons]);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required bool dark,
    Size size = const Size(1440, 900),
    bool rail = false,
    PlayerDock dock = PlayerDock.side,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    const songs = [
      ('Кино', 'Группа крови', 'Группа крови'),
      ('Земфира', 'Хочешь?', 'Прости меня моя любовь'),
      ('Сплин', 'Выхода нет', 'Гранатовый альбом'),
      ('Metallica', 'Nothing Else Matters', 'Metallica'),
      ('Мумий Тролль', 'Владивосток 2000', 'Морская'),
      ('Radiohead', 'Weird Fishes/Arpeggi', 'In Rainbows'),
      ('Би-2', 'Полковнику никто не пишет', 'Би-2'),
      ('Daft Punk', 'Digital Love', 'Discovery'),
      ('Аквариум', 'Город золотой', 'Десять стрел'),
      ('Portishead', 'Glory Box', 'Dummy'),
      ('ДДТ', 'Что такое осень', 'Актриса Весна'),
      ('Massive Attack', 'Teardrop', 'Mezzanine'),
    ];
    final ids = store.upsertAll(vk, [
      for (final (i, (artist, title, album)) in songs.indexed)
        NewTrack(
          sourceKey: '1_$i',
          artist: artist,
          title: title,
          album: album,
          durationSec: 180 + i * 17,
          addedAt: 1000 - i,
        ),
    ]);
    store.saveAudioFile(ids[1], 'cache/a.mp3', 10, pinned: true);
    store.saveAudioFile(ids[3], 'cache/b.mp3', 10);
    store.markGone(vk, ['1_6']);
    final collections = CollectionsController(store);
    final stack = collections.createStack('Вечер у моря');
    collections.addToStack(stack, store.loadAll().first);
    collections.createStack('Run');
    final library = LibraryController(
      store.loadAll(),
      collections: collections,
    );
    final settings = ShellSettings.inMemory();
    if (!dark) settings.toggleTheme();
    if (rail) settings.toggleRail();
    settings.dockTo(dock);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? OwnColors.dark : OwnColors.light),
          home: LibraryScreen(
            library: library,
            playback: PlaybackController(
              player: PlayerService(vk: null, muted: true, dataDir: '.'),
              recordPlay: (_) {},
            ),
            collections: collections,
            settings: settings,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File(p.join(shotsDir, '$name.png'))
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('dark, side panel', (t) => shoot(t, 'dark-side', dark: true));
  testWidgets('light, side panel', (t) => shoot(t, 'light-side', dark: false));
  testWidgets(
    'dark, bottom bar, rail',
    (t) => shoot(
      t,
      'dark-bottom-rail',
      dark: true,
      rail: true,
      dock: PlayerDock.bottom,
    ),
  );
  testWidgets(
    'light, narrow',
    (t) => shoot(t, 'light-narrow', dark: false, size: const Size(900, 760)),
  );
}
