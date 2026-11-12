// Widget tests for + in an album's place (plan 06, C4): each song of the
// album the library lacks has + in the heart's slot, the heading offers
// "Add the other N", and once VK has added them the album lists them as the
// library's own songs.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sources_scope.dart';

import 'catalog_support.dart';

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late LibraryController library;
  late CatalogSearch catalog;
  late ValueNotifier<List<SourceInfo>> sources;
  late PlaybackController playback;

  late Map<String, Object> albumReply;

  /// VK's list of the album: the library's song and two it lacks.
  Map<String, Object> makeReply() => {
    'count': 3,
    'items': [
      for (final (id, title, trackId) in [
        (1, 'Люди', 101),
        (2, 'Альтернатива', 102),
        (3, 'Маяк', 103),
      ])
        {
          'owner_id': -5,
          'id': id,
          'access_key': 'k$id',
          'artist': 'Дайте танк (!)',
          'title': title,
          'duration': 160 + id * 20,
          'track_id': trackId,
        },
    ],
  };

  setUp(() {
    albumReply = makeReply();
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    store.upsertAll(source, [
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Дайте танк (!)',
        title: 'Люди',
        album: 'Человеко-часы',
        durationSec: 180,
        addedAt: 2,
        vkTrackId: 101,
        vkAlbumKey: '-5_9',
        vkAlbumAccessKey: 'a',
      ),
    ]);
    vk = FakeVk(42);
    Future<Object?> call(String method, Map<String, String> params) async =>
        method == 'audio.get'
        ? jsonDecode(jsonEncode(albumReply))
        : vk.call(method, params);
    library = LibraryController(
      store.loadAll(),
      albums: LibraryAlbums(store: store, apiOfSource: (_) => call),
    );
    sources = ValueNotifier(store.sources());
    playback = PlaybackController(player: ShowingPlayer());
    catalog = CatalogSearch(
      library: library,
      store: store,
      sources: sources,
      apiOfSource: (id) => id == source ? call : null,
      onLibraryChanged: ({required severalAccounts}) {
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
      },
      onAdded: playback.adoptAdded,
    );
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  /// Puts [songs] into the library after setUp, as a sync would.
  void addToLibrary(List<NewTrack> songs) {
    store.upsertAll(source, songs);
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
  }

  Future<void> openAlbum(WidgetTester tester, {int songs = 3}) async {
    tester.view.physicalSize = const Size(1400, 900);
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
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Человеко-часы').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(library.view.kind, ViewKind.album);
    expect(library.visible, hasLength(songs));
  }

  Track outside(String title) =>
      library.visible.firstWhere((t) => t.title == title && !t.inLibrary);

  Finder addOf(Track track) => find.descendant(
    of: find.byKey(ValueKey('song-${track.id}')),
    matching: find.byKey(const ValueKey('add-song')),
  );

  testWidgets('+ on each song the library lacks, and Add the other N', (
    tester,
  ) async {
    await openAlbum(tester);
    final alternative = outside('Альтернатива');
    final lighthouse = outside('Маяк');
    expect(addOf(alternative), findsOneWidget);
    expect(addOf(lighthouse), findsOneWidget);
    // The library's own song keeps its heart, no +.
    final own = library.visible.firstWhere((t) => t.inLibrary);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('song-${own.id}')),
        matching: find.byKey(const ValueKey('add-song')),
      ),
      findsNothing,
    );
    expect(find.text('Add the other 2'), findsOneWidget);

    // + on one row: the check, the note, and one fewer to add.
    await tester.tap(addOf(alternative));
    await tester.pump();
    await tester.pump();
    expect(vk.adds, ['-5_2 k2']);
    expect(find.text('Added "Альтернатива" to Мой VK'), findsOneWidget);
    expect(find.text('Add the other 1'), findsOneWidget);

    // After the animation the lists reload: the album lists the added copy
    // as the library's own song (same VK track id).
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final added = library.visible.firstWhere((t) => t.title == 'Альтернатива');
    expect(added.inLibrary, isTrue);
    expect(added.sourceKey, '42_900');
    expect(library.visible, hasLength(3));

    // Add the other 1 adds the last one.
    await tester.tap(find.byKey(const ValueKey('album-add-all')));
    await tester.pump();
    await tester.pump();
    expect(vk.adds, ['-5_2 k2', '-5_3 k3']);
    // The first note slides out before the new one comes in.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Added 1 song to Мой VK'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(library.visible.every((t) => t.inLibrary), isTrue);
    expect(library.visible, hasLength(3));
    expect(find.byKey(const ValueKey('album-add-all')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('album-status'))).data,
      contains('3 songs in your library'),
    );
    // Let the note's timer run out.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an added song VK lists without a track id takes its place in '
      'the album, not a second row', (tester) async {
    // VK leaves track_id out on some album songs: the copy is matched by
    // name and length instead.
    final items = albumReply['items']! as List;
    (items[2] as Map).remove('track_id');
    await openAlbum(tester);
    await tester.tap(addOf(outside('Маяк')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(store.loadAll(), hasLength(2));
    expect(library.visible, hasLength(3), reason: 'no row twice');
    expect(library.visible.map((t) => t.title), [
      'Люди',
      'Альтернатива',
      'Маяк',
    ], reason: "in the album's order");
    expect(library.visible.last.inLibrary, isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a song you have as another recording says so and keeps +', (
    tester,
  ) async {
    // User, 2026-11-12: album songs did not show as theirs, "maybe i have
    // other versions added"; a hint, and + still adds this one (C4e).
    addToLibrary([
      const NewTrack(
        sourceKey: '42_2',
        artist: 'Дайте танк (!)',
        title: 'Маяк',
        album: 'Live',
        durationSec: 300,
        addedAt: 3,
      ),
    ]);
    await openAlbum(tester);
    final lighthouse = outside('Маяк');
    final tag = find.byKey(ValueKey('other-version-${lighthouse.id}'));
    expect(tag, findsOneWidget);
    expect(find.text('you have another version'), findsOneWidget);
    expect(
      tester
          .widget<Tooltip>(
            find.descendant(of: tag, matching: find.byType(Tooltip)),
          )
          .message,
      'You have this song as another recording (5:00; this one is 3:40). '
      '+ adds this one as well.',
    );
    expect(addOf(lighthouse), findsOneWidget);
    // A song of another name has no tag.
    expect(
      find.byKey(ValueKey('other-version-${outside('Альтернатива').id}')),
      findsNothing,
    );

    await tester.tap(addOf(lighthouse));
    await tester.pump();
    await tester.pump();
    expect(vk.adds, ['-5_3 k3']);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('you have another version'), findsNothing);
    expect(store.loadAll(), hasLength(3), reason: 'both recordings kept');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a song with a track id VK reused but another length does not '
      'take an album row', (tester) async {
    // Real VK, 2026-11-12: one track id on other songs (a 1380 s concert).
    addToLibrary([
      const NewTrack(
        sourceKey: '42_7',
        artist: 'Дайте танк (!)',
        title: 'Концерт',
        album: 'Человеко-часы',
        durationSec: 1380,
        addedAt: 4,
        vkTrackId: 102,
        vkAlbumKey: '-5_9',
        vkAlbumAccessKey: 'a',
      ),
    ]);
    await openAlbum(tester, songs: 4);
    expect(library.visible.map((t) => t.title), [
      'Люди',
      'Альтернатива',
      'Маяк',
      'Концерт',
    ]);
    expect(outside('Альтернатива'), isNotNull);
    expect(addOf(outside('Альтернатива')), findsOneWidget);
  });

  testWidgets('a song + adds while it plays keeps its playing mark', (
    tester,
  ) async {
    // User, 2026-11-12: "when i add the song that i listened to in the
    // album its playing animation disappeared."
    await openAlbum(tester);
    final song = outside('Альтернатива');
    await tester.tap(find.byKey(ValueKey('song-${song.id}')));
    await tester.pump();
    await tester.pump();
    expect(playback.player.current?.id, song.id);
    Finder markOf(Track track) => find.descendant(
      of: find.byKey(ValueKey('song-${track.id}')),
      matching: find.byKey(const ValueKey('playing-bars')),
    );
    expect(markOf(song), findsOneWidget);
    await tester.tap(addOf(song));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final added = library.visible.firstWhere((t) => t.title == 'Альтернатива');
    expect(added.inLibrary, isTrue);
    expect(playback.player.current?.id, added.id);
    expect(markOf(added), findsOneWidget);
    // Stops the controller's periodic save of the place.
    playback.player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Add the other N adds them all at once', (tester) async {
    await openAlbum(tester);
    await tester.tap(find.byKey(const ValueKey('album-add-all')));
    await tester.pump();
    await tester.pump();
    expect(vk.adds, ['-5_2 k2', '-5_3 k3']);
    expect(find.text('Added 2 songs to Мой VK'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(library.visible.every((t) => t.inLibrary), isTrue);
    expect(store.loadAll(), hasLength(3));
    await tester.pump(const Duration(seconds: 5));
  });
}
