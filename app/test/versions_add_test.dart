// Widget tests for + in a song's Versions (plan 06, C4): every other upload
// of the song has + (the song itself does not count as "already in the
// library" there), VK's own file of the song has none, and an added upload
// keeps its check, also for a fresh start of the app.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/mp3_length.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/ui/catalog_search.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/vk/vk_client.dart';

import 'catalog_support.dart';

SongVersion upload(
  String key,
  double seconds, {
  int listed = 219,
  int? trackId,
}) => SongVersion(
  key: key,
  accessKey: 'k$key',
  artist: 'Операция Пластилин',
  title: 'Ты и я',
  album: 'Волна',
  listedSec: listed,
  vkTrackId: trackId,
  file: FileFacts(bytes: (seconds * 40000).round(), seconds: seconds),
);

void main() {
  late LibraryStore store;
  late int source;
  late FakeVk vk;
  late VersionBook versions;
  late PlayerService player;
  late LibraryController library;
  late ValueNotifier<List<SourceInfo>> sources;
  late CatalogSearch catalog;

  CatalogSearch makeCatalog() => CatalogSearch(
    library: library,
    store: store,
    sources: sources,
    apiOfSource: (id) => id == source ? vk.call : null,
    onLibraryChanged: ({required severalAccounts}) {
      final tracks = store.loadAll();
      library.replaceTracks(tracks, SearchIndex(tracks));
    },
  );

  setUp(() {
    store = LibraryStore.open(':memory:');
    source = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    store.upsertAll(source, [
      const NewTrack(
        sourceKey: '42_1',
        artist: 'Операция Пластилин',
        title: 'Ты и я',
        durationSec: 219,
        addedAt: 2,
        vkTrackId: 500,
      ),
    ]);
    vk = FakeVk(42);
    versions = VersionBook(
      store: store,
      find: (track, route, progress) async => [
        upload('5_1', 219.2, trackId: 500),
        upload('6_1', 226.5, listed: 226, trackId: 600),
      ],
      measure: (route) async => const FileFacts(bytes: 8760000, seconds: 219),
    );
    player = PlayerService(
      muted: true,
      dataDir: '.',
      accounts: (sourceId) => VkClient(const []),
    )..versions = versions;
    library = LibraryController(store.loadAll(), versions: versions);
    sources = ValueNotifier(store.sources());
    catalog = makeCatalog();
  });

  tearDown(() {
    catalog.dispose();
    store.close();
  });

  Future<Track> openVersions(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SourcesScope(
        sources: sources,
        child: MaterialApp(
          home: LibraryScreen(
            library: library,
            playback: PlaybackController(player: player),
            catalog: catalog,
          ),
        ),
      ),
    );
    await tester.pump();
    final song = library.all.single;
    await tester.tap(find.text('Ты и я'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-versions')));
    await tester.pumpAndSettle();
    expect(library.view.kind, ViewKind.versions);
    return song;
  }

  Finder addIn(Track song, String key) => find.descendant(
    of: find.byKey(
      ValueKey('song-${versions.versionTrack(song, upload(key, 1)).id}'),
    ),
    matching: find.byKey(const ValueKey('add-song')),
  );

  Finder checkIn(Track song, String key) => find.descendant(
    of: find.byKey(
      ValueKey('song-${versions.versionTrack(song, upload(key, 1)).id}'),
    ),
    matching: find.byKey(const ValueKey('song-added')),
  );

  testWidgets("+ on every other upload, none on VK's own file; an added "
      'upload keeps its check', (tester) async {
    final song = await openVersions(tester);
    expect(library.visible, hasLength(3));
    // Same name, length and VK track id as the song: still addable here.
    expect(addIn(song, '5_1'), findsOneWidget);
    expect(addIn(song, '6_1'), findsOneWidget);
    expect(addIn(song, '42_1'), findsNothing, reason: "VK's own file");
    expect(checkIn(song, '42_1'), findsNothing);

    await tester.tap(addIn(song, '6_1'));
    await tester.pump();
    await tester.pump();
    expect(vk.adds, ['6_1 k6_1']);
    expect(checkIn(song, '6_1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // The library lists both songs now; the versions place stays.
    expect(store.loadAll(), hasLength(2));
    expect(library.view.kind, ViewKind.versions);
    expect(checkIn(song, '6_1'), findsOneWidget);
    expect(addIn(song, '5_1'), findsOneWidget);

    // A fresh start: the added copy (226 s, VK track 600) is in the
    // library, so its upload shows the check; the 219 s upload matches only
    // the song itself.
    catalog.dispose();
    catalog = makeCatalog();
    final tracks = [
      for (final shown in library.visible)
        if (library.versionOf(shown) case final version?)
          (version.key, shown, version),
    ];
    final (_, track6, version6) = tracks.firstWhere((t) => t.$1 == '6_1');
    final (_, track5, version5) = tracks.firstWhere((t) => t.$1 == '5_1');
    expect(
      catalog.stateOf(
        catalog.outsideSong(
          track6,
          vkTrackId: version6.vkTrackId,
          except: {song.id},
        ),
      ),
      FoundState.inLibrary,
    );
    expect(
      catalog.stateOf(
        catalog.outsideSong(
          track5,
          vkTrackId: version5.vkTrackId,
          except: {song.id},
        ),
      ),
      FoundState.addable,
    );
    await tester.pump(const Duration(seconds: 5));
  });
}
