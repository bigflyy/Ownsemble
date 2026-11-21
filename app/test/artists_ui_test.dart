// Widget tests for plan 09 Stage D: the Artists place (grid, sort kept,
// search, photos asked of VK while it is open), an artist's page (library
// part at once, VK's Popular / Releases / You may like from the scrubbed
// page of the test account, loading and error states, a name-only
// artist), "Show all" as a song list, + on a Popular song showing on the
// page at once (R3), and artist names in song rows as links (D3).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/artists.dart';
import 'package:ownsemble/ui/artists_page.dart' show ArtistPhoto;
import 'package:ownsemble/ui/card_play.dart';
import 'package:ownsemble/ui/cover_tile.dart' show TrackTile;
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/vk/vk_artists.dart';

import 'card_support.dart';
import 'catalog_support.dart';

const tank = ArtistCredit(vkId: '10000', name: 'Дайте танк (!)');
const rita = ArtistCredit(vkId: '20000', name: 'Рита', featured: true);

Map<String, dynamic> _page() => jsonDecode(
  File('test/fixtures/vk_artists/catalog_get_audio_artist.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late LibraryArtists artists;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;
  late ShowingPlayer player;
  late Map<String, String?> settings;
  late List<String> calls;

  /// What the next artist page request does: null answers the fixture.
  Completer<Object?>? pageGate;
  Object? pageError;
  Object? Function(Map<String, String> params)? pageAnswer;
  Object? Function(Map<String, String> params)? blockItemsAnswer;

  void reload() {
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
  }

  setUp(() {
    pageGate = null;
    pageError = null;
    pageAnswer = null;
    blockItemsAnswer = null;
    calls = [];
    settings = {};
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    store.upsertAll(source, [
      // Popular's first song, as the account's own copy.
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Дайте танк (!)',
        title: 'Утро',
        durationSec: 147,
        addedAt: 10,
        album: 'Радио Пепел',
        vkAlbumKey: '-7_62',
        artists: [tank],
      ),
      for (var i = 2; i <= 6; i++)
        NewTrack(
          sourceKey: '42_$i',
          artist: 'Дайте танк (!)',
          title: 'Своя $i',
          durationSec: 200 + i,
          addedAt: 10 - i,
          artists: const [tank],
        ),
      const NewTrack(
        sourceKey: '42_7',
        artist: 'Дайте танк (!) feat. Рита',
        title: 'Вдвоём',
        durationSec: 190,
        addedAt: 1,
        artists: [tank, rita],
      ),
      // No artist id: a name-only artist.
      const NewTrack(
        sourceKey: '42_8',
        artist: 'Старый рок-клуб',
        title: 'Без id',
        durationSec: 150,
        addedAt: 0,
      ),
    ]);
    vk = FakeVk(42);
    Future<Object?> call(String method, Map<String, String> params) async {
      calls.add(method);
      if (method == 'catalog.getAudioArtist') {
        if (pageError case final error?) throw error;
        if (pageGate case final gate?) return gate.future;
        if (pageAnswer case final answer?) return answer(params);
        return _page();
      }
      // The album "Радио Пепел" on VK: Утро, "Своя 2" (another upload of
      // the library's song with no album) and a song the library lacks.
      if (method == 'audio.get' && params['album_id'] == '62') {
        Map<String, Object> item(int id, String title, int seconds) => {
          'owner_id': -7,
          'id': id,
          'artist': 'Дайте танк (!)',
          'title': title,
          'duration': seconds,
          'url': 'https://audio.invalid/$id.mp3',
        };
        return {
          'count': 3,
          'items': [
            item(1, 'Утро', 147),
            item(2, 'Своя 2', 202),
            item(3, 'Чужая', 180),
          ],
        };
      }
      if (method == 'catalog.getBlockItems' && blockItemsAnswer != null) {
        return blockItemsAnswer!(params);
      }
      if (method == 'execute') {
        // One search per artist asked: the first answers with its photo.
        final code = params['code']!;
        final count = 'searchArtists'.allMatches(code).length;
        return [
          for (var i = 0; i < count; i++)
            [
              {
                'id': '10000',
                'photo': [
                  {
                    'url': 'https://example.invalid/p135.jpg',
                    'width': 135,
                    'height': 135,
                  },
                  {
                    'url': 'https://example.invalid/p270.jpg',
                    'width': 270,
                    'height': 270,
                  },
                ],
              },
            ],
        ];
      }
      return vk.call(method, params);
    }

    library = LibraryController(
      store.loadAll(),
      albums: LibraryAlbums(
        store: store,
        apiOfSource: (id) => id == source ? call : null,
      ),
    );
    sources = ValueNotifier(store.sources());
    player = ShowingPlayer();
    playback = PlaybackController(player: player);
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? call : null,
      onLibraryChanged: ({required severalAccounts}) => reload(),
      onAdded: playback.adoptAdded,
    );
    final outside = OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong);
    artists = LibraryArtists(
      library: library,
      credits: store.songArtistCredits,
      albumKeys: store.listedVkAlbumKeys,
      loadPhotos: store.artistPhotos,
      savePhotos: store.saveArtistPhotos,
      outside: outside,
      accounts: () => catalog.accounts,
      apiOfSource: (id) => id == source ? call : null,
      readSetting: (key) => settings[key],
      writeSetting: (key, value) => settings[key] = value,
    );
    artists.onListChanged = library.listChanged;
    library.artistSongsOf = artists.songsOf;
    library.vkLists = artists;
  });

  tearDown(() {
    artists.dispose();
    catalog.dispose();
    store.close();
  });

  // Tall enough that the whole artist page is laid out without scrolling.
  Future<void> show(
    WidgetTester tester, {
    double width = 1400,
    double height = 2400,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SourcesScope(
        sources: sources,
        child: MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: playback,
            catalog: catalog,
            artists: artists,
            settings: ShellSettings.inMemory(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openArtists(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav-artists')));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> openTank(WidgetTester tester) async {
    await openArtists(tester);
    await tester.tap(find.byKey(const ValueKey('artist-vk:10000')));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  group('the Artists place', () {
    testWidgets('a tile per artist, most songs first; the sort is kept', (
      tester,
    ) async {
      await show(tester);
      expect(find.text('later'), findsOneWidget, reason: 'only Playlists');
      await openArtists(tester);
      expect(library.view.kind, ViewKind.artists);
      expect(find.text('3 artists'), findsOneWidget);
      final tiles = [
        for (final key in ['vk:10000', 'vk:20000', 'name:старый рок-клуб'])
          tester.getTopLeft(find.byKey(ValueKey('artist-$key'))).dx,
      ];
      expect(tiles, orderedEquals([...tiles]..sort()));
      expect(find.text('7 songs'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('artists-sort-name')));
      await tester.pumpAndSettle();
      expect(settings[artistsSortSetting], 'name');
      expect(artists.shown('').map((a) => a.name), [
        'Дайте танк (!)',
        'Рита',
        'Старый рок-клуб',
      ]);
      // A new run starts with the kept sort.
      final again = LibraryArtists(
        library: library,
        credits: store.songArtistCredits,
        outside: OutsideSongs(libraryCopyOfSong: (_) => null),
        accounts: () => const [],
        apiOfSource: (_) => null,
        readSetting: (key) => settings[key],
      );
      expect(again.sort, ArtistSort.name);
      again.dispose();
    });

    testWidgets('the search box filters the artists by name', (tester) async {
      await show(tester);
      await openArtists(tester);
      await tester.enterText(find.byType(TextField).first, 'рок');
      await tester.pumpAndSettle();
      expect(find.text('1 of 3 artists'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artist-name:старый рок-клуб')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('artist-vk:10000')), findsNothing);
    });

    testWidgets('photos are asked of VK while the place is open and '
        'stored; a name-only artist is never asked', (tester) async {
      await show(tester);
      await openArtists(tester);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'execute'), hasLength(1));
      final stored = store.artistPhotos();
      expect(stored['10000']?.large, 'https://example.invalid/p270.jpg');
      expect(stored['10000']?.small, 'https://example.invalid/p135.jpg');
      // Рита's search did not name her: no photo, stored as none.
      expect(stored['20000']?.large, isNull);
      expect(stored, hasLength(2));
      // Open again: nothing to ask, the photos are fresh.
      await tester.tap(find.byKey(const ValueKey('nav-songs')));
      await tester.pumpAndSettle();
      await openArtists(tester);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'execute'), hasLength(1));
    });
  });

  group("an artist's page", () {
    testWidgets('the library part at once, then VK: Popular with a check '
        'on the own song and + on the rest, releases, similar', (tester) async {
      pageGate = Completer();
      await show(tester);
      await openTank(tester);
      expect(library.view.kind, ViewKind.artist);
      expect(find.byKey(const ValueKey('artist-page-name')), findsOneWidget);
      expect(find.text('7 songs and 1 album in your library'), findsOneWidget);
      expect(find.text('IN YOUR LIBRARY (7)'), findsOneWidget);
      expect(find.byKey(const ValueKey('artist-vk-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('artist-show-all')), findsOneWidget);

      pageGate!.complete(_page());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('artist-vk-loading')), findsNothing);
      expect(find.text('POPULAR ON VK'), findsOneWidget);
      expect(
        find.textContaining('On VK: 132 songs, 10 releases'),
        findsOneWidget,
      );
      // Утро is the library's song: its row, with a check.
      final own = library.all.firstWhere((t) => t.title == 'Утро');
      expect(find.byKey(ValueKey('have-${own.id}')), findsOneWidget);
      // The others are VK's, with +.
      expect(find.byKey(const ValueKey('artist-popular-more')), findsOneWidget);
      expect(find.text('Show more (132 on VK)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artist-release--10061_10062')),
        findsOneWidget,
      );
      expect(find.text('Серебряная Свадьба'), findsOneWidget);
    });

    testWidgets('a Popular list read before the page pages the releases '
        'too (Codex review 2026-11-21)', (tester) async {
      blockItemsAnswer = (params) => {
        'block': {
          'playlists_ids': ['-7_51'],
        },
        'playlists': [
          {
            'owner_id': -7,
            'id': 51,
            'type': 'album',
            'title': 'Старый альбом',
            'count': 9,
            'main_artists': [
              {'id': '10000', 'name': 'Дайте танк (!)'},
            ],
          },
        ],
      };
      await show(tester);
      final ref = artists.popularRef(vkArtistPageOf(_page())!, source);
      await tester.runAsync(() => artists.fetch(ref));
      await tester.pumpAndSettle();
      expect(artists.vkOf('10000').page?.releases, hasLength(11));
    });

    testWidgets("an album card counts your songs as the album's place does "
        '(user 2026-11-21: 4 on the tile, 11 in the album)', (tester) async {
      await show(tester);
      await openTank(tester);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      final own = library.all.firstWhere((t) => t.title == 'Утро');
      final card = find.byKey(ValueKey('artist-album-${own.id}'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // Утро tied to it, and "Своя 2" as another upload with no album.
      expect(
        find.descendant(of: card, matching: find.text('2 songs')),
        findsOneWidget,
      );
      expect(calls.where((c) => c == 'audio.get'), hasLength(1));
    });

    testWidgets('Play on an album card plays the whole album as its place '
        'lists it, and the card then shows it plays (user 2026-11-21)', (
      tester,
    ) async {
      await show(tester);
      await openTank(tester);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      final own = library.all.firstWhere((t) => t.title == 'Утро');
      final card = find.byKey(ValueKey('artist-album-${own.id}'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final play = find.descendant(
        of: card,
        matching: find.byType(CardPlayButton),
      );
      await tapCardPlay(tester, play);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final album = library.albumOf(own)!;
      expect(playback.queue.from?.label, album.title);
      expect(
        playback.queue.from?.place,
        LibraryView(ViewKind.album, album: album),
      );
      // The whole album: the two songs the card counts as yours and the one
      // the library does not have.
      expect(playback.queue.context, hasLength(3));
      expect(playback.queue.context.where((t) => t.inLibrary), hasLength(2));
      expect(playback.queue.context.map((t) => t.id), contains(own.id));
      expect(
        find.descendant(of: play, matching: find.byIcon(Icons.pause)),
        findsOne,
      );
      player.playing.value = false;
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('releases past the first ten come in after the page '
        '(user 2026-11-21: "not all the albums")', (tester) async {
      blockItemsAnswer = (params) => {
        'block': {
          'id': params['block_id'],
          'playlists_ids': ['-7_51'],
        },
        'playlists': [
          {
            'owner_id': -7,
            'id': 51,
            'type': 'album',
            'title': 'Старый альбом',
            'count': 9,
            'year': 2004,
            'main_artists': [
              {'id': '10000', 'name': 'Дайте танк (!)'},
            ],
          },
        ],
      };
      await show(tester);
      await openTank(tester);
      await tester.pumpAndSettle();
      expect(calls, contains('catalog.getBlockItems'));
      expect(
        find.textContaining('On VK: 132 songs, 11 releases'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('artist-release--7_51')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Старый альбом'), findsOneWidget);
    });

    testWidgets('Play plays the library songs; Show all opens them as a '
        'song list and Back returns', (tester) async {
      await show(tester);
      await openTank(tester);
      await tester.tap(find.byKey(const ValueKey('artist-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(playback.queue.context, hasLength(7));
      expect(playback.queue.from?.label, 'Дайте танк (!)');

      await tester.tap(find.byKey(const ValueKey('artist-show-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(library.view.kind, ViewKind.artistSongs);
      expect(library.visible, hasLength(7));
      expect(find.text('7 songs'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(library.view.kind, ViewKind.artist);
      player.playing.value = false;
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Play turns into Pause while the artist plays and a second '
        'click pauses instead of starting over (user 2026-11-21: "play and '
        'shuffle are unresponsive")', (tester) async {
      await show(tester);
      await openTank(tester);
      final play = find.byKey(const ValueKey('artist-play'));
      expect(find.descendant(of: play, matching: find.text('Play')), findsOne);

      await tester.tap(play);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.descendant(of: play, matching: find.text('Pause')), findsOne);
      final started = playback.player.current;

      await tester.tap(play);
      await tester.pump();
      expect(player.pauseToggles, 1);
      expect(playback.player.current, started);

      player.playing.value = false;
      await tester.pump();
      expect(find.descendant(of: play, matching: find.text('Play')), findsOne);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Shuffle starts the artist shuffled, then shows it is on and '
        'turns shuffle off and on while the artist plays', (tester) async {
      await show(tester);
      await openTank(tester);
      expect(playback.shuffle, isFalse);
      final shuffle = find.byKey(const ValueKey('artist-shuffle'));

      await tester.tap(shuffle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(playback.shuffle, isTrue);
      expect(playback.queue.from?.label, 'Дайте танк (!)');
      expect(
        find.descendant(of: shuffle, matching: find.text('Shuffle on')),
        findsOne,
      );
      final started = playback.player.current;

      await tester.tap(shuffle);
      await tester.pump();
      expect(playback.shuffle, isFalse);
      expect(playback.player.current, started);
      expect(
        find.descendant(of: shuffle, matching: find.text('Shuffle')),
        findsOne,
      );

      await tester.tap(shuffle);
      await tester.pump();
      expect(playback.shuffle, isTrue);
      expect(playback.player.current, started);
      player.playing.value = false;
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('VK not answering: the library part stays, Try again asks '
        'again', (tester) async {
      pageError = const SocketException('no network');
      await show(tester);
      await openTank(tester);
      expect(find.byKey(const ValueKey('artist-vk-failed')), findsOneWidget);
      expect(find.text('IN YOUR LIBRARY (7)'), findsOneWidget);
      pageError = null;
      await tester.tap(find.byKey(const ValueKey('artist-vk-retry')));
      await tester.pumpAndSettle();
      expect(find.text('POPULAR ON VK'), findsOneWidget);
    });

    testWidgets('a name-only artist has no VK part', (tester) async {
      await show(tester);
      await openArtists(tester);
      await tester.tap(
        find.byKey(const ValueKey('artist-name:старый рок-клуб')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('artist-vk-none')), findsOneWidget);
      expect(calls, isNot(contains('catalog.getAudioArtist')));
    });

    testWidgets('+ on a Popular song puts it on the page at once (R3)', (
      tester,
    ) async {
      await show(tester);
      await openTank(tester);
      final add = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('add-'),
      );
      expect(add, findsWidgets);
      await tester.tap(add.first);
      await tester.pumpAndSettle();
      expect(vk.adds, hasLength(1));
      expect(find.text('IN YOUR LIBRARY (8)'), findsOneWidget);
      // The added row keeps VK's artist: the index finds it by id.
      final added = library.all.firstWhere((t) => t.title == 'Люди');
      expect(
        artists.index.artistsOf(added.id).map((a) => a.key),
        contains('vk:10000'),
      );
    });

    testWidgets('a click on the photo shows it bigger; Esc closes it '
        '(user 2026-11-21)', (tester) async {
      await show(tester);
      await openTank(tester);
      // The grid asked for the photos: the header has one.
      expect(find.byKey(const ValueKey('artist-photo-open')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('artist-photo-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cover-viewer')), findsOneWidget);
      final side = tester.getSize(
        find.descendant(
          of: find.byKey(const ValueKey('cover-viewer')),
          matching: find.byType(TrackTile),
        ),
      );
      expect(side.width, lessThanOrEqualTo(ArtistPhoto.viewerSide));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cover-viewer')), findsNothing);
      expect(library.view.kind, ViewKind.artist);
    });

    testWidgets('a name-only artist has no photo to open', (tester) async {
      await show(tester);
      await openArtists(tester);
      await tester.tap(
        find.byKey(const ValueKey('artist-name:старый рок-клуб')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('artist-photo-open')), findsNothing);
    });

    testWidgets('a similar artist opens by address name', (tester) async {
      // The scrubbed fixture's links lost their /artist/ address; real VK
      // gives one (probe 2026-11-20).
      pageAnswer = (params) {
        final page = _page();
        for (final (i, link) in (page['links'] as List).indexed) {
          (link as Map)['url'] = 'https://vk.ru/artist/similar$i';
        }
        if (params['artist_id'] != '10000') {
          final artist = (page['artists'] as List).first as Map;
          artist['id'] = '30000';
          artist['name'] = 'Серебряная Свадьба';
          artist['domain'] = params['artist_id'];
        }
        return page;
      };
      await show(tester);
      await openTank(tester);
      await tester.tap(find.text('Серебряная Свадьба'));
      await tester.pumpAndSettle();
      expect(library.view.kind, ViewKind.artist);
      expect(library.view.artist, 'domain:similar1');
      expect(
        find.byKey(const ValueKey('artist-page-name')).evaluate().single.widget,
        isA<Text>().having((t) => t.data, 'name', 'Серебряная Свадьба'),
      );
      expect(
        find.textContaining('None of their songs in your library'),
        findsOneWidget,
      );
    });
  });

  group('artist names as links (D3)', () {
    testWidgets('each named artist of a row opens its page', (tester) async {
      await show(tester);
      artists.warmUp();
      await tester.pumpAndSettle();
      final duet = library.all.firstWhere((t) => t.title == 'Вдвоём');
      final line = find.byKey(ValueKey('artist-line-${duet.id}'));
      expect(line, findsOneWidget);
      // "Дайте танк (!) feat. Рита": the second name is its own link.
      final box = tester.getRect(line);
      await tester.tapAt(Offset(box.left + 4, box.center.dy));
      await tester.pumpAndSettle();
      expect(
        library.view,
        const LibraryView(ViewKind.artist, artist: 'vk:10000'),
      );
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await tester.pumpAndSettle();
      expect(library.view.kind, ViewKind.songs);
    });

    testWidgets('a name-only song links its text', (tester) async {
      await show(tester);
      artists.warmUp();
      await tester.pumpAndSettle();
      final own = library.all.firstWhere((t) => t.title == 'Без id');
      final line = find.byKey(ValueKey('artist-line-${own.id}'));
      final box = tester.getRect(line);
      await tester.tapAt(Offset(box.left + 4, box.center.dy));
      await tester.pumpAndSettle();
      expect(library.view.artist, 'name:старый рок-клуб');
    });
  });
}
