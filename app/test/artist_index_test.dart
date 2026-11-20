// Tests for plan 09 C2: which stored artists a listed song has (review R9)
// and how ArtistIndex groups the library's songs by artist (ids, featured
// artists, songs without an id, spellings, counts, sorts; review R4, R5).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/artist_credit.dart';
import 'package:ownsemble/library/artist_index.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/play_stats.dart';
import 'package:ownsemble/library/song_generator.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_sync.dart';

import 'merge_support.dart';

const tank = ArtistCredit(vkId: '111', name: 'Дайте танк (!)', domain: 'tank');
const tankOther = ArtistCredit(vkId: '111', name: 'ДАЙТЕ ТАНК (!)');
const rita = ArtistCredit(vkId: '222', name: 'Рита Вихрия', featured: true);
const ritaMain = ArtistCredit(vkId: '222', name: 'Рита Вихрия');
const namesake = ArtistCredit(vkId: '333', name: 'Кино');
const namesake2 = ArtistCredit(vkId: '334', name: 'Кино');

var _nextId = 1;

/// A listed song with row id [id] (or the next one).
Track song(
  String artist, {
  int? id,
  String title = 'Песня',
  String? album,
  int addedAt = 0,
  int? tint,
}) => Track(
  id: id ?? _nextId++,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: title,
  album: album,
  durationSec: 200,
  addedAt: addedAt,
  tint: tint,
);

void main() {
  group('the artists of a listed song (R9)', () {
    late LibraryStore store;
    late int first;
    late int second;
    setUp(() {
      store = LibraryStore.open(':memory:');
      first = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
      second = store.ensureSource(TrackSource.vk, account: '2', name: 'VK');
    });
    tearDown(() => store.close());

    NewTrack credited(String key, List<ArtistCredit> artists) => NewTrack(
      sourceKey: key,
      artist: 'Дайте танк (!)',
      title: 'Утро',
      durationSec: 200,
      addedAt: 0,
      vkTrackId: 7,
      artists: artists,
    );

    test('a song in one account has its own row\'s artists', () {
      final a = store.upsertAll(first, [
        credited('1_1', [tank, rita]),
      ]).single;
      expect(store.songArtistCredits(), {
        a: [tank, rita],
      });
    });

    test('a merged song has its listed row\'s artists only, never a mix', () {
      final a = store.upsertAll(first, [
        credited('1_1', [tank]),
      ]).single;
      store.upsertAll(second, [
        credited('2_1', [namesake]),
      ]);
      mergeSameFiles(store);
      expect(store.loadAll().single.id, a);
      expect(store.songArtistCredits(), {
        a: [tank],
      });
    });

    test('a listed row with no artists takes its copy\'s', () {
      final a = store.upsertAll(first, [credited('1_1', const [])]).single;
      store.upsertAll(second, [
        credited('2_1', [tank]),
      ]);
      mergeSameFiles(store);
      expect(store.songArtistCredits(), {
        a: [tank],
      });
    });

    test('when the listed row\'s own copy is removed, its copy\'s artists '
        'count', () {
      final a = store.upsertAll(first, [
        credited('1_1', [namesake]),
      ]).single;
      store.upsertAll(second, [
        credited('2_1', [tank]),
      ]);
      mergeSameFiles(store);
      store.markRemoved(first, ['1_1']);
      final listed = store.loadAll().single;
      expect(listed.id, a);
      expect(listed.ownRemoved, isTrue);
      expect(store.songArtistCredits(), {
        a: [tank],
      });
    });

    test('a certain copy wins over a likely one', () {
      final third = store.ensureSource(
        TrackSource.vk,
        account: '3',
        name: 'VK',
      );
      final a = store.upsertAll(first, [credited('1_1', const [])]).single;
      final b = store.upsertAll(second, [
        credited('2_1', [namesake]),
      ]).single;
      final c = store.upsertAll(third, [
        credited('3_1', [tank]),
      ]).single;
      const fileA = FilePrint(bytes: 8770917, sample: 11, seconds: 200.2);
      const fileB = FilePrint(bytes: 8774052, sample: 22, seconds: 200.4);
      store.savePrints({a: fileA, b: fileB, c: fileA});
      store.writeSetting(LibraryStore.mergeLikelySetting, 'on');
      store.mergeSameSongs();
      final listed = store.loadAll().single;
      expect(listed.id, a);
      expect(
        listed.copies.firstWhere((x) => x.sourceId == second).likely,
        isTrue,
      );
      expect(store.songArtistCredits(), {
        a: [tank],
      });
    });

    test("removing the listed row's account: the copy that takes its place "
        'keeps its own artists', () {
      store.upsertAll(first, [
        credited('1_1', [namesake]),
      ]);
      final b = store.upsertAll(second, [
        credited('2_1', [tank]),
      ]).single;
      mergeSameFiles(store);
      store.removeSource(first);
      final listed = store.loadAll().single;
      expect(listed.id, b);
      expect(store.songArtistCredits(), {
        b: [tank],
      });
    });

    test('album keys: the listed row first, else a copy', () {
      NewTrack inAlbum(String key, String? album) => NewTrack(
        sourceKey: key,
        artist: 'Дайте танк (!)',
        title: 'Утро',
        durationSec: 200,
        addedAt: 0,
        vkTrackId: 7,
        vkAlbumKey: album,
      );
      final a = store.upsertAll(first, [inAlbum('1_1', null)]).single;
      store.upsertAll(second, [inAlbum('2_1', '-5_9')]);
      mergeSameFiles(store);
      expect(store.listedVkAlbumKeys(), {a: '-5_9'});
      store.updateQuietDetails(first, [inAlbum('1_1', '-5_8')]);
      expect(store.listedVkAlbumKeys(), {a: '-5_8'});
    });

    test('an unmerged copy has its own artists again', () {
      final a = store.upsertAll(first, [
        credited('1_1', [tank]),
      ]).single;
      final b = store.upsertAll(second, [
        credited('2_1', [namesake]),
      ]).single;
      mergeSameFiles(store);
      expect(store.songArtistCredits().keys, [a]);
      store.savePrints({
        b: const FilePrint(bytes: 9062443, sample: 33, seconds: 207.5),
      });
      expect(store.mergeSameSongs().unmerged, 1);
      expect(store.songArtistCredits(), {
        a: [tank],
        b: [namesake],
      });
    });
  });

  group('grouping', () {
    test('by VK id: two spellings are one artist, shown as the commoner', () {
      final a = song('Дайте танк (!)');
      final b = song('ДАЙТЕ ТАНК (!)');
      final c = song('Дайте танк (!)');
      final index = ArtistIndex.build(
        [a, b, c],
        {
          a.id: [tank],
          b.id: [tankOther],
          c.id: [tank],
        },
      );
      expect(index.length, 1);
      final artist = index['vk:111']!;
      expect(artist.name, 'Дайте танк (!)');
      expect(artist.domain, 'tank');
      expect(artist.nameOnly, isFalse);
      expect(artist.songs, [a, b, c]);
    });

    test('a tie of spellings goes to the newest song (listed first)', () {
      final newer = song('ДАЙТЕ ТАНК (!)');
      final older = song('Дайте танк (!)');
      final index = ArtistIndex.build(
        [newer, older],
        {
          newer.id: [tankOther],
          older.id: [tank],
        },
      );
      expect(index['vk:111']!.name, 'ДАЙТЕ ТАНК (!)');
    });

    test('one name with two ids is two artists', () {
      final a = song('Кино');
      final b = song('Кино');
      final index = ArtistIndex.build(
        [a, b],
        {
          a.id: [namesake],
          b.id: [namesake2],
        },
      );
      expect(index.length, 2);
      expect(index['vk:333']!.songs, [a]);
      expect(index['vk:334']!.songs, [b]);
    });

    test('a song is under each main and featured artist, main first', () {
      final a = song('Дайте танк (!) feat. Рита Вихрия');
      final index = ArtistIndex.build(
        [a],
        {
          a.id: [tank, rita],
        },
      );
      expect(index.artistsOf(a.id).map((x) => x.key), ['vk:111', 'vk:222']);
      expect(index['vk:222']!.songs, [a]);
      expect(index['vk:222']!.name, 'Рита Вихрия');
    });

    test('a song naming one artist twice counts once', () {
      final a = song('Рита Вихрия');
      final index = ArtistIndex.build(
        [a],
        {
          a.id: [ritaMain, rita],
        },
      );
      expect(index['vk:222']!.songs, [a]);
      expect(index.artistsOf(a.id), hasLength(1));
    });

    test('a song with no id joins the one VK artist of that name, in any '
        'case, with yo as ye and any spaces', () {
      const yolka = ArtistCredit(vkId: '444', name: 'Ёлка');
      final known = song('Дайте танк (!)');
      final plain = song('дайте   ТАНК (!)');
      final singer = song('Ёлка');
      final loose = song('елка');
      final index = ArtistIndex.build(
        [known, plain, singer, loose],
        {
          known.id: [tank],
          singer.id: [yolka],
        },
      );
      expect(index.length, 2);
      expect(index['vk:111']!.songs, [known, plain]);
      expect(index.artistsOf(plain.id).single.key, 'vk:111');
      // Its spelling counts too: one each, so the newer song's wins.
      expect(index['vk:111']!.name, 'Дайте танк (!)');
      expect(index['vk:444']!.songs, [singer, loose]);
    });

    test('punctuation keeps names apart: no join without VK (C2 review)', () {
      const plus = ArtistCredit(vkId: '601', name: 'A+');
      const four = ArtistCredit(vkId: '602', name: '4');
      final known = song('Дайте танк (!)');
      final bare = song('Дайте танк');
      final aPlus = song('A+');
      final a = song('A');
      final number = song('4');
      final broken = song('???4???');
      final index = ArtistIndex.build(
        [known, bare, aPlus, a, number, broken],
        {
          known.id: [tank],
          aPlus.id: [plus],
          number.id: [four],
        },
      );
      expect(index.artistsOf(bare.id).single.key, 'name:дайте танк');
      expect(index.artistsOf(a.id).single.key, 'name:a');
      expect(index.artistsOf(broken.id).single.key, 'name:???4???');
      expect(index['vk:602']!.songs, [number]);
    });

    test('a name two ids share joins neither: a name-only artist', () {
      final a = song('Кино');
      final b = song('Кино');
      final loose = song('КИНО');
      final index = ArtistIndex.build(
        [a, b, loose],
        {
          a.id: [namesake],
          b.id: [namesake2],
        },
      );
      expect(index.length, 3);
      final only = index['name:кино']!;
      expect(only.nameOnly, isTrue);
      expect(only.songs, [loose]);
      expect(only.name, 'КИНО');
    });

    test('the text without its featured part joins when the whole text '
        'names no artist (R4)', () {
      final known = song('Дайте танк (!)');
      for (final text in [
        'Дайте танк (!) feat. Кто-то',
        'Дайте танк (!) ft. Кто-то',
        'Дайте танк (!) Featuring Кто-то',
        'Дайте танк (!) (feat. Кто-то)',
      ]) {
        final loose = song(text);
        final index = ArtistIndex.build(
          [known, loose],
          {
            known.id: [tank],
          },
        );
        expect(index.length, 1, reason: text);
        expect(index['vk:111']!.songs, [known, loose], reason: text);
      }
    });

    test('a whole text VK knows wins over its cut; an unknown one is a '
        'name-only artist by the WHOLE text', () {
      const duo = ArtistCredit(vkId: '555', name: 'Tank feat. Rita');
      const solo = ArtistCredit(vkId: '556', name: 'Tank');
      final a = song('Tank feat. Rita');
      final b = song('Tank');
      final loose = song('tank feat. rita');
      final other = song('Nobody feat. Tank');
      final index = ArtistIndex.build(
        [a, b, loose, other],
        {
          a.id: [duo],
          b.id: [solo],
        },
      );
      expect(index.artistsOf(loose.id).single.key, 'vk:555');
      expect(index.artistsOf(other.id).single.key, 'name:nobody feat. tank');
    });

    test('a join is computed, never kept: a second namesake undoes it', () {
      final a = song('Кино');
      final loose = song('Кино');
      final once = ArtistIndex.build(
        [a, loose],
        {
          a.id: [namesake],
        },
      );
      expect(once.artistsOf(loose.id).single.key, 'vk:333');
      final b = song('Кино');
      final twice = ArtistIndex.build(
        [a, loose, b],
        {
          a.id: [namesake],
          b.id: [namesake2],
        },
      );
      expect(twice.artistsOf(loose.id).single.key, 'name:кино');
    });

    test('a song with no artist text is under no artist', () {
      final a = song('  ');
      final index = ArtistIndex.build([a], {});
      expect(index.length, 0);
      expect(index.artistsOf(a.id), isEmpty);
    });

    test('albums with counts, newest added and the tint of the newest song '
        'that has one', () {
      final a = song('Дайте танк (!)', album: 'Человеко-часы', addedAt: 30);
      final b = song(
        'Дайте танк (!)',
        album: 'Человеко-часы',
        addedAt: 20,
        tint: 0xFF112233,
      );
      final c = song('Дайте танк (!)', album: 'Глаза', addedAt: 10);
      final d = song('Дайте танк (!)', addedAt: 5);
      final index = ArtistIndex.build(
        [a, b, c, d],
        {
          for (final x in [a, b, c, d]) x.id: [tank],
        },
      );
      final artist = index['vk:111']!;
      expect(
        [for (final album in artist.albums) (album.title, album.songs)],
        [('Человеко-часы', 2), ('Глаза', 1)],
      );
      expect(artist.albums.first.first, a);
      expect(artist.albums.first.artist, 'Дайте танк (!)');
      expect(artist.newestAddedAt, 30);
      expect(artist.tint, 0xFF112233);
    });

    test("albums go by VK's album key when songs have one, as the album "
        'place opens them (C2 review)', () {
      final solo = song('Дайте танк (!)', album: 'Человеко-часы');
      final duet = song(
        'Дайте танк (!) feat. Рита Вихрия',
        album: 'Человеко-часы',
      );
      final first = song('Дайте танк (!)', album: 'Демо');
      final second = song('Дайте танк (!)', album: 'Демо');
      final index = ArtistIndex.build(
        [solo, duet, first, second],
        {
          solo.id: [tank],
          duet.id: [tank, rita],
          first.id: [tank],
          second.id: [tank],
        },
        albumKeys: {
          solo.id: '-5_9',
          duet.id: '-5_9',
          first.id: '-5_10',
          second.id: '-5_11',
        },
      );
      final albums = index['vk:111']!.albums;
      expect(
        [
          for (final album in albums)
            (album.title, album.vkAlbumKey, album.songs),
        ],
        [
          ('Человеко-часы', '-5_9', 2),
          ('Демо', '-5_10', 1),
          ('Демо', '-5_11', 1),
        ],
      );
      expect(albums.first.first, solo);
      // The featured artist has the release once, with its one song.
      expect([for (final album in index['vk:222']!.albums) album.songs], [1]);
    });

    test('per-song credits keep their spelling and role for name links', () {
      final a = song('ДАЙТЕ ТАНК (!) feat. Рита Вихрия');
      final b = song('Дайте танк (!)');
      final c = song('Дайте танк (!)');
      final index = ArtistIndex.build(
        [a, b, c],
        {
          a.id: [tankOther, rita],
          b.id: [tank],
          c.id: [tank],
        },
      );
      expect(index.creditsOf(a.id), [tankOther, rita]);
      expect(
        index['vk:${index.creditsOf(a.id).first.vkId}']!.name,
        'Дайте танк (!)',
      );
      expect(index.creditsOf(-1), isEmpty);
    });
  });

  group('sorting', () {
    late Track a1, a2, a3, b1, c1;
    late ArtistIndex index;
    setUp(() {
      a1 = song('Альфа', addedAt: 10);
      a2 = song('Альфа', addedAt: 11);
      a3 = song('Альфа', addedAt: 12);
      b1 = song('beta', addedAt: 50);
      c1 = song('Гамма', addedAt: 30);
      index = ArtistIndex.build([a1, a2, a3, b1, c1], {});
    });
    List<String> names(ArtistSort sort, [Map<int, SongPlays>? plays]) => [
      for (final artist in index.sorted(sort, plays: plays ?? const {}))
        artist.name,
    ];

    test('Most songs, then name', () {
      expect(names(ArtistSort.mostSongs), ['Альфа', 'beta', 'Гамма']);
    });

    test('A-Z ignores case', () {
      expect(names(ArtistSort.name), ['beta', 'Альфа', 'Гамма']);
    });

    test('Recently added', () {
      expect(names(ArtistSort.recentlyAdded), ['beta', 'Гамма', 'Альфа']);
    });

    test('Most heard adds up counted plays, then the last heard', () {
      SongPlays plays(int count, int last) =>
          SongPlays(plays: count, listenedMs: 0, lastMs: last);
      final heard = {
        a1.id: plays(1, 100),
        a2.id: plays(1, 900),
        c1.id: plays(2, 500),
      };
      expect(names(ArtistSort.mostHeard, heard), ['Альфа', 'Гамма', 'beta']);
      expect(index['name:альфа']!.heard(heard), (
        plays: 2,
        listenedMs: 0,
        lastMs: 900,
      ));
      expect(index['name:beta']!.heard(heard), (
        plays: 0,
        listenedMs: 0,
        lastMs: null,
      ));
      // A new counted play shows the next time it is asked (R5).
      heard[b1.id] = plays(3, 1000);
      expect(names(ArtistSort.mostHeard, heard).first, 'beta');
    });
  });

  test('a real artist page (scrubbed fixture): every song under the '
      "artist's id, featured artists too", () {
    final reply = jsonDecode(
      File('test/fixtures/vk_artists/audio_get_audios_by_artist.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final songs = [
      for (final item in reply['items'] as List)
        vkItemToTrack(item as Map<String, dynamic>),
    ];
    final tracks = [
      for (final (i, s) in songs.indexed) song(s.artist, id: 10000 + i),
    ];
    final index = ArtistIndex.build(tracks, {
      for (final (i, s) in songs.indexed) 10000 + i: s.artists,
    });
    final main = index['vk:10000']!;
    expect(main.songs, hasLength(100));
    expect(main.name, songs.first.artists.first.name);
    expect(index.length, greaterThan(1));
    for (final artist in index.artists) {
      expect(artist.nameOnly, isFalse);
    }
  });

  test('the generator gives seven of ten artists an id', () {
    final songs = generateSongs(1200);
    final credited = songs.where((s) => s.artists.isNotEmpty).toList();
    expect(credited.length / songs.length, closeTo(0.7, 0.08));
    for (final s in credited) {
      expect(s.artists.single.name, s.artist);
    }
    // One id per artist text.
    final idOf = <String, String>{};
    for (final s in credited) {
      expect(
        idOf.putIfAbsent(s.artist, () => s.artists.single.vkId),
        s.artists.single.vkId,
      );
    }
  });
}
