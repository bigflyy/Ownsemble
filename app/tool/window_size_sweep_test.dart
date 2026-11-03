// Finds the window size where the main window's layout breaks: pumps the real
// shell with the real fonts at many sizes and prints what failed where, and
// how much room the song list, its title column and the seek bar had left.
//
// Run from app/:
//   flutter test tool/window_size_sweep_test.dart

import 'dart:async';
import 'dart:io';

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
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:path/path.dart' as p;

/// A player showing a song without opening any audio.
class _ShownPlayer extends PlayerService {
  _ShownPlayer(AudioStorage storage)
    : super(muted: true, dataDir: '.', storage: storage);

  Track? _track;
  final _changes = StreamController<Track?>.broadcast();

  @override
  bool get isReady => true;
  @override
  Track? get current => _track;
  @override
  bool get currentLoaded => true;
  @override
  Stream<Track?> get currentStream => _changes.stream;
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Duration get position => const Duration(seconds: 42);
  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    _track = track;
    _changes.add(track);
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

  /// Pumps the shell once, then walks through [sizes], collecting errors.
  Future<void> sweep(
    WidgetTester tester, {
    required String name,
    required PlayerDock dock,
    required bool rail,
    required bool thumbnails,
    required bool song,
    required List<Size> sizes,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      for (var i = 0; i < 12; i++)
        NewTrack(
          sourceKey: '1_$i',
          artist: 'Исполнитель с длинным именем $i',
          title: 'Песня с очень длинным названием, которое не помещается $i',
          album: 'Альбом с длинным названием',
          durationSec: 180 + i * 17,
          addedAt: 1000 - i,
        ),
    ]);
    final collections = CollectionsController(store);
    final library = LibraryController(
      store.loadAll(),
      collections: collections,
    );
    final settings = ShellSettings.inMemory();
    settings.dockTo(dock);
    if (rail) settings.toggleRail();
    if (!thumbnails) settings.toggleThumbnails();
    final storage = AudioStorage(dataDir: '.', store: store);
    final player = _ShownPlayer(storage);
    if (song) await player.play(library.visible.first);
    final sync = SyncController(
      sources: [
        SourceInfo(
          id: 1,
          kind: TrackSource.vk,
          account: '1',
          name: 'VK',
          songCount: 12,
          goneCount: 0,
          lastSyncAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      runner: null,
      onLibraryChanged: (_) {},
    );

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    final shell = KeyedSubtree(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(OwnColors.dark),
        home: LibraryScreen(
          library: library,
          playback: PlaybackController(player: player, recordPlay: (_) {}),
          collections: collections,
          sync: sync,
          settings: settings,
        ),
      ),
    );

    final old = FlutterError.onError;
    final failures = <Size, Set<String>>{};
    var at = Size.zero;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString().split('\n').first;
      // The widget that overflowed is named in the error's own text.
      final where = details
          .toString()
          .split('\n')
          .where((line) => line.contains('.dart:') && line.contains('lib'))
          .take(1)
          .join()
          .trim();
      (failures[at] ??= {}).add('$text  <- $where');
    };
    double? widthOf(String key) {
      final found = find.byKey(ValueKey(key));
      if (found.evaluate().isEmpty) return null;
      return tester.getSize(found.first).width;
    }

    double? bottomOf(String key) {
      final found = find.byKey(ValueKey(key));
      if (found.evaluate().isEmpty) return null;
      return tester.getBottomLeft(found.first).dy;
    }

    final lines = <String>[];
    for (final size in sizes) {
      at = size;
      // A RenderFlex reports an overflow only once, so every size gets new
      // render objects; otherwise a smaller size can read as clean.
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = size;
      await tester.pumpWidget(shell);
      await tester.pump();
      final list = library.scroll.hasClients
          ? library.scroll.position.viewportDimension
          : -1;
      lines.add(
        '${size.width.toInt()}x${size.height.toInt()}'
        ' list=${list.toStringAsFixed(0)}'
        ' seek=${widthOf('seek')?.toStringAsFixed(0)}'
        ' header=${widthOf('list-header')?.toStringAsFixed(0)}'
        ' volumeBottom=${bottomOf('volume')?.toStringAsFixed(0)}'
        ' repeatBottom=${bottomOf('repeat')?.toStringAsFixed(0)}'
        ' dockBottom=${bottomOf('dock-bottom')?.toStringAsFixed(0)}'
        ' failures=${failures[size]?.length ?? 0}'
        '${(failures[size] ?? const {}).map((f) => '\n    $f').join()}',
      );
    }
    FlutterError.onError = old;
    // ignore: avoid_print
    print('=== $name\n${lines.join('\n')}');
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpWidget(const SizedBox());
  }

  const widths = <double>[
    1000,
    980,
    900,
    800,
    720,
    680,
    640,
    600,
    560,
    520,
    480,
    440,
    400,
    360,
    320,
  ];
  const heights = <double>[
    800,
    700,
    680,
    660,
    640,
    620,
    600,
    560,
    520,
    480,
    440,
    400,
    360,
    320,
    280,
    240,
  ];

  for (final (name, dock, rail, thumbnails, song) in const [
    ('bottom, full sidebar, song', PlayerDock.bottom, false, true, true),
    ('bottom, rail, song', PlayerDock.bottom, true, true, true),
    ('bottom, rail, no song', PlayerDock.bottom, true, true, false),
    ('bottom, rail, numbers, song', PlayerDock.bottom, true, false, true),
    ('side, full sidebar, song', PlayerDock.side, false, true, true),
  ]) {
    testWidgets(name, (tester) async {
      await sweep(
        tester,
        name: '$name, widths at height 700',
        dock: dock,
        rail: rail,
        thumbnails: thumbnails,
        song: song,
        sizes: [for (final w in widths) Size(w, 700)],
      );
      await sweep(
        tester,
        name: '$name, heights at width 1400',
        dock: dock,
        rail: rail,
        thumbnails: thumbnails,
        song: song,
        sizes: [for (final h in heights) Size(1400, h)],
      );
      await sweep(
        tester,
        name: '$name, heights at width 640',
        dock: dock,
        rail: rail,
        thumbnails: thumbnails,
        song: song,
        sizes: [for (final h in heights) Size(640, h)],
      );
    });
  }
}
