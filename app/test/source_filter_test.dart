import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/theme.dart';

import 'merge_support.dart';

/// A VK song of account [source], with the other accounts' copies [alsoIn].
Track song(
  int id,
  String title, {
  int source = 1,
  List<int> alsoIn = const [],
  bool downloaded = false,
}) => Track(
  id: id,
  sourceId: source,
  source: TrackSource.vk,
  artist: 'Артист',
  title: title,
  durationSec: 100,
  sourceKey: '${source}_$id',
  localPath: downloaded ? 'audio/$id.mp3' : null,
  pinned: downloaded,
  copies: [
    for (final other in alsoIn)
      TrackCopy(sourceId: other, sourceKey: '${other}_$id'),
  ],
);

SourceInfo account(int id, String name, {int songs = 1}) => SourceInfo(
  id: id,
  kind: TrackSource.vk,
  name: name,
  songCount: songs,
  goneCount: 0,
  account: '$id',
);

List<String> titles(LibraryController library) => [
  for (final track in library.visible) track.title,
];

void main() {
  late List<Track> tracks;
  late Map<String, String?> settings;
  late ValueNotifier<List<SourceInfo>> sources;

  LibraryController open() {
    final library = LibraryController(
      tracks,
      readSetting: (key) => settings[key],
      writeSetting: (key, value) => settings[key] = value,
    );
    library.watchSources(sources);
    return library;
  }

  setUp(() {
    tracks = [
      song(1, 'Первая'),
      song(2, 'Вторая', source: 2),
      song(3, 'Общая', alsoIn: [2]),
      song(4, 'Четвёртая', downloaded: true),
      song(5, 'Пятая', source: 2, downloaded: true),
    ];
    settings = {};
    sources = ValueNotifier([account(1, 'Мой'), account(2, 'Второй')]);
  });

  test('a source keeps its own songs and merged ones, in library order', () {
    final library = open();
    expect(library.sourceFilter, isNull);
    expect(library.viewCount, 5);

    library.showSource(2);
    expect(library.sourceFilter, 2);
    expect(titles(library), ['Вторая', 'Общая', 'Пятая']);
    expect(library.viewCount, 3);

    library.showSource(1);
    expect(titles(library), ['Первая', 'Общая', 'Четвёртая']);

    library.showSource(null);
    expect(library.visible.length, 5);
  });

  test('the filter and the search apply together, in every view', () {
    final library = open()..showSource(2);
    library.searchText.text = 'п'; // Первая (1) and Пятая (2)
    expect(titles(library), ['Пятая']);
    library.searchText.clear();

    library.showView(const LibraryView(ViewKind.downloads));
    expect(titles(library), ['Пятая']);
    expect(library.viewCount, 1);
    library.showSource(1);
    expect(titles(library), ['Четвёртая']);
  });

  test('the filter is saved and comes back in the next run', () {
    open().showSource(2);
    final next = open();
    expect(next.sourceFilter, 2);
    expect(titles(next), ['Вторая', 'Общая', 'Пятая']);
  });

  test('a source that leaves takes its filter with it', () {
    final library = open()..showSource(2);
    sources.value = [account(1, 'Мой'), account(3, 'Третий')];
    expect(library.sourceFilter, isNull);
    expect(library.visible.length, 5);
    expect(settings[LibraryController.sourceSetting], isNull);
  });

  test('with one source to choose from there is no filter', () {
    final library = open()..showSource(1);
    sources.value = [account(1, 'Мой'), account(2, 'Второй', songs: 0)];
    expect(library.filterSources.map((s) => s.id), [1]);
    expect(library.sourceFilter, isNull);
    expect(library.visible.length, 5);

    // A saved filter is not restored then either.
    settings[LibraryController.sourceSetting] = '1';
    expect(open().sourceFilter, isNull);
  });

  test('a renamed source keeps its filter', () {
    final library = open()..showSource(2);
    sources.value = [account(1, 'Мой'), account(2, 'Новое имя')];
    expect(library.sourceFilter, 2);
  });

  test('Back returns to the list before the filter changed', () {
    final library = open()..showSource(2);
    library.goBack();
    expect(library.sourceFilter, isNull);
    expect(library.visible.length, 5);
    library.goForward();
    expect(library.sourceFilter, 2);
    expect(titles(library), ['Вторая', 'Общая', 'Пятая']);
  });

  testWidgets('going to the playing song uses the filter it was played with', (
    tester,
  ) async {
    final library = open()..showSource(2);
    library.notePlayedFrom();
    library.showSource(1);
    library.goToSong(tracks[1]);
    expect(library.sourceFilter, 2);
    expect(library.jump.row, 0);

    // Saved with the list, so the next run goes back there too.
    final next = open()..showSource(1);
    next.goToSong(tracks[4]);
    expect(next.sourceFilter, 2);
    expect(next.jump.row, 2);
  });

  testWidgets('a song the filtered lists lack is shown in all songs', (
    tester,
  ) async {
    final library = open()..showSource(1);
    library.notePlayedFrom();
    library.goToSong(tracks[1]);
    expect(library.view, LibraryView.songs);
    expect(library.sourceFilter, isNull);
    expect(library.jump.row, 1);
  });

  screenTests();
}

/// The real screen over a library of two accounts, one song in both.
void screenTests() {
  group('on screen', () {
    late LibraryStore store;
    late LibraryController library;
    late ValueNotifier<List<SourceInfo>> sources;
    late int first;
    late int second;

    NewTrack vkSong(String key, String title, {int? trackId}) => NewTrack(
      sourceKey: key,
      artist: 'Земфира',
      title: title,
      durationSec: 200,
      addedAt: 0,
      vkTrackId: trackId,
    );

    setUp(() {
      store = LibraryStore.open(':memory:');
      first = store.ensureSource(TrackSource.vk, account: '1', name: 'Анна');
      second = store.ensureSource(TrackSource.vk, account: '2', name: 'Борис');
      store.upsertAll(first, [
        vkSong('1_1', 'Общая', trackId: 7),
        vkSong('1_2', 'Только первая'),
      ]);
      store.upsertAll(second, [
        vkSong('2_1', 'Общая', trackId: 7),
        vkSong('2_2', 'Только вторая'),
      ]);
      mergeSameFiles(store);
      sources = ValueNotifier(store.sources());
      library = LibraryController(store.loadAll())..watchSources(sources);
    });
    tearDown(() => store.close());

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: SourcesScope(
            sources: sources,
            child: LibraryScreen(
              library: library,
              playback: PlaybackController(
                player: PlayerService(muted: true, dataDir: '.'),
                recordPlay: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }

    testWidgets('a chip per account filters the list, All brings it back', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.text('3 songs'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-filter-all')), findsOneWidget);
      expect(find.text('Анна'), findsOneWidget);
      expect(find.text('Борис'), findsOneWidget);

      await tapKey(tester, 'source-filter-$second');
      expect(find.text('Только вторая'), findsOneWidget);
      expect(find.text('Общая'), findsOneWidget);
      expect(find.text('Только первая'), findsNothing);
      expect(find.text('2 songs'), findsOneWidget);

      // The chosen chip again shows every account, as All does.
      await tapKey(tester, 'source-filter-$second');
      expect(library.sourceFilter, isNull);
      await tapKey(tester, 'source-filter-$first');
      expect(find.text('Только вторая'), findsNothing);
      await tapKey(tester, 'source-filter-all');
      expect(find.text('3 songs'), findsOneWidget);
    });

    testWidgets('an empty filtered list says why', (tester) async {
      await pumpScreen(tester);
      await tapKey(tester, 'source-filter-$first');
      await tester.enterText(find.byType(TextField), 'вторая');
      await tester.pump();
      expect(find.text('No songs from Анна match "вторая"'), findsOneWidget);
    });

    testWidgets('with one account there are no chips', (tester) async {
      await pumpScreen(tester);
      sources.value = [sources.value.first];
      await tester.pump();
      expect(find.byKey(const ValueKey('source-filter')), findsNothing);
    });

    testWidgets('the chips fit the smallest window', (tester) async {
      sources.value = [
        for (final source in sources.value)
          SourceInfo(
            id: source.id,
            kind: source.kind,
            account: source.account,
            name: 'Очень длинное имя аккаунта ${source.id}',
            color: source.color,
            songCount: source.songCount,
            goneCount: 0,
          ),
      ];
      tester.view.physicalSize = const Size(480, 440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpScreen(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('source-filter')), findsOneWidget);
    });
  });
}
