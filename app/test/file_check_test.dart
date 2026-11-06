import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/mp3_length.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/sync/file_check.dart';

/// Stage M2: the background check of every song's VK file after a sync.
void main() {
  late LibraryStore store;
  late int vk;
  var now = 1000000000;

  /// What VK's file for each song key plays now, in seconds; a key that is
  /// missing has no file.
  late Map<String, double> files;

  /// What VK's search finds for each listed title.
  late Map<String, List<SongVersion>> uploads;
  late List<String> searched;
  late List<List<int>> readBatches;
  Object? searchFails;

  FilePrint printOf(String key) {
    final seconds = files[key];
    if (seconds == null) return const FilePrint.noFile();
    return FilePrint(
      bytes: (seconds * 40000).round(),
      sample: key.hashCode,
      seconds: seconds,
    );
  }

  Future<FileCheckOutcome> check({Set<int>? reachable}) => checkFiles(
    store: store,
    reachable: reachable ?? {vk},
    readPrints: (sourceId, rows) async {
      readBatches.add([for (final row in rows) row.trackId]);
      return {for (final row in rows) row.trackId: printOf(row.sourceKey)};
    },
    findVersions: (song) async {
      searched.add(song.title);
      if (searchFails != null) throw searchFails!;
      return uploads[song.title] ?? const [];
    },
    now: () => now,
  );

  SongVersion upload(String key, String title, double seconds) => SongVersion(
    key: key,
    artist: 'Сплин',
    title: title,
    listedSec: seconds.round(),
    file: FileFacts(bytes: (seconds * 40000).round(), seconds: seconds),
  );

  Track song(String title) =>
      store.loadAll().firstWhere((t) => t.title == title);

  setUp(() {
    store = LibraryStore.open(':memory:');
    vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertTracks(vk, const [
      NewTrack(
        sourceKey: '1_1',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 236,
        addedAt: 3,
      ),
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Романс',
        durationSec: 219,
        addedAt: 2,
      ),
      NewTrack(
        sourceKey: '1_3',
        artist: 'Сплин',
        title: 'Орбит без сахара',
        durationSec: 200,
        addedAt: 1,
      ),
    ]);
    files = {'1_1': 236.4, '1_2': 226.5};
    uploads = {
      'Романс': [
        upload('5_1', 'Романс', 219.2),
        upload('6_1', 'Романс', 226.5),
      ],
    };
    searched = [];
    readBatches = [];
    searchFails = null;
  });
  tearDown(() => store.close());

  test(
    'every listed VK song is read once, newest first, then is fresh',
    () async {
      expect(
        [for (final row in store.filesToCheck(nowMs: now)) row.sourceKey],
        ['1_1', '1_2', '1_3'],
      );
      final outcome = await check();
      expect(outcome.checked, 3);
      expect(store.filesToCheck(nowMs: now), isEmpty);

      // A week later the files are read again; a song with no file a day later.
      expect(
        [
          for (final row in store.filesToCheck(
            nowMs: now + const Duration(days: 1).inMilliseconds,
          ))
            row.sourceKey,
        ],
        ['1_3'],
      );
      expect(
        store.filesToCheck(nowMs: now + const Duration(days: 7).inMilliseconds),
        hasLength(3),
      );
    },
  );

  test('a swapped song gets its version before it is played', () async {
    final outcome = await check();
    expect(outcome.swapped, 1);
    expect(outcome.decided, 1);
    expect(searched, ['Романс']);
    final choice = store.versionChoices()[song('Романс').id]!;
    expect(choice.state, VersionState.suggested);
    expect(choice.fileKey, '5_1');
    expect(choice.ownSeconds, 226.5);
    expect(choice.listedSec, 219);
    // The uploads found are kept, so the song's versions open at once.
    expect(
      store.foundVersions(song('Романс').id)?.versions.map((v) => v.key),
      contains('5_1'),
    );

    // The app's book reads it, so the row is tagged.
    final shared = VersionBook(
      store: store,
      find: (track, route, progress) async => const [],
      measure: (route) async => null,
    );
    expect(shared.choiceFor(song('Романс'))!.state, VersionState.suggested);

    // Nothing left to do on the next sync.
    searched.clear();
    final again = await check();
    expect(again.checked, 0);
    expect(searched, isEmpty);
  });

  test(
    'a song with no matching upload is marked as another recording',
    () async {
      uploads = {};
      await check();
      final choice = store.versionChoices()[song('Романс').id]!;
      expect(choice.state, VersionState.none);
      expect(choice.playsOwnFile, isTrue);
    },
  );

  test(
    'a failed search stores nothing and is tried on the next sync',
    () async {
      searchFails = StateError('VK said no');
      final outcome = await check();
      expect(outcome.swapped, 1);
      expect(outcome.decided, 0);
      expect(outcome.failed, 1);
      expect(store.versionChoices(), isEmpty);

      searchFails = null;
      searched.clear();
      final again = await check();
      expect(again.checked, 0);
      expect(searched, ['Романс']);
      expect(store.versionChoices(), hasLength(1));
    },
  );

  test(
    'VK fixing the file drops the automatic choice, not the user\'s',
    () async {
      await check();
      final romance = song('Романс');
      // The user also picked a version of Выхода нет.
      final book = VersionBook(
        store: store,
        find: (track, route, progress) async => const [],
        measure: (route) async => null,
      );
      book.pick(song('Выхода нет'), upload('7_1', 'Выхода нет', 236));

      files['1_2'] = 219.1;
      now += const Duration(days: 8).inMilliseconds;
      await check();
      expect(store.versionChoices().containsKey(romance.id), isFalse);
      expect(
        store.versionChoices()[song('Выхода нет').id]!.state,
        VersionState.picked,
      );
    },
  );

  test('a picked version is never searched again', () async {
    await check();
    final book = VersionBook(
      store: store,
      find: (track, route, progress) async => const [],
      measure: (route) async => null,
    );
    book.pick(song('Романс'), upload('6_1', 'Романс', 226.5));
    now += const Duration(days: 8).inMilliseconds;
    searched.clear();
    await check();
    expect(searched, isEmpty);
    expect(store.versionChoices()[song('Романс').id]!.fileKey, '6_1');
  });

  test('a new listed length checks the song again', () async {
    await check();
    store.upsertTracks(vk, const [
      NewTrack(
        sourceKey: '1_2',
        artist: 'Сплин',
        title: 'Романс',
        durationSec: 226,
        addedAt: 2,
      ),
    ]);
    expect(
      [for (final row in store.filesToCheck(nowMs: now)) row.sourceKey],
      ['1_2'],
    );
    searched.clear();
    await check();
    // 226.5 s for 226 s listed: the song is not swapped any more.
    expect(searched, isEmpty);
    expect(store.versionChoices().containsKey(song('Романс').id), isFalse);
  });

  test('songs of an account that did not connect wait', () async {
    final outcome = await check(reachable: {});
    expect(outcome.checked, 0);
    expect(readBatches, isEmpty);
    expect(store.filesToCheck(nowMs: now), hasLength(3));
  });

  test('a removed account and a merged copy are not checked', () async {
    final second = store.ensureSource(TrackSource.vk, account: '2', name: 'B');
    store.upsertTracks(second, const [
      NewTrack(
        sourceKey: '2_9',
        artist: 'Сплин',
        title: 'Выхода нет',
        durationSec: 236,
        addedAt: 4,
      ),
    ]);
    // The second account's copy is VK's same file: merged into the first.
    final rows = store.printsToRead(nowMs: now);
    store.savePrints({
      for (final row in rows)
        row.trackId: const FilePrint(bytes: 1, sample: 1, seconds: 236.4),
    }, atMs: now);
    store.mergeSameSongs();
    expect(store.loadAll(), hasLength(3));
    expect(
      [for (final row in store.filesToCheck(nowMs: now)) row.sourceKey],
      ['1_2', '1_3'],
    );
    store.removeSource(second);
    expect(store.filesToCheck(nowMs: now), hasLength(2));
  });

  test('progress counts the files, then the searches', () async {
    final steps = <FileCheckProgress>[];
    await checkFiles(
      store: store,
      reachable: {vk},
      readPrints: (sourceId, rows) async => {
        for (final row in rows) row.trackId: printOf(row.sourceKey),
      },
      findVersions: (song) async => uploads[song.title] ?? const [],
      onProgress: steps.add,
      now: () => now,
    );
    expect(steps.first.searching, isFalse);
    expect(steps.first.total, 3);
    expect(steps.where((s) => !s.searching).last.done, 3);
    expect(steps.last.searching, isTrue);
    expect(steps.last.done, 1);
    expect(steps.last.total, 1);
  });

  test('a swapped song is listed for the search with all its keys', () async {
    final second = store.ensureSource(TrackSource.vk, account: '2', name: 'B');
    store.upsertTracks(second, const [
      NewTrack(
        sourceKey: '2_7',
        artist: 'Сплин',
        title: 'Романс',
        durationSec: 219,
        addedAt: 4,
      ),
    ]);
    store.savePrints({
      for (final row in store.printsToRead(nowMs: now))
        row.trackId: const FilePrint(bytes: 9, sample: 9, seconds: 226.5),
    }, atMs: now);
    store.mergeSameSongs();
    final rows = store.swappedToDecide();
    expect(rows, hasLength(1));
    final swapped = rows.single;
    expect(swapped.title, 'Романс');
    expect(swapped.artist, 'Сплин');
    expect(swapped.listedSec, 219);
    expect(swapped.ownSeconds, 226.5);
    expect(swapped.ownKeys, {'1_2', '2_7'});
  });
}
