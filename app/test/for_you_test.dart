// The For you place's data (plan 07, C2): the cache that opens it at once,
// refreshing only the lists VK rewrote, keeping what it had when VK fails,
// VK Mix, similar songs and the dislike, against the recorded VK replies.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/vk/vk_client.dart';

import 'recs_support.dart';

const _account = SourceInfo(
  id: 3,
  kind: TrackSource.vk,
  account: 'test',
  name: 'Test',
  songCount: 126,
  goneCount: 0,
);

void main() {
  late Directory dir;
  late RecsVk vk;
  var now = DateTime(2026, 11, 17, 12);
  final logs = <String>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('for_you_test');
    vk = RecsVk();
    now = DateTime(2026, 11, 17, 12);
    logs.clear();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ForYou make({RecsVk? fake, Track? Function(NewTrack)? copyOf}) => ForYou(
    accounts: () => [_account],
    apiOfSource: (id) => id == _account.id ? (fake ?? vk).call : null,
    libraryCopyOfSong: copyOf ?? (_) => null,
    cacheDir: dir.path,
    log: logs.add,
    now: () => now,
  );

  List<String> listReads(RecsVk fake) =>
      fake.calls.where((c) => c.startsWith('audio.get ')).toList();

  test('the first open asks VK: the page and the seven lists', () async {
    final forYou = make();
    forYou.open();
    await Future<void>.microtask(() {});
    expect(forYou.refreshing, isTrue);
    expect(forYou.hasLists, isFalse);
    await forYou.refresh();
    expect(forYou.hasLists, isTrue);
    expect(forYou.lists, hasLength(7));
    expect(listReads(vk), hasLength(7));
    expect(forYou.songsOf(forYou.lists.first.key), hasLength(12));
    expect(forYou.similar.single.songs, hasLength(18));
    expect(logs.last, contains('7 of 7 lists read'));
  });

  test('the cache keeps no stream link and opens the place at once', () async {
    await make().refresh();
    final text = File('${dir.path}/for-you.json').readAsStringSync();
    expect(text, isNot(contains('"url"')));
    expect(text, isNot(contains('.mp3')));
    expect(text, contains('Закрой за мной дверь'), reason: 'Cyrillic kept');

    now = now.add(const Duration(minutes: 5));
    final again = RecsVk();
    final next = make(fake: again)..open();
    expect(next.hasLists, isTrue);
    expect(next.lists.first.title, 'For you');
    expect(next.songsOf(next.lists.first.key), hasLength(12));
    expect(next.refreshing, isFalse, reason: 'fresh: VK is not asked');
    expect(again.calls, isEmpty);
  });

  test('a stale cache reads again only the lists VK rewrote', () async {
    await make().refresh();
    now = now.add(const Duration(hours: 3));
    final page = recFixture('catalog_get_audio') as Map<String, dynamic>;
    final generated = (page['playlists'] as List)
        .cast<Map<String, dynamic>>()
        .where((p) => p['type'] == 'generated')
        .toList();
    generated[3]['update_time'] = (generated[3]['update_time'] as int) + 86400;
    final again = RecsVk(overrides: {'catalog.getAudio': (_) => page});
    final next = make(fake: again)..open();
    await Future<void>.microtask(() {});
    expect(next.refreshing, isTrue);
    await next.refresh();
    expect(listReads(again), hasLength(1));
    expect(listReads(again).single, contains('album_id=-25'));
    expect(next.lists[3].updateTime, generated[3]['update_time']);
  });

  test('VK not answering keeps the lists it had and says why', () async {
    await make().refresh();
    now = now.add(const Duration(hours: 3));
    final failing = RecsVk(
      overrides: {
        'catalog.getAudio': (_) =>
            throw VkException('catalog.getAudio error 10', transient: true),
      },
    );
    final next = make(fake: failing)..open();
    await next.refresh();
    expect(next.error, isNotNull);
    expect(next.lists, hasLength(7));
    expect(next.songsOf(next.lists.first.key), hasLength(12));
  });

  test('a list VK fails to give keeps its songs from before', () async {
    final first = make();
    await first.refresh();
    now = now.add(const Duration(hours: 3));
    final page = recFixture('catalog_get_audio') as Map<String, dynamic>;
    for (final p in (page['playlists'] as List).cast<Map<String, dynamic>>()) {
      p['update_time'] = 1900000000;
    }
    final flaky = RecsVk(
      overrides: {
        'catalog.getAudio': (_) => page,
        'audio.get': (params) => params['album_id'] == '-21'
            ? throw VkException('audio.get error 10', transient: true)
            : recFixture('audio_get_generated_playlist'),
      },
    );
    final next = make(fake: flaky)..open();
    await next.refresh();
    expect(next.error, isNull);
    expect(next.songsOf(next.lists.first.key), hasLength(12));
    expect(logs.last, contains('1 failed'));
  });

  test('a list opens from the cache as songs with stable ids', () async {
    final forYou = make();
    await forYou.refresh();
    final ref = forYou.refOf(forYou.lists[2]);
    final songs = forYou.cached(ref)!;
    expect(songs, hasLength(12));
    expect(songs.every((s) => !s.track.inLibrary), isTrue);
    expect(forYou.cached(ref)!.first.track.id, songs.first.track.id);
    expect(forYou.listOf(ref)!.title, 'New releases');
    expect(await forYou.fetch(ref), hasLength(12));
  });

  test('a song the library has names its library copy', () async {
    final own = Track(
      id: 41,
      sourceId: 3,
      source: TrackSource.vk,
      artist: 'Кино',
      title: 'Закрой за мной дверь',
      durationSec: 205,
    );
    final forYou = make(copyOf: (song) => song.title == own.title ? own : null);
    await forYou.refresh();
    final songs = forYou.cached(forYou.refOf(forYou.lists.first))!;
    expect(forYou.libraryCopyOf(songs.first), own);
    expect(forYou.libraryCopyOf(songs[1]), isNull);
  });

  test('VK Mix grows by the new songs of each call', () async {
    var round = 0;
    final mixVk = RecsVk(
      overrides: {
        'audio.getStreamMixAudios': (_) {
          round++;
          return [
            recSong(5, round * 10 + 1, title: 'Песня $round'),
            recSong(5, round * 10 + 2, title: 'Другая $round'),
            recSong(5, round * 10 + 3, restricted: 2),
          ];
        },
      },
    );
    final forYou = make(fake: mixVk);
    final first = await forYou.moreMix();
    expect(first.map((t) => t.title), ['Песня 1', 'Другая 1']);
    expect(forYou.isMixList(first), isTrue);
    final second = await forYou.moreMix();
    expect(second, hasLength(2));
    expect(forYou.mixSongs, hasLength(4));
    expect(forYou.isMixList([...first, ...second]), isTrue);
    expect(forYou.cached(forYou.mixRef), hasLength(4));
  });

  group('similar songs (C5)', () {
    test('of a VK song: a place with VK\'s songs; again adds new', () async {
      final forYou = make();
      final ref = await forYou.similarTo(
        sourceId: 3,
        artist: 'Кино',
        title: 'Звезда',
        sourceKey: '5_6',
      );
      expect(ref!.title, 'Similar to Звезда');
      expect(vk.calls.single, contains('target_audio=5_6'));
      expect(forYou.cached(ref), hasLength(12));
      expect(await forYou.moreSimilar(ref), 0, reason: 'same reply');
    });

    test(
      'an upload VK gives nothing for: a same-name copy stands in',
      () async {
        final copyVk = RecsVk(
          overrides: {
            'audio.getRecommendations': (p) => p['target_audio'] == '5_6'
                ? recFixture('audio_get_recommendations_target_no_track_id')
                : recFixture('audio_get_recommendations_target_found'),
            'audio.search': (_) => {
              'count': 1,
              'items': [recSong(7, 8, artist: 'a', title: 'b', trackId: 9)],
            },
          },
        );
        final forYou = make(fake: copyVk);
        final ref = await forYou.similarTo(
          sourceId: 3,
          artist: 'a',
          title: 'b',
          sourceKey: '5_6',
        );
        expect(forYou.cached(ref!), hasLength(12));
        expect(copyVk.calls.last, contains('target_audio=7_8'));
      },
    );

    test('nothing similar: no place', () async {
      final none = RecsVk(
        overrides: {
          'audio.getRecommendations': (_) =>
              recFixture('audio_get_recommendations_target_missing'),
          'audio.search': (_) => {'count': 0, 'items': []},
        },
      );
      final forYou = make(fake: none);
      expect(
        await forYou.similarTo(
          sourceId: 3,
          artist: 'a',
          title: 'b',
          sourceKey: '5_6',
        ),
        isNull,
      );
    });
  });

  test('the thumb-down records the song and tells VK', () async {
    final forYou = make();
    final track = Track(
      id: -5,
      sourceId: 3,
      source: TrackSource.vk,
      artist: 'Кино',
      title: 'Звезда',
      durationSec: 200,
      sourceKey: '5_6',
    );
    final note = await forYou.dislike(track);
    expect(note, startsWith('Skipped.'));
    expect(vk.calls.single, 'audio.addDislike audio_ids=5_6');
    final line = File('${dir.path}/dislikes.jsonl').readAsLinesSync().single;
    final record = jsonDecode(line) as Map<String, dynamic>;
    expect(record['key'], '5_6');
    expect(record['title'], 'Звезда');
  });

  test('a list of another account is never shown as this one\'s', () async {
    await make().refresh();
    final other = ForYou(
      accounts: () => const [
        SourceInfo(
          id: 9,
          kind: TrackSource.vk,
          account: 'x',
          name: 'X',
          songCount: 0,
          goneCount: 0,
        ),
      ],
      apiOfSource: (id) => vk.call,
      libraryCopyOfSong: (_) => null,
      cacheDir: dir.path,
      now: () => now,
    )..open();
    await Future<void>.microtask(() {});
    expect(other.refreshing, isTrue, reason: 'cache of account 3');
  });
}
