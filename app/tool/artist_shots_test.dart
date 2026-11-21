// Renders the artist places of plan 09 (Stage D) to PNG files with the
// real fonts, so their look can be checked without opening the app on
// screen: the Artists grid (sorts, search, narrow), an artist's page (VK
// loading, loaded with a song playing, VK not answering, a name-only
// artist, an artist known only by VK's link, a long name), its songs list
// and its Popular list, and the artist links in the Songs rows.
//
// Run from app/:
//   flutter test tool/artist_shots_test.dart \
//       --dart-define=OWNSEMBLE_SHOTS=<folder>

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/artists.dart';
import 'package:ownsemble/ui/card_play.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/song_filters.dart';
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

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File(file).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

Map<String, dynamic> _page() => jsonDecode(
  File('test/fixtures/vk_artists/catalog_get_audio_artist.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

const tank = ArtistCredit(vkId: '10000', name: 'Дайте танк (!)');
const rita = ArtistCredit(vkId: '20000', name: 'Рита Вихрия', featured: true);
const longName = ArtistCredit(
  vkId: '40000',
  name: 'Оркестр Государственного академического Большого театра России',
);

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

  /// [step]: 'grid', 'heard' (sorted by Most heard), 'search', 'page',
  /// 'loading', 'failed', 'nameOnly', 'domain' (an artist VK suggested),
  /// 'long' (a long name), 'songs' (Show all), 'popular' (Show more),
  /// 'links' (Songs with the mouse on a featured artist's name).
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required String step,
    required bool dark,
    Size size = const Size(1440, 900),
    bool rail = false,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    final songs = <NewTrack>[
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Дайте танк (!)',
        title: 'Утро',
        album: 'Радио Пепел',
        durationSec: 147,
        addedAt: 100,
        artists: [tank],
      ),
      for (final (i, title) in [
        'Маленький',
        'Люди',
        'Спички',
        'Бесполезно',
        'Мама',
        'Альтернатива',
      ].indexed)
        NewTrack(
          sourceKey: '1_${10 + i}',
          artist: 'Дайте танк (!)',
          title: title,
          album: i < 3 ? 'Радио Пепел' : 'Человеко-часы',
          durationSec: 190 + i * 11,
          addedAt: 90 - i,
          artists: const [tank],
        ),
      const NewTrack(
        sourceKey: '1_2',
        artist: 'Дайте танк (!) feat. Рита Вихрия',
        title: 'Вдвоём',
        durationSec: 201,
        addedAt: 99,
        artists: [tank, rita],
      ),
      const NewTrack(
        sourceKey: '1_3',
        artist: 'Старый рок-клуб',
        title: 'Без имени на VK',
        durationSec: 150,
        addedAt: 50,
      ),
      const NewTrack(
        sourceKey: '1_4',
        artist:
            'Оркестр Государственного академического Большого театра '
            'России',
        title: 'Увертюра',
        album: 'Классика',
        durationSec: 420,
        addedAt: 40,
        artists: [longName],
      ),
      for (final (i, (artist, id, title)) in [
        ('Кино', '50001', 'Группа крови'),
        ('Земфира', '50002', 'Хочешь?'),
        ('Сплин', '50003', 'Выхода нет'),
        ('Radiohead', '50004', 'Weird Fishes'),
        ('Daft Punk', '50005', 'Digital Love'),
        ('Аквариум', '50006', 'Город золотой'),
        ('Portishead', '50007', 'Glory Box'),
        ('Massive Attack', '50008', 'Teardrop'),
        ('Мумий Тролль', '50009', 'Владивосток 2000'),
        ('ДДТ', '50010', 'Что такое осень'),
      ].indexed)
        NewTrack(
          sourceKey: '1_${30 + i}',
          artist: artist,
          title: title,
          album: title,
          durationSec: 200 + i * 7,
          addedAt: 80 - i,
          tint: 0xFF000000 | (0x303050 + i * 0x0a0806),
          artists: [ArtistCredit(vkId: id, name: artist)],
        ),
    ];
    final ids = store.upsertAll(vk, songs);
    // Plays for Most heard.
    final today = DateTime.now();
    store.addPlays([
      for (final (i, id) in ids.indexed)
        for (var n = 0; n < (i * 7) % 11 + 1; n++)
          (
            id,
            DateTime(
              today.year,
              today.month,
              today.day - n,
            ).millisecondsSinceEpoch,
            170000,
            'finished',
          ),
    ]);
    final settingsStore = <String, String?>{};
    final filters = SongFilters(
      store,
      readSetting: (key) => settingsStore[key],
      writeSetting: (key, value) => settingsStore[key] = value,
    )..load();
    final collections = CollectionsController(store);
    final library = LibraryController(
      store.loadAll(),
      filters: filters,
      collections: collections,
      albums: LibraryAlbums(store: store, apiOfSource: (_) => null),
    );
    final sources = ValueNotifier(store.sources());
    final storage = AudioStorage(dataDir: '.', store: store);
    final player = _ShownPlayer(storage);
    final playback = PlaybackController(player: player);

    final never = Completer<Object?>();
    Future<Object?> fakeVk(String method, Map<String, String> params) async {
      switch (method) {
        case 'catalog.getAudioArtist':
          if (step == 'loading') return never.future;
          if (step == 'failed') {
            throw const SocketException('no network');
          }
          final page = _page();
          for (final (i, link) in (page['links'] as List).indexed) {
            (link as Map)['url'] = 'https://vk.ru/artist/similar$i';
          }
          if (params['artist_id'] != '10000') {
            final artist = (page['artists'] as List).first as Map;
            artist['id'] = '30000';
            artist['name'] = 'Серебряная Свадьба';
          }
          return page;
        case 'catalog.getBlockItems':
          return {
            'audios': <Object>[],
            'block': {'audios_ids': <Object>[]},
          };
        case 'execute':
          // No photos in the shots: the tiles show their letters.
          return <Object>[];
        case 'audio.add':
          return {
            'items_count': 1,
            'errors_count': 0,
            'items': [
              {'new_audio_id': 900, 'new_owner_id': 1},
            ],
            'errors': <Object>[],
          };
      }
      return null;
    }

    final catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (_) => fakeVk,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
    );
    final outside = OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong);
    final artists = LibraryArtists(
      library: library,
      credits: store.songArtistCredits,
      albumKeys: store.listedVkAlbumKeys,
      plays: () => filters.allTime,
      loadPhotos: store.artistPhotos,
      savePhotos: store.saveArtistPhotos,
      outside: outside,
      accounts: () => catalog.accounts,
      apiOfSource: (_) => fakeVk,
      readSetting: (key) => settingsStore[key],
      writeSetting: (key, value) => settingsStore[key] = value,
    );
    artists.onListChanged = library.listChanged;
    library.artistSongsOf = artists.songsOf;
    library.vkLists = artists;
    if (step == 'heard') artists.sort = ArtistSort.mostHeard;

    final settings = ShellSettings.inMemory();
    if (!dark) settings.toggleTheme();
    if (rail) settings.toggleRail();
    settings.dockTo(PlayerDock.side);

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
          home: SourcesScope(
            sources: sources,
            child: LibraryScreen(
              library: library,
              playback: playback,
              collections: collections,
              settings: settings,
              catalog: catalog,
              artists: artists,
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    // A song of the artist plays (its row and the player show it).
    await playback.playFrom(library.all, 2);
    artists.warmUp();
    await settle();
    switch (step) {
      case 'grid' || 'heard' || 'search':
        library.showView(const LibraryView(ViewKind.artists));
        if (step == 'search') library.searchText.text = 'да';
      case 'page' ||
          'loading' ||
          'failed' ||
          'songs' ||
          'popular' ||
          'playing' ||
          'cards':
        library.openArtist('vk:10000');
      case 'nameOnly':
        library.openArtist('name:старый рок-клуб');
      case 'domain':
        library.openArtist('domain:similar1');
      case 'long':
        library.openArtist('vk:40000');
      case 'links':
        break;
    }
    await settle();
    await settle();
    if (step == 'songs') {
      library.openArtistSongs('vk:10000');
      await settle();
    }
    if (step == 'popular') {
      // "Show more" is below the fold at 900 px: what it does.
      final vkPart = artists.vkOf('10000');
      final ref = artists.popularRef(vkPart.page!, vkPart.sourceId!);
      library.openList(ref);
      unawaited(artists.morePopular(ref));
      await settle();
    }
    TestGesture? mouse;
    // The artist plays from the header: Play shows Pause, Shuffle is on.
    if (step == 'playing') {
      await tester.tap(find.byKey(const ValueKey('artist-shuffle')));
      await settle();
    }
    // An album plays from its card (outlined, Pause kept), and the mouse
    // rests on a release card (its Play shown).
    if (step == 'cards') {
      // Real soft shadows, not the test's solid outlines.
      debugDisableShadows = false;
      final scroll = find.byType(Scrollable).first;
      final album = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('artist-album-'),
      );
      await tester.scrollUntilVisible(album.first, 300, scrollable: scroll);
      await tester.drag(scroll, const Offset(0, -120));
      await settle();
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final albumPlay = find.descendant(
        of: album.first,
        matching: find.byType(CardPlayButton),
      );
      await mouse.addPointer(location: tester.getCenter(albumPlay));
      await settle();
      await tester.tap(albumPlay);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await settle();
      }
      // Sound plays: the playing card's Play shows moving bars.
      player.playing.value = true;
      await mouse.moveTo(tester.getCenter(album.at(1)));
      await settle();
    }
    if (step == 'links') {
      final duet = library.all.firstWhere((t) => t.title == 'Вдвоём');
      final line = find.byKey(ValueKey('artist-line-${duet.id}'));
      final box = tester.getRect(line);
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      // Over "Рита Вихрия", after " feat. ".
      await mouse.moveTo(Offset(box.left + 150, box.center.dy));
      await settle();
    }
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
      final image = await render.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File(p.join(shotsDir, '$name.png'))
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
    await mouse?.removePointer();
    debugDisableShadows = true;
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
    artists.dispose();
    catalog.dispose();
  }

  for (final (step, dark, size) in [
    ('grid', true, const Size(1440, 900)),
    ('grid', false, const Size(1440, 900)),
    ('grid', false, const Size(760, 900)),
    ('heard', true, const Size(1440, 900)),
    ('search', false, const Size(1440, 900)),
    ('page', true, const Size(1440, 900)),
    ('page', false, const Size(1440, 900)),
    ('page', true, const Size(760, 900)),
    ('loading', false, const Size(1440, 900)),
    ('failed', true, const Size(1440, 900)),
    ('nameOnly', false, const Size(1440, 900)),
    ('domain', true, const Size(1440, 900)),
    ('long', false, const Size(1440, 900)),
    ('long', true, const Size(760, 900)),
    ('songs', true, const Size(1440, 900)),
    ('popular', false, const Size(1440, 900)),
    ('links', true, const Size(1440, 900)),
    ('playing', true, const Size(1440, 900)),
    ('cards', true, const Size(1440, 900)),
    ('cards', false, const Size(760, 900)),
  ]) {
    final width = size.width < 1000 ? 'narrow' : 'wide';
    testWidgets(
      'Artists: $step, ${dark ? 'dark' : 'light'}, $width',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-artists-$step-$width',
        step: step,
        dark: dark,
        size: size,
      ),
    );
  }
}
