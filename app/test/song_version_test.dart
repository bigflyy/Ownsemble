import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/song_version.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/mp3_length.dart';
import 'package:ownsemble/playback/stream_route.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_versions.dart';

/// An upload as VK's search would give it, with its file measured.
SongVersion upload(
  String key, {
  int listed = 219,
  double? seconds,
  int? bytes,
  bool official = false,
  String title = 'Ты и я',
}) => SongVersion(
  key: key,
  artist: 'Операция Пластилин',
  title: title,
  listedSec: listed,
  file: seconds == null
      ? null
      : FileFacts(bytes: bytes ?? (seconds * 40000).round(), seconds: seconds),
  official: official,
);

/// The real case of 2026-11-04 (gate-2acc): the row lists 219 s, VK's file
/// for it is the 226.5 s official release, and three other uploads of the
/// same track_id are the 219 s recording.
List<SongVersion> realCase() => [
  upload('-1_1', listed: 226, seconds: 226.5, bytes: 9062443, official: true),
  upload('-1_2', listed: 227, seconds: 226.5, bytes: 9062443, official: true),
  upload('5_1', seconds: 219.3, bytes: 8774052),
  upload('6_1', seconds: 219.2, bytes: 8770917),
  upload('7_1', seconds: 219.2, bytes: 8770917),
  upload('8_1', seconds: 219.2, bytes: 8773007),
  upload('9_1', listed: 219), // no link: no file
];

void main() {
  group('uploads of the same song', () {
    test('the same track_id, or the same artist and title', () {
      bool same(String artist, String title, {int? trackId}) => isUploadOfSong(
        rowArtist: 'Операция Пластилин',
        rowTitle: 'Ты и Я',
        rowTrackId: 74440157,
        artist: artist,
        title: title,
        trackId: trackId,
      );
      expect(same('операция пластилин', 'Ты и я'), isTrue);
      expect(same('Операция  Пластилин!', 'ты и я', trackId: 1), isTrue);
      expect(same('Other', 'Song', trackId: 74440157), isTrue);
      expect(same('Операция Пластилин', 'Ты и я (live)'), isFalse);
      expect(same('Другая группа', 'Ты и я'), isFalse);
    });

    test('a search item becomes a version without its link', () {
      final version = versionFromItem({
        'owner_id': -2001,
        'id': 42,
        'access_key': 'abc',
        'artist': 'Операция Пластилин',
        'title': 'Ты и я',
        'duration': 219,
        'is_official': 1,
        'track_id': '74440157',
        'album': {'title': 'Волна'},
        'url': 'https://example.invalid/never-kept.mp3',
      });
      expect(version.key, '-2001_42');
      expect(version.accessKey, 'abc');
      expect(version.album, 'Волна');
      expect(version.official, isTrue);
      expect(version.vkTrackId, 74440157);
      expect(version.listedSec, 219);
    });
  });

  group('ranking', () {
    test('the listed length wins, then the most copies of one size', () {
      final ranked = rankVersions(219, realCase());
      // 8770917 bytes: two uploads share this file.
      expect(ranked.take(2).map((v) => v.key), unorderedEquals(['6_1', '7_1']));
      expect(ranked.take(4).every((v) => v.matches(219)), isTrue);
      expect(ranked.last.key, '9_1');
      expect(suggestedVersion(219, ranked)!.file!.bytes, 8770917);
    });

    test("VK's current file is never the suggestion", () {
      final current = SongVersion(
        key: '3_3',
        artist: 'a',
        title: 'b',
        listedSec: 219,
        file: const FileFacts(bytes: 1, seconds: 219.5),
        isCurrentFile: true,
      );
      expect(suggestedVersion(219, rankVersions(219, [current])), isNull);
    });

    test('nothing within 1 s: no suggestion, versions still listed', () {
      final ranked = rankVersions(219, [
        upload('1_1', seconds: 221.0),
        upload('2_2', seconds: 226.5),
      ]);
      expect(suggestedVersion(219, ranked), isNull);
      expect(ranked.first.key, '1_1');
    });
  });

  group('the version book', () {
    late LibraryStore store;
    late Track song;
    late StreamRoute route;
    var found = <SongVersion>[];
    Object? searchFails;
    var searches = 0;

    VersionBook book({bool persist = true}) => VersionBook(
      store: store,
      persist: persist,
      find: (track, route) async {
        searches++;
        if (searchFails != null) throw searchFails!;
        return found;
      },
      measure: (route) async => const FileFacts(bytes: 9062443, seconds: 226.5),
      now: () => 1000,
    );

    setUp(() {
      store = LibraryStore.open(':memory:');
      final source = store.ensureSource(
        TrackSource.vk,
        account: '1',
        name: 'VK',
      );
      store.upsertTracks(source, [
        const NewTrack(
          sourceKey: '1_10788',
          artist: 'Операция Пластилин',
          title: 'Ты и я',
          durationSec: 219,
          addedAt: 1,
        ),
      ]);
      song = store.loadAll().single;
      route = StreamRoute(
        sourceId: source,
        client: VkClient(const []),
        sourceKey: '1_10788',
      );
      found = realCase();
      searchFails = null;
      searches = 0;
    });

    tearDown(() => store.close());

    const swapped = FileFacts(bytes: 9062443, seconds: 226.5);

    test('a swapped song gets the suggested match, stored', () async {
      final versions = book();
      final choice = await versions.decide(song, route, swapped);
      expect(searches, 1);
      expect(choice.state, VersionState.suggested);
      expect(choice.fileSeconds, closeTo(219.2, 0.01));
      expect(choice.expectSeconds, closeTo(219.2, 0.01));
      expect(choice.ownSeconds, 226.5);
      expect(versions.choiceFor(song)!.fileKey, choice.fileKey);
      // A new run reads it back.
      final again = book().choiceFor(song)!;
      expect(again.state, VersionState.suggested);
      expect(again.fileKey, choice.fileKey);
      expect(again.ownBytes, 9062443);
    });

    test('with nothing that matches, VK\'s file plays marked', () async {
      found = [upload('2_2', seconds: 226.5)];
      final choice = await book().decide(song, route, swapped);
      expect(choice.state, VersionState.none);
      expect(choice.playsOwnFile, isTrue);
      expect(choice.expectSeconds, 226.5);
      expect(versionMark(choice)!.label, 'different recording');
    });

    test('a failed search plays VK\'s file this run only', () async {
      searchFails = VkException('audio.search error 10', transient: true);
      final versions = book();
      final choice = await versions.decide(song, route, swapped);
      expect(choice.state, VersionState.none);
      expect(versions.choiceFor(song), isNotNull);
      expect(book().choiceFor(song), isNull);
    });

    test('the user picks a version, can change it and reset', () async {
      final versions = book();
      await versions.decide(song, route, swapped);
      final listed = await versions.versionsOf(song, route);
      final current = listed.singleWhere((v) => v.isCurrentFile);
      expect(current.file!.seconds, 226.5);
      versions.pick(song, current);
      expect(book().choiceFor(song)!.state, VersionState.picked);
      expect(book().choiceFor(song)!.expectSeconds, 226.5);
      expect(versionMark(book().choiceFor(song))!.label, 'your version');
      versions.reset(song);
      expect(versions.choiceFor(song), isNull);
      expect(book().choiceFor(song), isNull);
    });

    test('a sync that lists another length makes the choice stale', () async {
      await book().decide(song, route, swapped);
      final source = song.sourceId;
      store.upsertTracks(source, [
        const NewTrack(
          sourceKey: '1_10788',
          artist: 'Операция Пластилин',
          title: 'Ты и я',
          durationSec: 226,
          addedAt: 1,
        ),
      ]);
      final relisted = store.loadAll().single;
      expect(book().choiceFor(relisted), isNull);
    });

    test('reload takes over what the background check stored', () async {
      final versions = book();
      expect(versions.choiceFor(song), isNull);
      var notified = 0;
      versions.addListener(() => notified++);
      // The check after a sync stores a choice through its own connection.
      store.saveVersionChoice(
        decideVersion(
          trackId: song.id,
          listedSec: 219,
          ownSeconds: 226.5,
          ownBytes: 9062443,
          found: realCase(),
          nowMs: 5,
        ),
      );
      versions.reload();
      expect(notified, 1);
      expect(versions.choiceFor(song)!.state, VersionState.suggested);

      // VK gave the file back: the check forgot it, and so does the book.
      store.removeVersionChoice(song.id);
      versions.reload();
      expect(versions.choiceFor(song), isNull);

      // A choice kept only for this run (the search failed) stays.
      searchFails = VkException('audio.search error 10', transient: true);
      await versions.decide(song, route, swapped);
      versions.reload();
      expect(versions.choiceFor(song), isNotNull);
    });

    test('the speed gate keeps its data unchanged', () async {
      final versions = book(persist: false);
      await versions.decide(song, route, swapped);
      expect(versions.choiceFor(song), isNotNull);
      expect(book().choiceFor(song), isNull);
    });

    test('a song outside the library is never checked', () {
      const outside = Track(
        id: -3,
        sourceId: 1,
        source: TrackSource.vk,
        artist: 'a',
        title: 'b',
        durationSec: 1,
      );
      expect(book().choiceFor(outside), isNull);
    });

    test('the mark says it is looking while it searches', () {
      expect(versionMark(null, searching: true)!.label, 'finding version');
      expect(versionMark(null), isNull);
    });
  });
}
