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
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/song_filters.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/source_editor.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/ui/stats_calendar.dart';
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
    // Filters (plan 04, C2): chips in use, the page period, a chip's menu
    // open, the Custom picker open (on its days with [pickerDays]).
    List<FilterRule> rules = const [],
    PlayPeriod? period,
    SongSort? sort,
    FilterField? openRule,
    bool picker = false,
    bool pickerDays = false,
    String? statsTab,
    // Calendar tab (plan 04, D2): pick the days from 6 to 2 days ago
    // (click, then Shift+click).
    bool calendarRange = false,
    // Scrolls the Stats page down this far before the shot.
    double statsScroll = 0,
    CalendarListening calendar = CalendarListening.line,
    bool saveView = false,
    // The first song gets three artists and a short title (the bottom bar
    // cuts the artist line at the title's width, user 2026-11-08).
    bool longNames = false,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(
      TrackSource.vk,
      account: '1',
      name: twoAccounts ? 'Мой VK' : 'VK',
    );
    final songs = [
      if (longNames)
        (
          'Сергей Канунников, Никита Алёшин, Илья Кудряшов',
          'Полыхала степь',
          'Зодчий',
        )
      else
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
      // As if VK gave both accounts the same file (Stage L).
      store.savePrints({
        for (final row in store.printsToRead())
          row.trackId: const FilePrint(bytes: 1, sample: 1, seconds: 200),
      });
      store.mergeSameSongs();
    }
    store.saveAudioFile(ids[1], 'cache/a.mp3', 10, pinned: true);
    store.saveAudioFile(ids[3], 'cache/b.mp3', 10);
    store.markGone(vk, ['1_6']);
    // Favorites (plan 05): the playing song and one more show filled hearts.
    store.addFavorite(ids[0], atMs: 1);
    store.addFavorite(ids[4], atMs: 2);
    final collections = CollectionsController(store);
    final stack = collections.createStack('Вечер у моря');
    collections.addToStack(stack, store.loadAll().first);
    collections.createStack('Run');
    // The album's VK list, made up: "Выхода нет" (VK track 502) and three
    // songs the library lacks. Nothing leaves the test.
    final albumList = Completer<Object?>();
    if (albumListed ?? false) {
      // "Новые люди" is also in the library, added from a single: its row
      // in the album names the album (user, 2026-11-08).
      store.upsertAll(vk, [
        const NewTrack(
          sourceKey: '1_50',
          artist: 'Сплин',
          title: 'Новые люди',
          album: 'Новые люди (сингл)',
          durationSec: 247,
          addedAt: 500,
          vkTrackId: 550,
        ),
      ]);
      albumList.complete(
        jsonDecode(
          jsonEncode({
            'count': 4,
            'items': [
              for (final (i, (title, seconds, track)) in [
                ('Гранатовый альбом', 225, 0),
                ('Выхода нет', 214, 502),
                ('Новые люди', 247, 550),
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
    // Made-up plays over the last two years, more for the first songs, so
    // the play columns and the picker's months have numbers.
    final today = DateTime.now();
    final noon = DateTime(today.year, today.month, today.day, 14);
    final plays = <(int, int, int, String)>[];
    for (var d = 0; d < 730; d += 3) {
      for (final (i, id) in ids.indexed) {
        if ((d * 7 + i * 13) % (i + 3) != 0) continue;
        final at = DateTime(noon.year, noon.month, noon.day - d, 9 + i);
        plays.add((id, at.millisecondsSinceEpoch, 170000, 'finished'));
      }
    }
    store.addPlays(plays);
    final settingsStore = <String, String?>{};
    final filters = SongFilters(
      store,
      readSetting: (key) => settingsStore[key],
      writeSetting: (key, value) => settingsStore[key] = value,
      clock: () => noon,
    );
    for (final rule in rules) {
      filters.setRule(rule);
    }
    if (period != null) filters.setPeriod(period);
    if (sort != null) filters.sortBy(sort);
    if (saveView) filters.saveView(filters.suggestedName());
    final library = LibraryController(
      store.loadAll(),
      filters: filters,
      collections: collections,
      albums: LibraryAlbums(
        store: store,
        apiOfSource: (_) =>
            (method, params) => albumList.future,
      ),
    );
    // The accounts dialog reads each account's last sync from the store.
    // A fixed time of day, so the shots do not change from run to run.
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
    settings.setCalendarListening(calendar);
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
              playback: PlaybackController(player: player),
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
    if (openRule != null) {
      await tester.tap(find.byKey(ValueKey('chip-${openRule.name}')));
      await tester.pumpAndSettle();
    }
    if (picker) {
      await tester.tap(find.byKey(const ValueKey('period-custom')));
      await tester.pumpAndSettle();
      // A range of whole months opens on months, any other on its days.
      if (pickerDays && find.text('Exact days').evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('picker-exact')));
        await tester.pumpAndSettle();
      }
    }
    if (statsTab != null) {
      await tester.tap(find.byKey(ValueKey('stats-tab-$statsTab')));
      await tester.pumpAndSettle();
    }
    if (calendarRange) {
      final today = DateTime.now();
      Finder day(int ago) => find.byKey(
        ValueKey(
          'cal-day-${isoDay(DateTime(today.year, today.month, today.day - ago))}',
        ),
      );
      await tester.tap(day(6));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(day(2));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }
    if (statsScroll > 0) {
      await tester.drag(
        find.byKey(const ValueKey('stats-page')),
        Offset(0, -statsScroll),
      );
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
    'light, bottom bar, long artist names',
    (t) => shoot(
      t,
      'light-long-names',
      dark: false,
      saving: true,
      longNames: true,
      dock: PlayerDock.bottom,
      pixelRatio: 2,
    ),
  );
  testWidgets(
    'dark, bottom bar, long artist names, narrow',
    (t) => shoot(
      t,
      'dark-long-names-narrow',
      dark: true,
      saving: true,
      longNames: true,
      dock: PlayerDock.bottom,
      size: const Size(700, 640),
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
    'dark, filters in use',
    (t) => shoot(
      t,
      'dark-filters',
      dark: true,
      rules: [
        const FilterRule(FilterField.artist, values: {'Кино', 'Сплин', 'ДДТ'}),
        const FilterRule(FilterField.plays, values: {'1'}),
        FilterRule(
          FilterField.lastPlayed,
          values: const {'month+'},
          negate: true,
        ),
      ],
      period: const PlayPeriod.year(),
      sort: SongSort.plays,
    ),
  );
  testWidgets(
    'light, a saved view, Plays with own dates',
    (t) => shoot(
      t,
      'light-filters-view',
      dark: false,
      rules: [
        FilterRule(
          FilterField.plays,
          values: const {'5'},
          period: PlayPeriod.year(offset: -1).fixedAt(DateTime.now()),
        ),
        const FilterRule(FilterField.offline, values: {'yes'}),
      ],
      saveView: true,
    ),
  );
  testWidgets(
    'dark, Artist menu',
    (t) => shoot(
      t,
      'dark-artist-menu',
      dark: true,
      rules: [
        const FilterRule(FilterField.artist, values: {'Кино', 'Сплин'}),
      ],
      openRule: FilterField.artist,
    ),
  );
  testWidgets(
    'dark, Plays menu',
    (t) => shoot(t, 'dark-plays-menu', dark: true, openRule: FilterField.plays),
  );
  testWidgets(
    'dark, Custom months',
    (t) => shoot(t, 'dark-picker-months', dark: true, picker: true),
  );
  testWidgets(
    'light, Custom months, color',
    (t) => shoot(
      t,
      'light-picker-months-color',
      dark: false,
      picker: true,
      calendar: CalendarListening.color,
      period: PlayPeriod.custom(
        DayRange(
          DateTime(DateTime.now().year, 1),
          DateTime(DateTime.now().year, 3, 31),
        ),
      ),
    ),
  );
  testWidgets(
    'dark, Custom days',
    (t) => shoot(
      t,
      'dark-picker-days',
      dark: true,
      picker: true,
      pickerDays: true,
      period: PlayPeriod.custom(
        DayRange(
          DateTime.now().subtract(const Duration(days: 12)),
          DateTime.now().subtract(const Duration(days: 3)),
        ),
      ),
    ),
  );
  testWidgets(
    'dark, Custom days, color',
    (t) => shoot(
      t,
      'dark-picker-days-color',
      dark: true,
      picker: true,
      pickerDays: true,
      calendar: CalendarListening.color,
      period: PlayPeriod.custom(
        DayRange(
          DateTime.now().subtract(const Duration(days: 12)),
          DateTime.now().subtract(const Duration(days: 3)),
        ),
      ),
    ),
  );
  testWidgets(
    'dark, narrow, filters',
    (t) => shoot(
      t,
      'dark-narrow-filters',
      dark: true,
      size: const Size(900, 760),
      rules: [
        const FilterRule(FilterField.plays, values: {'1'}),
      ],
    ),
  );
  testWidgets(
    'light, narrow',
    (t) => shoot(t, 'light-narrow', dark: false, size: const Size(900, 760)),
  );
  testWidgets(
    'dark, Favorites',
    (t) => shoot(
      t,
      'dark-favorites',
      dark: true,
      view: const LibraryView(ViewKind.favorites),
    ),
  );
  testWidgets(
    'light, Favorites, bottom bar, narrow',
    (t) => shoot(
      t,
      'light-favorites-narrow',
      dark: false,
      size: const Size(900, 760),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.favorites),
    ),
  );
  testWidgets(
    'dark, Stats',
    (t) => shoot(
      t,
      'dark-stats',
      dark: true,
      view: const LibraryView(ViewKind.stats),
    ),
  );
  testWidgets(
    'light, Stats, artists, year',
    (t) => shoot(
      t,
      'light-stats-artists',
      dark: false,
      view: const LibraryView(ViewKind.stats),
      period: const PlayPeriod.year(),
      statsTab: 'artists',
    ),
  );
  testWidgets(
    'dark, Stats, narrow, albums',
    (t) => shoot(
      t,
      'dark-stats-narrow',
      dark: true,
      size: const Size(900, 760),
      view: const LibraryView(ViewKind.stats),
      statsTab: 'albums',
    ),
  );
  testWidgets(
    'dark, Stats, Calendar',
    (t) => shoot(
      t,
      'dark-stats-calendar',
      dark: true,
      size: const Size(1440, 1300),
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
    ),
  );
  testWidgets(
    'light, Stats, Calendar, a range, long names',
    (t) => shoot(
      t,
      'light-stats-calendar-range',
      dark: false,
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      longNames: true,
    ),
  );
  testWidgets(
    'dark, Stats, Calendar, narrow',
    (t) => shoot(
      t,
      'dark-stats-calendar-narrow',
      dark: true,
      size: const Size(900, 760),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      statsScroll: 700,
    ),
  );
  testWidgets(
    'light, Stats, Calendar, narrow, When you listen',
    (t) => shoot(
      t,
      'light-stats-calendar-narrow-hours',
      dark: false,
      size: const Size(900, 760),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      statsScroll: 1400,
    ),
  );
  testWidgets(
    'light, Stats, Calendar, the first year',
    (t) => shoot(
      t,
      'light-stats-calendar-first-year',
      dark: false,
      size: const Size(1440, 1300),
      view: const LibraryView(ViewKind.stats),
      period: const PlayPeriod.year(offset: -2),
      statsTab: 'calendar',
    ),
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
