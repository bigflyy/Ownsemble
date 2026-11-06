import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/mp3_length.dart';

/// The uploads VK's search found for a song are kept, so the song's
/// versions open at once (plan 03, A2).
void main() {
  late LibraryStore store;
  late int songId;
  setUp(() {
    store = LibraryStore.open(':memory:');
    final source = store.ensureSource(TrackSource.vk, account: '1', name: 'A');
    songId = store.upsertAll(source, [
      const NewTrack(
        sourceKey: '1_1',
        artist: 'Операция Пластилин',
        title: 'Ты и я',
        durationSec: 219,
        addedAt: 5,
      ),
    ]).single;
  });
  tearDown(() => store.close());

  test('a found list comes back in its order, Cyrillic intact', () {
    store.saveFoundVersions(songId, [
      const SongVersion(
        key: '1_1',
        artist: 'Операция Пластилин',
        title: 'Ты и я',
        listedSec: 219,
        isCurrentFile: true,
      ),
      const SongVersion(
        key: '5_9',
        accessKey: 'ak',
        artist: 'Операция Пластилин',
        title: 'Ты и я',
        album: 'Пластинки',
        albumKey: '-77_5',
        albumAccessKey: 'albumkey',
        coverUrl: 'https://example.invalid/135.jpg',
        coverLargeUrl: 'https://example.invalid/600.jpg',
        listedSec: 219,
        file: FileFacts(bytes: 8770917, seconds: 219.2),
        official: true,
        vkTrackId: 77,
      ),
      const SongVersion(
        key: '6_3',
        artist: 'Операция Пластилин',
        title: 'Ты и я (live)',
        listedSec: 226,
      ),
    ], atMs: 1000);

    final found = store.foundVersions(songId)!;
    expect(found.foundAtMs, 1000);
    // VK's current file for the row is not kept: its print says that.
    expect(found.versions.map((v) => v.key), ['5_9', '6_3']);
    final first = found.versions.first;
    expect(first.accessKey, 'ak');
    expect(first.album, 'Пластинки');
    expect(first.albumKey, '-77_5');
    expect(first.albumAccessKey, 'albumkey');
    expect(first.coverUrl, 'https://example.invalid/135.jpg');
    expect(first.coverLargeUrl, 'https://example.invalid/600.jpg');
    expect(first.file?.seconds, 219.2);
    expect(first.file?.bytes, 8770917);
    expect(first.official, isTrue);
    expect(first.vkTrackId, 77);
    expect(found.versions.last.title, 'Ты и я (live)');
    expect(found.versions.last.file, isNull);
  });

  test('a new search replaces the old list', () {
    store.saveFoundVersions(songId, [
      const SongVersion(key: '5_9', artist: 'a', title: 'b', listedSec: 1),
    ], atMs: 1);
    store.saveFoundVersions(songId, [
      const SongVersion(key: '7_7', artist: 'a', title: 'b', listedSec: 2),
    ], atMs: 2);
    final found = store.foundVersions(songId)!;
    expect(found.versions.map((v) => v.key), ['7_7']);
    expect(found.foundAtMs, 2);
  });

  test('a song never searched has no list', () {
    expect(store.foundVersions(songId), isNull);
    store.saveFoundVersions(12345, [
      const SongVersion(key: '5_9', artist: 'a', title: 'b', listedSec: 1),
    ]);
    expect(store.foundVersions(12345), isNull);
  });

  test("the row's print says how VK's file plays, for this length only", () {
    expect(store.printedFileOf(songId), isNull);
    store.savePrints({
      songId: const FilePrint(bytes: 9000000, sample: 3, seconds: 226.5),
    });
    expect(store.printedFileOf(songId)?.seconds, 226.5);
    expect(store.printedFileOf(songId)?.bytes, 9000000);
  });
}
