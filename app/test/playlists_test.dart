// The account's playlists in the app (plan 08, B1): the refresh after a
// sync reads only the playlists whose update time or count moved, keeps
// what VK did not answer for, and the cache file brings them back at the
// next start. Songs come from the recorded reply of the test account
// (test/fixtures/vk_playlists).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/albums.dart';
import 'package:ownsemble/ui/for_you.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/playlists.dart';
import 'package:ownsemble/vk/vk_playlists.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';

const _account = SourceInfo(
  id: 7,
  kind: TrackSource.vk,
  name: 'Test',
  songCount: 0,
  goneCount: 0,
  account: '10000',
);

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/vk_playlists/$name.json').readAsStringSync())
        as Map<String, dynamic>;

/// VK as the test needs it: the account's playlists and each one's songs.
class PlaylistsVk {
  PlaylistsVk() {
    final item =
        (fixture('audio_get_playlists')['items'] as List).first
            as Map<String, dynamic>;
    final made = {...item}
      ..remove('original')
      ..remove('followed')
      ..['id'] = 2
      ..['title'] = 'Мой плейлист'
      ..['count'] = 3
      ..['update_time'] = 100;
    final album = {...item, 'id': 3, 'type': 'album', 'count': 2};
    items = [made, item, album];
    final recorded = (fixture('audio_get_playlist_songs')['items'] as List)
        .cast<Map<String, dynamic>>();
    songs = {
      '10000_1': recorded,
      '10000_2': recorded.take(3).toList(),
      '10000_3': recorded.skip(5).take(2).toList(),
    };
  }

  late List<Map<String, dynamic>> items;
  late Map<String, List<Map<String, dynamic>>> songs;
  final calls = <String>[];

  /// Keys whose songs VK does not answer for.
  final failing = <String>{};
  bool listFails = false;

  Future<Object?> call(String method, Map<String, String> params) async {
    await Future<void>.delayed(Duration.zero);
    if (method == 'audio.getPlaylists') {
      calls.add(method);
      if (listFails) throw const SocketException('offline');
      return {'count': items.length, 'items': items};
    }
    if (method == 'audio.get') {
      final key = '${params['owner_id']}_${params['album_id']}';
      calls.add('audio.get $key');
      if (failing.contains(key)) throw const SocketException('offline');
      final all = songs[key]!;
      final offset = int.parse(params['offset']!);
      final count = int.parse(params['count']!);
      return {
        'count': all.length,
        'items': all.skip(offset).take(count).toList(),
      };
    }
    throw StateError('unexpected $method');
  }

  List<String> songReads() =>
      calls.where((c) => c.startsWith('audio.get ')).toList();
}

void main() {
  late Directory dir;
  late PlaylistsVk vk;
  final logs = <String>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('playlists_test');
    vk = PlaylistsVk();
    logs.clear();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  VkPlaylists make({OutsideSongs? outside, bool loggedIn = true}) =>
      VkPlaylists(
        accounts: () => loggedIn ? [_account] : const [],
        apiOfSource: (id) => loggedIn && id == _account.id ? vk.call : null,
        outside: outside ?? OutsideSongs(libraryCopyOfSong: (_) => null),
        cacheDir: dir.path,
        log: logs.add,
      );

  test('the first refresh reads every playlist; albums are kept, not '
      'shown', () async {
    final playlists = make();
    await playlists.refresh();
    expect(vk.songReads(), hasLength(3));
    final shown = playlists.shown.single;
    expect(shown.account.id, _account.id);
    expect(
      [for (final list in shown.lists) list.title],
      ['Мой плейлист', 'сладкая вата'],
    );
    expect(
      [for (final list in shown.lists) list.kind],
      [VkPlaylistKind.made, VkPlaylistKind.followed],
    );
    expect(playlists.allOf(_account.id), hasLength(3));
    final ref = playlists.refOf(_account.id, shown.lists.first);
    expect(isPlaylistRef(ref), isTrue);
    final songs = playlists.cached(ref)!;
    expect(songs, hasLength(3));
    expect(songs.first.track.sourceId, _account.id);
    expect(songs.first.track.inLibrary, isFalse);
    expect(playlists.playlistOf(ref)!.title, 'Мой плейлист');
    expect(logs.last, contains('3 of 3 playlists read'));
  });

  test('the next refresh reads only playlists whose time or count moved, '
      'and drops one VK no longer lists', () async {
    final playlists = make();
    await playlists.refresh();
    vk.calls.clear();
    await playlists.refresh();
    // Nothing moved; the made playlist is read every time (a vk.com
    // reorder moves neither its time nor its count: B17).
    expect(vk.calls, ['audio.getPlaylists', 'audio.get 10000_2']);

    vk.items[0]['update_time'] = 200;
    vk.songs['10000_2'] = vk.songs['10000_2']!.take(2).toList();
    vk.items[0]['count'] = 2;
    vk.items.removeAt(2);
    vk.calls.clear();
    await playlists.refresh();
    expect(vk.songReads(), ['audio.get 10000_2']);
    final made = playlists.shown.single.lists.first;
    expect(playlists.songsOf(made.key), hasLength(2));
    expect(playlists.allOf(_account.id), hasLength(2));
    expect(playlists.songsOf('10000_3'), isEmpty);
  });

  test('a playlist VK did not answer for keeps its songs and is asked '
      'again', () async {
    final playlists = make();
    await playlists.refresh();
    vk.items[1]['update_time'] = 5;
    vk.failing.add('10000_1');
    vk.calls.clear();
    await playlists.refresh();
    expect(
      vk.songReads(),
      unorderedEquals(['audio.get 10000_1', 'audio.get 10000_2']),
    );
    expect(playlists.songsOf('10000_1'), hasLength(20));
    expect(logs.last, contains('1 failed'));

    vk.failing.clear();
    vk.calls.clear();
    await playlists.refresh();
    expect(
      vk.songReads(),
      unorderedEquals(['audio.get 10000_1', 'audio.get 10000_2']),
      reason: 'asked again (and the made one, as always)',
    );
    expect(playlists.allOf(_account.id)[1].updateTime, 5);
  });

  test('VK not listing the playlists keeps the ones from before', () async {
    final playlists = make();
    await playlists.refresh();
    vk.listFails = true;
    await playlists.refresh();
    expect(playlists.shown.single.lists, hasLength(2));
    expect(playlists.errorOf(_account.id), isNotNull);
    vk.listFails = false;
    await playlists.refresh();
    expect(playlists.errorOf(_account.id), isNull);
  });

  test('the cache file brings everything back, Cyrillic too, without '
      'asking VK', () async {
    await make().refresh();
    vk.calls.clear();
    final again = make();
    final shown = again.shown.single.lists;
    expect(shown.first.title, 'Мой плейлист');
    final songs = again.cached(again.refOf(_account.id, shown.last))!;
    final recorded = fixture('audio_get_playlist_songs')['items'] as List;
    expect(songs, hasLength(recorded.length));
    expect(songs.first.track.title, (recorded.first as Map)['title']);
    expect(vk.calls, isEmpty);
    final saved = File('${dir.path}/playlists.json').readAsStringSync();
    // The first song's stream link and its streams' links; covers stay.
    for (final link in ['example.invalid/13"', 'example.invalid/14"']) {
      expect(saved, isNot(contains(link)), reason: 'no stream links');
    }
  });

  test('open reads the cache at once and asks VK once a run', () async {
    await make().refresh();
    vk.calls.clear();
    final again = make();
    again.open();
    expect(again.hasLists, isTrue);
    expect(vk.calls, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await again.refresh();
    expect(vk.calls.where((c) => c == 'audio.getPlaylists'), hasLength(2));
    vk.calls.clear();
    again.open();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(vk.calls, isEmpty, reason: 'asked in this run already');
  });

  test('a refresh asked while one runs runs once after it', () async {
    final playlists = make();
    final first = playlists.refresh();
    // Asks before it began join it; these come once it runs.
    expect(identical(playlists.refresh(), first), isTrue);
    await Future<void>.delayed(Duration.zero);
    final second = playlists.refresh();
    final third = playlists.refresh();
    await Future.wait([first, second, third]);
    expect(vk.calls.where((c) => c == 'audio.getPlaylists'), hasLength(2));
  });

  test('a logged-out account shows nothing and asks nothing', () async {
    final playlists = make(loggedIn: false);
    await playlists.refresh();
    expect(vk.calls, isEmpty);
    expect(playlists.shown, isEmpty);
    expect(playlists.hasLists, isFalse);
  });

  test('a song in a For you list and a playlist is one song; only the '
      'recommended one offers the thumb-down', () async {
    final outside = OutsideSongs(libraryCopyOfSong: (_) => null);
    final playlists = make(outside: outside);
    await playlists.refresh();
    final made = playlists.shown.single.lists.first;
    final listed = playlists.cached(playlists.refOf(_account.id, made))!;
    final song = playlists.songsOf(made.key).first;
    final rec = outside.trackOf(song, _account.id, recommended: true);
    expect(rec.id, listed.first.track.id);
    expect(outside.isRecommended(rec.id), isTrue);
    expect(outside.isRecommended(listed[1].track.id), isFalse);
  });

  test('the library copy and the album come from the shared songs', () async {
    final copy = Track(
      id: 42,
      sourceId: _account.id,
      source: TrackSource.vk,
      artist: 'a',
      title: 't',
      durationSec: 1,
    );
    final playlists = make(
      outside: OutsideSongs(
        libraryCopyOfSong: (song) => song.title == 'моя любовь' ? copy : null,
      ),
    );
    await playlists.refresh();
    final followed = playlists.shown.single.lists.last;
    final listed = playlists.cached(playlists.refOf(_account.id, followed))!;
    expect(playlists.libraryCopyOf(listed.first), copy);
    expect(playlists.libraryCopyOf(listed[1]), isNull);
  });

  test('the combined catalog sends each place to its own part', () async {
    final outside = OutsideSongs(libraryCopyOfSong: (_) => null);
    final playlists = make(outside: outside);
    final forYou = ForYou(
      accounts: () => [_account],
      apiOfSource: (_) => null,
      libraryCopyOfSong: (_) => null,
      outside: outside,
    );
    final lists = CombinedLists(playlists: playlists, others: forYou);
    await playlists.refresh();
    final made = playlists.shown.single.lists.first;
    final ref = playlists.refOf(_account.id, made);
    expect(lists.cached(ref), hasLength(3));
    expect(lists.canFetch(ref), isTrue);
    final other = AlbumRef(
      title: 'x',
      link: (sourceId: _account.id, key: '10000_2', accessKey: null),
    );
    expect(lists.cached(other), isNull, reason: "For you's, not a playlist");
    expect(lists.canFetch(other), isFalse);
    final song = VkRecSong(
      const NewTrack(
        artist: 'a',
        title: 't',
        durationSec: 1,
        addedAt: 0,
        sourceKey: '1_2',
      ),
    );
    final track = forYou.trackOf(song);
    expect(lists.albumOf(track), isNull);
  });
}
