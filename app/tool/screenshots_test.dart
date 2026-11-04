// Renders the main window with made-up songs to PNG files, with the real
// fonts, so the look can be checked without opening the app on screen.
//
// Run from app/ (writes into the folder given, default build/screenshots):
//   flutter test tool/screenshots_test.dart \
//       --dart-define=OWNSEMBLE_SHOTS=<folder>

import 'dart:async';
import 'dart:convert';
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
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/source_editor.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/ui/vk_accounts.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_login_window.dart';
import 'package:ownsemble/vk/vk_session.dart';
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

/// A login window that never opens: the shots only show saved accounts.
class _NoWindow implements LoginWindow {
  @override
  set onClosed(void Function() listener) {}

  @override
  Future<void> open() async {}

  @override
  Future<List<SessionCookie>> cookies() async => const [];

  @override
  Future<void> close() async {}
}

/// Saved sessions kept in memory, with made-up cookies that never reach VK.
class _MemorySessions implements VkSessionVault {
  final _saved = <String, SavedSession>{};

  @override
  List<SavedSession> load() => _saved.values.toList();

  @override
  String save(String account, List<SessionCookie> cookies) {
    _saved[account] = SavedSession(account, account, cookies);
    return account;
  }

  @override
  String adopt(SavedSession session, String account) => session.id;

  @override
  void remove(String id) => _saved.remove(id);
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
    bool accountsDialog = false,
    bool secondLoggedOut = false,
    // Opens the album of "Выхода нет": null leaves it closed, false shows it
    // while VK's list is on its way, true with the list in.
    bool? albumListed,
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
          vkAlbumKey: i == 2 ? '-9_1' : null,
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
    // The album's VK list, made up: "Выхода нет" (VK track 502) and three
    // songs the library lacks. Nothing leaves the test.
    final albumList = Completer<Object?>();
    if (albumListed ?? false) {
      albumList.complete(
        jsonDecode(
          jsonEncode({
            'count': 4,
            'items': [
              for (final (i, (title, seconds, track)) in [
                ('Гранатовый альбом', 225, 0),
                ('Выхода нет', 214, 502),
                ('Новые люди', 247, 0),
                ('Иди через лес', 233, 0),
              ].indexed)
                {
                  'owner_id': -9,
                  'id': i + 1,
                  'artist': 'Сплин',
                  'title': title,
                  'duration': seconds,
                  if (track != 0) 'track_id': track,
                },
            ],
          }),
        ),
      );
    }
    final library = LibraryController(
      store.loadAll(),
      collections: collections,
      albums: LibraryAlbums(
        store: store,
        apiOfSource: (_) =>
            (method, params) => albumList.future,
      ),
    );
    // The accounts dialog reads each account's last sync from the store.
    // A fixed time of day, so the shots do not change from run to run.
    final today = DateTime.now();
    final syncedAt = DateTime(today.year, today.month, today.day, 9, 41);
    if (accountsDialog) {
      store.recordSync(vk, atMs: syncedAt.millisecondsSinceEpoch);
      store.recordSync(second!, atMs: syncedAt.millisecondsSinceEpoch);
    }
    final sources = ValueNotifier(store.sources());
    if (twoAccounts) library.watchSources(sources);
    library.showView(view);
    if (filtered) library.showSource(second);
    // The sync bar and the accounts dialog, with saved sessions only: no
    // runner, so nothing syncs and no request leaves the test.
    SyncController? sync;
    VkAccounts? accounts;
    SourceEditor? editor;
    if (accountsDialog) {
      final vault = _MemorySessions()
        ..save('1', const [SessionCookie('remixsid', 'a', '.vk.ru')]);
      if (!secondLoggedOut) {
        vault.save('2', const [SessionCookie('remixsid', 'b', '.vk.ru')]);
      }
      accounts = VkAccounts(
        vault: vault,
        window: _NoWindow(),
        clientFor: (cookies) => VkClient(cookies),
      );
      sync = SyncController(
        sources: store.sources(),
        runner: null,
        onLibraryChanged: (_) {},
      );
      editor = SourceEditor(
        store: store,
        sync: sync,
        library: library,
        dataDir: '.',
      );
    }
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
              sync: sync,
              account: accounts,
              sources: editor,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    jump.split('').forEach(library.jump.type);
    await tester.pump();
    if (accountsDialog) {
      await tester.tap(find.byKey(const ValueKey('vk-accounts')));
      await tester.pumpAndSettle();
    }
    if (shortcutsList) {
      await tester.tap(find.byKey(const ValueKey('keyboard-help')));
      await tester.pumpAndSettle();
    }
    if (albumListed != null) {
      await tester.tap(find.text('Гранатовый альбом'));
      await tester.pump();
      await tester.pump();
    }
    // Text without the app's font shows here as solid boxes and in the real
    // app in the system font; icons have their own font.
    for (final paragraph
        in tester.allRenderObjects.whereType<RenderParagraph>()) {
      final family = paragraph.text.style?.fontFamily;
      expect(
        family == appFontFamily || family == 'MaterialIcons',
        isTrue,
        reason: '"${paragraph.text.toPlainText()}" is drawn in $family',
      );
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
  testWidgets(
    'dark, an album loading',
    (t) => shoot(t, 'dark-album-loading', dark: true, albumListed: false),
  );
  testWidgets(
    'light, an album from VK',
    (t) => shoot(t, 'light-album', dark: false, albumListed: true),
  );
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
    'dark, accounts dialog',
    (t) => shoot(
      t,
      'dark-accounts-dialog',
      dark: true,
      twoAccounts: true,
      accountsDialog: true,
    ),
  );
  testWidgets(
    'light, accounts dialog, second account logged out',
    (t) => shoot(
      t,
      'light-accounts-logged-out',
      dark: false,
      twoAccounts: true,
      accountsDialog: true,
      secondLoggedOut: true,
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
