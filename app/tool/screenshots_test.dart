// Renders the main window with made-up songs to PNG files, with the real
// fonts, so the look can be checked without opening the app on screen.
//
// Run from app/ (writes into the folder given, default build/screenshots):
//   flutter test tool/screenshots_test.dart \
//       --dart-define=OWNSEMBLE_SHOTS=<folder>

import 'dart:async';
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
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:path/path.dart' as p;

const shotsDir = String.fromEnvironment(
  'OWNSEMBLE_SHOTS',
  defaultValue: 'build/screenshots',
);

/// A player showing a song without opening any audio.
class _ShownPlayer extends PlayerService {
  _ShownPlayer(AudioStorage storage)
    : super(muted: true, dataDir: '.', storage: storage);

  Track? _track;

  @override
  bool get isReady => true;
  @override
  Track? get current => _track;
  @override
  bool get currentLoaded => true;
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Duration get position => const Duration(seconds: 42);
  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    _track = track;
    return const PlayTiming(ok: true, cached: true, resolveMs: 0, toSoundMs: 1);
  }
}

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
    bool saving = false,
    double pixelRatio = 1,
    bool shortcutsList = false,
    String jump = '',
    LibraryView view = LibraryView.songs,
    bool twoAccounts = false,
    bool filtered = false,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(
      TrackSource.vk,
      account: '1',
      name: twoAccounts ? 'Мой VK' : 'VK',
    );
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
          vkTrackId: 500 + i,
        ),
    ]);
    // A second, made-up account: two songs of the first one merge into its
    // rows, two more are its own.
    final second = twoAccounts
        ? store.ensureSource(TrackSource.vk, account: '2', name: 'Рабочий')
        : null;
    if (second != null) {
      store.setSourceColor(second, 2);
      store.upsertAll(second, [
        for (final (i, (artist, title, album)) in songs.indexed)
          if (i == 0 || i == 4)
            NewTrack(
              sourceKey: '2_$i',
              artist: artist,
              title: title,
              album: album,
              durationSec: 180 + i * 17,
              addedAt: 2000 - i,
              vkTrackId: 500 + i,
            ),
        const NewTrack(
          sourceKey: '2_100',
          artist: 'Ленинград',
          title: 'Экспонат',
          durationSec: 201,
          addedAt: 900,
        ),
        const NewTrack(
          sourceKey: '2_101',
          artist: 'Placebo',
          title: 'Every You Every Me',
          durationSec: 213,
          addedAt: 899,
        ),
      ]);
      store.mergeSameSongs();
    }
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
    final sources = ValueNotifier(store.sources());
    if (twoAccounts) library.watchSources(sources);
    library.showView(view);
    if (filtered) library.showSource(second);
    final settings = ShellSettings.inMemory();
    if (!dark) settings.toggleTheme();
    if (rail) settings.toggleRail();
    settings.dockTo(dock);

    // A song playing while it is saved, and another one downloading.
    final storage = AudioStorage(dataDir: '.', store: store);
    final player = saving
        ? _ShownPlayer(storage)
        : PlayerService(muted: true, dataDir: '.');
    if (saving) {
      final tracks = library.visible;
      await player.play(tracks[0]);
      storage.noteSaving(tracks[0], Completer<int?>().future);
      storage.noteProgress(tracks[0], 55, 100);
      final never = Completer<Uri?>();
      unawaited(storage.download(tracks[2], () => never.future));
      storage.noteProgress(tracks[2], 30, 100);
    }

    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? OwnColors.dark : OwnColors.light),
          home: SourcesScope(
            sources: sources,
            child: LibraryScreen(
              library: library,
              playback: PlaybackController(player: player, recordPlay: (_) {}),
              collections: collections,
              settings: settings,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    jump.split('').forEach(library.jump.type);
    await tester.pump();
    if (shortcutsList) {
      await tester.tap(find.byKey(const ValueKey('keyboard-help')));
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: pixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File(p.join(shotsDir, '$name.png'))
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
    library.jump.clear();
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
    'dark, side panel, saving',
    (t) => shoot(t, 'dark-saving', dark: true, saving: true, pixelRatio: 2),
  );
  testWidgets(
    'light, bottom bar, saving',
    (t) => shoot(
      t,
      'light-saving',
      dark: false,
      saving: true,
      dock: PlayerDock.bottom,
      pixelRatio: 2,
    ),
  );
  testWidgets(
    'dark, shortcuts list',
    (t) => shoot(t, 'dark-shortcuts', dark: true, shortcutsList: true),
  );
  testWidgets(
    'dark, jump to a row',
    (t) => shoot(t, 'dark-jump', dark: true, jump: 'mas', pixelRatio: 2),
  );
  testWidgets(
    'light, jump to the playing row',
    (t) => shoot(
      t,
      'light-jump-current',
      dark: false,
      saving: true,
      jump: 'ки',
      pixelRatio: 2,
    ),
  );
  testWidgets(
    'dark, jump without a match',
    (t) => shoot(t, 'dark-jump-none', dark: true, jump: 'ъъ', pixelRatio: 2),
  );
  testWidgets(
    'dark, two accounts',
    (t) => shoot(t, 'dark-accounts', dark: true, twoAccounts: true),
  );
  testWidgets(
    'light, two accounts, filtered to the second',
    (t) => shoot(
      t,
      'light-accounts-filtered',
      dark: false,
      twoAccounts: true,
      filtered: true,
      pixelRatio: 2,
    ),
  );
  testWidgets(
    'dark, two accounts, smallest window',
    (t) => shoot(
      t,
      'dark-accounts-small',
      dark: true,
      twoAccounts: true,
      rail: true,
      dock: PlayerDock.bottom,
      size: const Size(480, 440),
      pixelRatio: 2,
    ),
  );
  testWidgets(
    'light, narrow',
    (t) => shoot(t, 'light-narrow', dark: false, size: const Size(900, 760)),
  );
  testWidgets(
    'dark, On this computer',
    (t) => shoot(
      t,
      'dark-stored',
      dark: true,
      view: const LibraryView(ViewKind.stored),
    ),
  );
  testWidgets(
    'light, On this computer, rail',
    (t) => shoot(
      t,
      'light-stored-rail',
      dark: false,
      rail: true,
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stored),
    ),
  );
}
