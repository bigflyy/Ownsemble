import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

void main() {
  late Directory dir;
  late LibraryStore store;
  late LibraryController library;
  late Completer<Object?> vkAnswer;
  late List<Map<String, String>> asked;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ownsemble_album_screen');
    store = LibraryStore.open(':memory:');
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Дайте танк (!)',
        title: 'Люди',
        album: 'Человеко-часы',
        durationSec: 162,
        addedAt: 2,
        vkTrackId: 101,
        vkAlbumKey: '-5_9',
        vkAlbumAccessKey: 'a',
      ),
      const NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Выхода нет',
        album: 'Гранатовый альбом',
        durationSec: 236,
        addedAt: 1,
      ),
    ]);
    vkAnswer = Completer();
    asked = [];
    library = LibraryController(
      store.loadAll(),
      albums: LibraryAlbums(
        store: store,
        apiOfSource: (_) => (method, params) {
          asked.add(params);
          return vkAnswer.future;
        },
      ),
    );
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  /// VK's list of the album: the library's song and one it lacks.
  final albumReply = {
    'count': 2,
    'items': [
      {
        'owner_id': -5,
        'id': 2,
        'access_key': 'k2',
        'artist': 'Дайте танк (!)',
        'title': 'Альтернатива',
        'duration': 230,
        'track_id': 102,
      },
      {
        'owner_id': -5,
        'id': 1,
        'access_key': 'k1',
        'artist': 'Дайте танк (!)',
        'title': 'Люди',
        'duration': 162,
        'track_id': 101,
      },
    ],
  };

  Future<void> pumpScreen(WidgetTester tester) async {
    // Made in the test's own zone: a future made in setUp would complete
    // outside the fake clock that pump drives.
    vkAnswer = Completer();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          collections: CollectionsController(store),
          playback: PlaybackController(
            player: PlayerService(
              muted: true,
              dataDir: dir.path,
              storage: AudioStorage(dataDir: dir.path, store: store),
            ),
            recordPlay: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder albumStatus() => find.byKey(const ValueKey('album-status'));

  String statusText(WidgetTester tester) =>
      tester.widget<Text>(albumStatus()).data!;

  testWidgets('a click on the album name opens the album, Back leaves it', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.text('All songs'), findsOneWidget);
    await tester.tap(find.text('Человеко-часы'));
    await tester.pump();

    expect(library.view.kind, ViewKind.album);
    // The album's title heads the list; the library's song shows at once.
    expect(find.text('Человеко-часы'), findsWidgets);
    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Выхода нет'), findsNothing);
    expect(statusText(tester), contains('loading the rest from VK'));
    expect(asked.single['album_id'], '9');
    // Opening the album did not play the row's song.
    expect(library.view.album?.title, 'Человеко-часы');

    // As VK sends it: decoded JSON.
    vkAnswer.complete(jsonDecode(jsonEncode(albumReply)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Альтернатива'), findsOneWidget);
    expect(
      statusText(tester),
      contains('album from VK, 1 song in your library'),
    );

    await tester.tap(find.byKey(const ValueKey('album-back')));
    await tester.pump();
    expect(library.view, LibraryView.songs);
    expect(albumStatus(), findsNothing);
    expect(find.text('Выхода нет'), findsOneWidget);
  });

  testWidgets('a song outside the library only plays from its menu', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Человеко-часы'));
    await tester.pump();
    // As VK sends it: decoded JSON.
    vkAnswer.complete(jsonDecode(jsonEncode(albumReply)));
    await tester.pump();
    await tester.pump();

    Future<void> openMenu(String title) async {
      await tester.tap(find.text(title), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    // The row says the song is not in the library.
    final outside = library.visible.firstWhere((t) => !t.inLibrary);
    expect(
      find.byKey(ValueKey('mark-${outside.id}-${Icons.public.codePoint}')),
      findsOneWidget,
    );

    await openMenu('Альтернатива');
    expect(find.byKey(const ValueKey('menu-play-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-download')), findsNothing);
    expect(find.byKey(const ValueKey('new-stack')), findsNothing);
    // Already in its album: no "Open the album".
    expect(find.byKey(const ValueKey('menu-open-album')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // The library's own song keeps its full menu.
    await openMenu('Люди');
    expect(find.byKey(const ValueKey('menu-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-stack')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the song menu opens the album too', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Выхода нет'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-open-album')));
    await tester.pumpAndSettle();
    // No VK link: the library's songs of that album and artist, no ask.
    expect(library.view.album?.title, 'Гранатовый альбом');
    expect(find.text('Выхода нет'), findsOneWidget);
    expect(find.text('Люди'), findsNothing);
    expect(asked, isEmpty);
    expect(statusText(tester), contains('the next sync links this album'));
  });
}
