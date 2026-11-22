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

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/day_range.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_period.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/similar_seeds.dart';
import 'package:ownsemble/library/song_filter.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/playlists.dart';
import 'package:ownsemble/ui/song_filters.dart';
import 'package:ownsemble/ui/song_remover.dart';
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
  final _tracks = StreamController<Track?>.broadcast();

  @override
  Stream<Track?> get currentStream => _tracks.stream;

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
    _tracks.add(track);
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
    // Opens the Calendar panel's Every play tab (a range opens on Top songs).
    bool calendarPlays = false,
    // Scrolls the Stats page down this far before the shot.
    double statsScroll = 0,
    // Opens the report of this many years before this one (0: this year),
    // with a month's facts open when [reportMonth] is given.
    int? reportYearsAgo,
    int? reportMonth,
    CalendarListening calendar = CalendarListening.line,
    bool saveView = false,
    // The first song gets three artists and a short title (the bottom bar
    // cuts the artist line at the title's width, user 2026-11-08).
    bool longNames = false,
    // The first song gets a long title (the side panel's buttons squeezed
    // one to three lines, user 2026-11-17).
    bool longTitle = false,
    // The first song (the most played) plays, so its rows show the moving
    // playing mark (Stats lists, the Calendar panel, the year report).
    bool playingFirst = false,
    // Search place A (plan 06, C3): these words in the search box, the On VK
    // part filled from a made-up VK answer; [catalogPlays] plays the third
    // found song, [catalogAdd] clicks the + of the second, [catalogFolded]
    // folds the part, [catalogAll] ticks every account, [catalogMenu] opens
    // the account list.
    String? catalogQuery,
    bool catalogPlays = false,
    bool catalogAdd = false,
    bool catalogFolded = false,
    // Folds your own songs in search to their header (C4d).
    bool catalogOwnFolded = false,
    bool catalogAll = false,
    bool catalogMenu = false,
    // An album's place (plan 06, C4): clicks "Add the other N".
    bool albumAddAll = false,
    // Remove from library (plan 06, C5) on "Выхода нет" (with two accounts
    // on "Группа крови", in both): 'menu' opens its menu, 'sliding' clicks
    // Remove and shoots mid-slide, 'note' after the list dropped it,
    // 'flash' just after Undo.
    String? removeStep,
    // The For you place (plan 07) from VK's recorded replies
    // (test/fixtures/vk_recommendations): 'page', 'list' (For you opened,
    // its second song playing), 'mix' (VK Mix playing), 'loading' (the very
    // first open), 'banner' (VK not answering, the lists from before),
    // 'own' (scrolled to the own Similar to shelves, plan 07 Stage E, a
    // song of the last one playing).
    String? forYouStep,
    // The Playlists place (plan 08) from a made-up VK: 'page' (made and
    // followed playlists, a long title), 'list' (a made playlist opened,
    // its second song playing, a song VK gives no file for), 'empty' (no
    // playlists on VK). Editing (Stage C), in the made playlist with its
    // second song playing: 'drag' (the fourth row dragged up, mid-drag),
    // 'rowMenu' (a row's menu), 'addMenu' (its Add to playlist... menu,
    // "already in" greyed), 'undo' (a row taken out, the Undo bar);
    // in the playlist with the long title: 'heading' (its menu), 'name'
    // (Rename's dialog).
    String? playlistsStep,
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
      else if (longTitle)
        (
          'Би-2, Brainstorm',
          'Полковнику никто не пишет (Live at Олимпийский, remastered 2021)',
          'Нечетный воин',
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
    // The library has the first song of the recorded For you list (another
    // upload, same name and length): its row there is the library's.
    if (forYouStep != null) {
      store.upsertAll(vk, [
        const NewTrack(
          sourceKey: '1_60',
          artist: 'Кино',
          title: 'Закрой за мной дверь',
          album: 'Ночь',
          durationSec: 205,
          addedAt: 400,
        ),
        // The own shelves' second song, so a shelf row shows the check
        // next to the + of the others (and the playing mark).
        if (forYouStep == 'own')
          const NewTrack(
            sourceKey: '1_61',
            artist: 'Земфира',
            title: 'Прогулка',
            durationSec: 255,
            addedAt: 401,
          ),
      ]);
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
    if (reportYearsAgo != null) {
      library.openYearReport(DateTime.now().year - reportYearsAgo);
    }
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
    final player =
        saving ||
            playingFirst ||
            catalogPlays ||
            forYouStep != null ||
            playlistsStep != null
        ? _ShownPlayer(storage)
        : PlayerService(muted: true, dataDir: '.');
    // A made-up VK: what the search finds and an add that always works.
    // Nothing leaves the test.
    CatalogSearch? catalog;
    if (catalogQuery != null ||
        albumListed != null ||
        forYouStep != null ||
        playlistsStep != null) {
      var newId = 700;
      Future<Object?> fakeVk(String method, Map<String, String> params) async {
        if (method == 'audio.add') {
          return {
            'items_count': 1,
            'errors_count': 0,
            'items': [
              {'new_audio_id': newId++, 'new_owner_id': 1},
            ],
            'errors': <Object>[],
          };
        }
        final found = [
          // The library's own "Группа крови", another upload: a check.
          ('Кино', 'Группа крови', 'Группа крови', 180),
          ('Кино', 'Кукушка', 'Последний герой', 401),
          // The library's "Группа крови" as another recording (a live
          // cut): the hint "you have another version" and + (C4e).
          ('Кино', 'Группа крови', 'Концерт в Лужниках', 412),
          ('Кино', 'Звезда по имени Солнце', 'Звезда по имени Солнце', 225),
          ('Кино', 'Пачка сигарет', 'Звезда по имени Солнце', 268),
          ('Кино', 'Восьмиклассница', '45', 187),
          ('Кино', 'Перемен', 'Последний герой', 295),
          ('Кино', 'Спокойная ночь', 'Группа крови', 368),
          ('Кино', 'Последний герой', 'Последний герой', 213),
          ('Кино', 'Хочу перемен (Live)', 'Концерт в Лужниках', 312),
          ('Кино', 'Красно-жёлтые дни', 'Чёрный альбом', 334),
          ('Кино', 'Мама, мы все сошли с ума', 'Группа крови', 254),
          ('Кино', 'Музыка волн', 'Чёрный альбом', 349),
        ];
        return jsonDecode(
          jsonEncode({
            'count': 268,
            'items': [
              for (final (i, (artist, title, album, seconds)) in found.indexed)
                {
                  'owner_id': -77,
                  'id': 10 + i,
                  'artist': artist,
                  'title': title,
                  'duration': seconds,
                  'album': {'title': album},
                },
            ],
          }),
        );
      }

      catalog = CatalogSearch(
        library: library,
        store: store,
        sources: sources,
        apiOfSource: (id) => fakeVk,
        onLibraryChanged: ({required severalAccounts}) => library.replaceTracks(
          store.loadAll(),
          SearchIndex(store.loadAll()),
        ),
        pause: const Duration(milliseconds: 10),
      );
      if (catalogAll) catalog.toggleAll();
      if (catalogFolded) catalog.toggleFolded();
      if (catalogOwnFolded) catalog.toggleOwnFolded();
    }
    // VK's recorded recommendation replies. Nothing leaves the test.
    ForYou? forYou;
    var vkDown = false;
    if (forYouStep != null) {
      Object? recorded(String name) => jsonDecode(
        File('test/fixtures/vk_recommendations/$name.json').readAsStringSync(),
      );
      final never = Completer<Object?>();
      Future<Object?> recsVk(String method, Map<String, String> params) async {
        if (vkDown) throw VkException('$method error 10', transient: true);
        switch (method) {
          case 'catalog.getAudio':
            if (forYouStep == 'loading') return never.future;
            return recorded('catalog_get_audio');
          case 'audio.get':
            final reply = recorded(
              'audio_get_generated_playlist',
            ) as Map<String, dynamic>;
            return <String, dynamic>{
              ...reply,
              'items': [
                ...(reply['items'] as List),
                for (final (id, code) in [(70, 2), (71, 3)])
                  {
                    'owner_id': -7,
                    'id': id,
                    'artist': 'Земфира',
                    'title': code == 2
                        ? 'Не в этом регионе'
                        : 'Только по подписке',
                    'duration': 200,
                    'url': '',
                    'content_restricted': code,
                  },
              ],
            };
          case 'audio.getStreamMixAudios':
            return recorded('audio_get_stream_mix_audios');
          default:
            return recorded('audio_get_recommendations_target_found');
        }
      }

      final found = catalog!;
      forYou = ForYou(
        accounts: () => found.accounts,
        apiOfSource: (_) => recsVk,
        libraryCopyOfSong: found.libraryCopyOfSong,
        // Most heard "Выхода нет", next "Хочешь?" by another artist, and
        // the favorite "Владивосток 2000" not heard in a while.
        seedsOf: forYouStep != 'own'
            ? null
            : ({required skipTitles}) {
                final all = {for (final t in store.loadAll()) t.id: t};
                return [
                  (kind: SimilarSeedKind.mostHeard, track: all[ids[2]]!),
                  (kind: SimilarSeedKind.alsoHeard, track: all[ids[1]]!),
                  (kind: SimilarSeedKind.rediscover, track: all[ids[4]]!),
                ];
              },
      );
      library.vkLists = forYou;
      if (forYouStep != 'loading') await forYou.refresh();
      if (forYouStep == 'own') await forYou.refreshOwnShelves();
      if (forYouStep == 'banner') {
        vkDown = true;
        await forYou.refresh();
      }
    }
    // A made-up VK with the account's playlists. Nothing leaves the test.
    VkPlaylists? playlists;
    if (playlistsStep != null) {
      Map<String, dynamic> list(
        int id,
        String title, {
        required int count,
        String type = 'ugc',
        bool followed = false,
      }) => {
        'id': id,
        'owner_id': 1,
        'title': title,
        'count': count,
        'update_time': 100,
        'type': type,
        if (followed || type == 'album')
          'original': {'owner_id': -5, 'playlist_id': id},
      };
      // The library's songs by their index (same name and length), and
      // songs the library lacks.
      Map<String, dynamic> own(int i) => {
        'owner_id': -3,
        'id': 300 + i,
        'artist': songs[i].$1,
        'title': songs[i].$2,
        'duration': 180 + i * 17,
      };
      Map<String, dynamic> other(
        int id,
        String artist,
        String title, {
        int? restricted,
      }) => {
        'owner_id': -4,
        'id': id,
        'artist': artist,
        'title': title,
        'duration': 190 + id % 60,
        'url': restricted == null ? 'https://example.invalid/$id.mp3' : '',
        'content_restricted': ?restricted,
      };
      final lists = playlistsStep == 'empty'
          ? const <Map<String, dynamic>>[]
          : [
              list(1, 'В дорогу', count: 6),
              list(
                2,
                'Вечер у моря, когда никуда не надо спешить и можно слушать '
                'всё подряд',
                count: 4,
              ),
              list(3, 'Тренировка', count: 3),
              list(4, 'сладкая вата', count: 5, followed: true),
              list(5, 'Indie Mix', count: 2, followed: true),
              list(6, 'Альбом', count: 9, type: 'album'),
            ];
      final listSongs = {
        '1_1': [
          own(2),
          other(11, 'Кино', 'Звезда по имени Солнце'),
          own(4),
          other(12, 'Земфира', 'Искала'),
          other(13, 'Сплин', 'Орбит без сахара', restricted: 2),
          own(7),
        ],
        '1_2': [
          own(8),
          other(21, 'Portishead', 'Roads'),
          own(10),
          other(22, 'Massive Attack', 'Angel'),
        ],
        '1_3': [own(3), other(31, 'Rammstein', 'Sonne'), own(6)],
        '1_4': [
          other(41, 'мартин', 'моя любовь'),
          other(42, 'Монеточка', 'Каждый раз'),
          own(1),
          other(43, 'Пошлая Молли', 'Типичный рэп'),
          other(44, 'Хадн дадн', 'Шугейз'),
        ],
        '1_5': [other(51, 'Arctic Monkeys', 'Do I Wanna Know?'), own(5)],
        '1_6': [for (var i = 60; i < 69; i++) other(i, 'Би-2', 'Песня $i')],
      };
      Future<Object?> playlistsVk(
        String method,
        Map<String, String> params,
      ) async {
        if (method == 'audio.getPlaylists') {
          return {'count': lists.length, 'items': lists};
        }
        final songs =
            listSongs['${params['owner_id']}_${params['album_id']}'] ??
            const [];
        return {'count': songs.length, 'items': songs};
      }

      final found = catalog!;
      playlists = VkPlaylists(
        accounts: () => found.accounts,
        apiOfSource: (_) => playlistsVk,
        outside: OutsideSongs(libraryCopyOfSong: found.libraryCopyOfSong),
      );
      library.vkLists = playlists;
      await playlists.refresh();
    }
    // A made-up VK that removes and restores. Nothing leaves the test.
    SongRemover? remover;
    if (removeStep != null) {
      Future<Object?> removingVk(
        String method,
        Map<String, String> params,
      ) async {
        final key = '${params['owner_id']}_${params['audio_id']}';
        if (method == 'audio.delete') {
          return {
            'audio_ids': [key],
          };
        }
        return {
          'owner_id': int.parse(params['owner_id']!),
          'id': int.parse(params['audio_id']!),
          'artist': 'Сплин',
          'title': 'Выхода нет',
          'duration': 214,
          'date': 998,
        };
      }

      remover = SongRemover(
        store: store,
        sources: sources,
        apiOfSource: (id) => removingVk,
        onLibraryChanged: () {
          final tracks = store.loadAll();
          library.replaceTracks(tracks, SearchIndex(tracks));
        },
      );
    }
    if (playingFirst && !saving) {
      await player.play(library.all.firstWhere((t) => t.id == ids[0]));
    }
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
    final playback = PlaybackController(player: player);
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
              playback: playback,
              collections: collections,
              settings: settings,
              sync: sync,
              account: accounts,
              sources: editor,
              catalog: catalog,
              remover: remover,
              forYou: forYou,
              playlists: playlists,
              // The mic button shows in every bar, as in the app.
              lyrics: LyricsController(
                load: (source, ref) => null,
                save: (source, ref, lyrics, {md5, meta}) {},
                routeOf: lyricsRouteBySource((sourceId) => null),
              ),
            ),
          ),
        ),
      ),
    );
    if (forYouStep == 'loading') {
      await tester.pump();
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
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
      // November sits below the fold of a short window.
      await tester.ensureVisible(day(6));
      await tester.pumpAndSettle();
      await tester.tap(day(6));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(day(2));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }
    if (calendarPlays) {
      await tester.tap(find.byKey(const ValueKey('cal-view-plays')));
      await tester.pumpAndSettle();
    }
    if (reportMonth != null) {
      final bar = find.byKey(ValueKey('year-month-$reportMonth'));
      await tester.ensureVisible(bar);
      await tester.pumpAndSettle();
      await tester.tap(bar);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('year-report')),
        const Offset(0, 3000),
      );
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
    if (albumAddAll) {
      await tester.tap(find.byKey(const ValueKey('album-add-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }
    if (catalog != null && catalogQuery != null) {
      library.searchText.text = catalogQuery;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      if (catalogPlays) {
        await playback.playFrom([
          for (final found in catalog.songs) found.track,
        ], 2);
        player.playing.value = true;
        await tester.pump();
      }
      if (catalogAdd) {
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('found-${catalog.songs[1].track.id}')),
            matching: find.byKey(const ValueKey('add-song')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        // Halfway through the Songs count's violet.
        await tester.pump(const Duration(milliseconds: 400));
      }
      if (catalogMenu) {
        await tester.tap(find.byKey(const ValueKey('catalog-targets')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (playingFirst || catalogPlays) {
      // The bars move without end, so no pumpAndSettle after this.
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (forYou != null && forYouStep == 'list') {
      await tester.tap(find.byKey(const ValueKey('list-card-For you')));
      await tester.pumpAndSettle();
      await playback.playFrom(library.visible, 1);
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (forYou != null && forYouStep == 'own') {
      await tester.drag(
        find.byKey(const ValueKey('for-you-page')),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      final rows = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('shelf-row-'),
          )
          .hitTestable();
      await tester.tap(rows.at(rows.evaluate().length - 2));
      await tester.pump();
      await tester.pump();
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
    }
    const editSteps = {'drag', 'rowMenu', 'addMenu', 'undo'};
    if (playlists != null &&
        (playlistsStep == 'list' || editSteps.contains(playlistsStep))) {
      await tester.tap(find.byKey(const ValueKey('list-card-В дорогу')));
      await tester.pumpAndSettle();
      // A row click, so the player says where it plays from.
      await tester.tap(
        find.byKey(ValueKey('entry-${library.entryIdAt(1)}')),
        warnIfMissed: false,
      );
      await tester.pump();
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
    }
    // A song plays in these steps: its mark moves on, so nothing settles;
    // fixed pumps let menus and bars come in.
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    TestGesture? drag;
    if (playlists != null && playlistsStep == 'drag') {
      drag = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey('drag-entry-${library.entryIdAt(3)}')),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(0, -rowHeight * 1.6 / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (playlists != null &&
        (playlistsStep == 'rowMenu' ||
            playlistsStep == 'addMenu' ||
            playlistsStep == 'undo')) {
      // The first row: a library song that is in this playlist already.
      await tester.tap(
        find.byKey(ValueKey('entry-${library.entryIdAt(0)}')),
        buttons: kSecondaryMouseButton,
      );
      await settle();
      if (playlistsStep == 'addMenu') {
        await tester.tap(find.byKey(const ValueKey('menu-add-to-playlist')));
        await settle();
      }
      if (playlistsStep == 'undo') {
        await tester.tap(
          find.byKey(const ValueKey('menu-remove-from-playlist')),
        );
        await settle();
      }
    }
    if (playlists != null &&
        (playlistsStep == 'heading' || playlistsStep == 'name')) {
      await tester.tap(
        find.byKey(
          const ValueKey(
            'list-card-Вечер у моря, когда никуда не надо спешить и можно '
            'слушать всё подряд',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playlist-menu')));
      await tester.pumpAndSettle();
      if (playlistsStep == 'name') {
        await tester.tap(find.byKey(const ValueKey('playlist-rename')));
        await tester.pumpAndSettle();
      }
    }
    // The page with a playlist playing from its card (user, 2026-11-18:
    // "not very clear which playlist is playing now").
    if (playlists != null && playlistsStep == 'playing') {
      // The card's Play shows only while the card is pointed at.
      final cardPlay = find.byKey(
        const ValueKey(
          'list-play-Вечер у моря, когда никуда не надо спешить и можно '
          'слушать всё подряд',
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(cardPlay));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(cardPlay);
      await mouse.removePointer();
      await tester.pump();
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (forYou != null && (forYouStep?.startsWith('mix') ?? false)) {
      await tester.tap(find.byKey(const ValueKey('vk-mix-play')));
      await tester.pump();
      await tester.pump();
      player.playing.value = true;
      await tester.pump(const Duration(milliseconds: 300));
      // B25: the narrow bar's More menu with the song's buttons.
      if (forYouStep == 'mix-menu') {
        await tester.tap(find.byKey(const ValueKey('player-more')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
    }
    if (removeStep != null) {
      final target = ids[twoAccounts ? 0 : 2];
      await tester.tap(
        find.byKey(ValueKey('song-$target')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (removeStep != 'menu') {
        await tester.tap(
          find.byKey(const ValueKey('menu-remove-from-library')),
        );
        await tester.pump();
        // Halfway through the slide.
        await tester.pump(const Duration(milliseconds: 120));
        if (removeStep != 'sliding') {
          await tester.pump(const Duration(milliseconds: 200));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          if (removeStep == 'flash') {
            await tester.tap(find.byKey(const ValueKey('note-undo')));
            await tester.pump();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 120));
          }
        }
      }
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
    // The drag is called off: nothing is sent.
    await drag?.cancel();
    if (drag != null) await settle();
    // Stops the playing timer of the controller before the tree goes.
    if (playingFirst ||
        catalogPlays ||
        forYouStep != null ||
        playlistsStep != null) {
      player.playing.value = false;
    }
    // Lets the note at the bottom time out, so no timer is left.
    final menuOpen =
        removeStep == 'menu' ||
        const {'rowMenu', 'addMenu', 'heading', 'name'}.contains(playlistsStep);
    if (catalogAdd ||
        albumAddAll ||
        removeStep != null ||
        menuOpen ||
        playlistsStep == 'undo') {
      if (menuOpen) {
        await tester.tapAt(const Offset(5, 5));
        await settle();
      }
      // The Undo bar goes Undo: nothing is sent to the made-up VK.
      if (playlistsStep == 'undo') {
        await tester.tap(find.byKey(const ValueKey('playlist-undo')));
      }
      await tester.pump(const Duration(seconds: 10));
    }
    catalog?.dispose();
    remover?.dispose();
    forYou?.dispose();
    playlists?.dispose();
  }

  for (final (step, dark, size) in [
    ('page', false, const Size(1440, 900)),
    ('page', true, const Size(1440, 900)),
    ('page', false, const Size(760, 900)),
    ('list', true, const Size(1440, 900)),
    ('list', false, const Size(760, 900)),
    ('empty', false, const Size(1440, 900)),
    ('playing', true, const Size(1440, 900)),
    ('playing', false, const Size(1440, 900)),
    ('playing', false, const Size(760, 900)),
    ('drag', false, const Size(1440, 900)),
    ('drag', true, const Size(760, 900)),
    ('rowMenu', true, const Size(1440, 900)),
    ('addMenu', false, const Size(1440, 900)),
    ('addMenu', true, const Size(760, 900)),
    ('undo', false, const Size(1440, 900)),
    ('undo', true, const Size(760, 900)),
    ('heading', false, const Size(1440, 900)),
    ('heading', true, const Size(760, 900)),
    ('name', true, const Size(1440, 900)),
  ]) {
    final width = size.width < 1000 ? 'narrow' : 'wide';
    testWidgets(
      'Playlists: $step, ${dark ? 'dark' : 'light'}, $width',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-playlists-$step-$width',
        dark: dark,
        size: size,
        dock: size.width < 1000 ? PlayerDock.bottom : PlayerDock.side,
        view: const LibraryView(ViewKind.playlists),
        playlistsStep: step,
      ),
    );
  }

  for (final (step, dark, size) in [
    ('page', false, const Size(1440, 900)),
    ('page', true, const Size(1440, 900)),
    ('page', false, const Size(760, 900)),
    ('list', true, const Size(1440, 900)),
    ('list', false, const Size(760, 900)),
    ('mix', false, const Size(1440, 900)),
    ('mix', true, const Size(760, 900)),
    ('loading', false, const Size(1440, 900)),
    ('banner', true, const Size(1440, 900)),
    ('own', false, const Size(1440, 900)),
    ('own', true, const Size(1440, 900)),
    ('own', false, const Size(760, 900)),
  ]) {
    final width = size.width < 1000 ? 'narrow' : 'wide';
    testWidgets(
      'For you: $step, ${dark ? 'dark' : 'light'}, $width',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-for-you-$step-$width',
        dark: dark,
        size: size,
        dock: size.width < 1000 ? PlayerDock.bottom : PlayerDock.side,
        view: const LibraryView(ViewKind.forYou),
        forYouStep: step,
      ),
    );
  }

  // The narrow window with the side panel, where a long note once pushed
  // Show all off the row.
  testWidgets(
    'For you: own, dark, narrow, side panel',
    (t) => shoot(
      t,
      'dark-for-you-own-narrow-side',
      dark: true,
      size: const Size(760, 900),
      view: const LibraryView(ViewKind.forYou),
      forYouStep: 'own',
    ),
  );

  for (final (step, dark) in [
    ('menu', true),
    ('sliding', false),
    ('note', true),
    ('flash', false),
  ]) {
    testWidgets(
      'Remove from library: $step',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-remove-$step',
        dark: dark,
        playingFirst: true,
        removeStep: step,
      ),
    );
  }
  testWidgets(
    'dark, Remove from library of a song in two accounts',
    (t) => shoot(
      t,
      'dark-remove-menu-two',
      dark: true,
      twoAccounts: true,
      playingFirst: true,
      removeStep: 'menu',
    ),
  );
  testWidgets(
    'light, narrow, the note after Remove from library',
    (t) => shoot(
      t,
      'light-remove-note-narrow',
      dark: false,
      size: const Size(640, 900),
      dock: PlayerDock.bottom,
      playingFirst: true,
      removeStep: 'note',
    ),
  );
  testWidgets(
    'dark, search with the On VK part, a found song playing',
    (t) => shoot(
      t,
      'dark-catalog',
      dark: true,
      catalogQuery: 'кино',
      catalogPlays: true,
    ),
  );
  testWidgets(
    'light, search with the On VK part, after +',
    (t) => shoot(
      t,
      'light-catalog-added',
      dark: false,
      dock: PlayerDock.bottom,
      catalogQuery: 'кино',
      catalogPlays: true,
      catalogAdd: true,
    ),
  );
  testWidgets(
    'light, search with the On VK part, narrow',
    (t) => shoot(
      t,
      'light-catalog-narrow',
      dark: false,
      size: const Size(700, 820),
      dock: PlayerDock.bottom,
      catalogQuery: 'кино',
      catalogPlays: true,
    ),
  );
  testWidgets(
    'dark, search with the On VK part, two accounts, both ticked',
    (t) => shoot(
      t,
      'dark-catalog-two',
      dark: true,
      twoAccounts: true,
      catalogQuery: 'кино',
      catalogAll: true,
      catalogMenu: true,
    ),
  );
  testWidgets(
    'dark, search with the On VK part, two accounts, after +',
    (t) => shoot(
      t,
      'dark-catalog-two-added',
      dark: true,
      twoAccounts: true,
      dock: PlayerDock.bottom,
      catalogQuery: 'кино',
      catalogAll: true,
      catalogAdd: true,
    ),
  );
  testWidgets(
    'light, the On VK part folded, no own song matches',
    (t) => shoot(
      t,
      'light-catalog-folded',
      dark: false,
      catalogQuery: 'кукушка',
      catalogFolded: true,
    ),
  );

  testWidgets(
    'dark, your own songs in search folded, a found song playing',
    (t) => shoot(
      t,
      'dark-catalog-own-folded',
      dark: true,
      catalogQuery: 'кино',
      catalogPlays: true,
      catalogOwnFolded: true,
    ),
  );
  testWidgets(
    'light, your own songs in search folded, narrow',
    (t) => shoot(
      t,
      'light-catalog-own-folded-narrow',
      dark: false,
      size: const Size(700, 820),
      dock: PlayerDock.bottom,
      catalogQuery: 'кино',
      catalogPlays: true,
      catalogOwnFolded: true,
    ),
  );

  testWidgets('dark, side panel', (t) => shoot(t, 'dark-side', dark: true));
  testWidgets(
    'dark, an album loading',
    (t) => shoot(t, 'dark-album-loading', dark: true, albumListed: false),
  );
  testWidgets(
    'light, an album from VK',
    (t) => shoot(t, 'light-album', dark: false, albumListed: true),
  );
  testWidgets(
    'dark, an album with + on the songs you lack, narrow',
    (t) => shoot(
      t,
      'dark-album-add-narrow',
      dark: true,
      size: const Size(700, 820),
      dock: PlayerDock.bottom,
      albumListed: true,
    ),
  );
  testWidgets(
    'light, an album after Add the other N',
    (t) => shoot(
      t,
      'light-album-added',
      dark: false,
      albumListed: true,
      albumAddAll: true,
    ),
  );
  testWidgets('light, side panel', (t) => shoot(t, 'light-side', dark: false));
  for (final (dark, size) in [
    (true, const Size(1440, 900)),
    (false, const Size(1440, 900)),
    (true, const Size(980, 660)),
    (false, const Size(980, 660)),
  ]) {
    final width = size.width < 1000 ? 'smallest' : 'wide';
    testWidgets(
      '${dark ? 'dark' : 'light'}, side panel, a long title, $width',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-long-title-$width',
        dark: dark,
        size: size,
        longTitle: true,
        playingFirst: true,
      ),
    );
  }
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
  // The narrow bar beside Up Next and the mic (B24: the title row
  // overflowed at the smallest window).
  for (final (name, size) in [
    ('smallest', const Size(480, 440)),
    ('640', const Size(640, 700)),
  ]) {
    testWidgets(
      'dark, bottom bar, long artist names, $name',
      (t) => shoot(
        t,
        'dark-long-names-$name',
        dark: true,
        saving: true,
        longNames: true,
        rail: true,
        dock: PlayerDock.bottom,
        size: size,
        pixelRatio: 2,
      ),
    );
  }
  for (final step in ['mix', 'mix-menu', 'loading']) {
    testWidgets(
      'For you: $step, dark, smallest window',
      (t) => shoot(
        t,
        'dark-for-you-$step-smallest',
        dark: true,
        size: const Size(480, 440),
        dock: PlayerDock.bottom,
        view: const LibraryView(ViewKind.forYou),
        forYouStep: step,
        pixelRatio: 2,
      ),
    );
  }
  for (final width in [640.0, 760.0]) {
    testWidgets(
      'For you: mix, light, ${width.round()} px',
      (t) => shoot(
        t,
        'light-for-you-mix-${width.round()}',
        dark: false,
        size: Size(width, 640),
        dock: PlayerDock.bottom,
        view: const LibraryView(ViewKind.forYou),
        forYouStep: 'mix',
        pixelRatio: 2,
      ),
    );
  }
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
      playingFirst: true,
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
      playingFirst: true,
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
      playingFirst: true,
      dark: false,
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      longNames: true,
    ),
  );
  testWidgets(
    'light, Stats, Calendar, a range, very wide window',
    (t) => shoot(
      t,
      'light-stats-calendar-wide',
      playingFirst: true,
      dark: false,
      size: const Size(2560, 1300),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      longNames: true,
    ),
  );
  testWidgets(
    'dark, Stats, Calendar, 1000 wide, bottom player',
    (t) => shoot(
      t,
      'dark-stats-calendar-1000',
      playingFirst: true,
      dark: true,
      size: const Size(1000, 900),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      statsScroll: 500,
    ),
  );
  testWidgets(
    'dark, Stats, Calendar, narrow',
    (t) => shoot(
      t,
      'dark-stats-calendar-narrow',
      playingFirst: true,
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
    'light, Stats, Calendar, narrow, a range on Every play, long names',
    (t) => shoot(
      t,
      'light-stats-calendar-narrow-plays',
      playingFirst: true,
      dark: false,
      size: const Size(900, 760),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      statsTab: 'calendar',
      calendarRange: true,
      calendarPlays: true,
      longNames: true,
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
    'dark, year report, last year, a month open',
    (t) => shoot(
      t,
      'dark-year-report',
      playingFirst: true,
      dark: true,
      size: const Size(1440, 2500),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      reportYearsAgo: 1,
      reportMonth: 3,
    ),
  );
  testWidgets(
    'light, year report, this year, narrow, long names',
    (t) => shoot(
      t,
      'light-year-report-narrow',
      playingFirst: true,
      dark: false,
      size: const Size(900, 3000),
      dock: PlayerDock.bottom,
      view: const LibraryView(ViewKind.stats),
      reportYearsAgo: 0,
      longNames: true,
    ),
  );
  testWidgets(
    'dark, year report, the first year, side panel',
    (t) => shoot(
      t,
      'dark-year-report-first',
      dark: true,
      size: const Size(1440, 1200),
      view: const LibraryView(ViewKind.stats),
      reportYearsAgo: 2,
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
