// Editing the account's VK playlists in the app (plan 08, C3): every edit
// is written to VK and the playlist read back; edits and the refresh after
// a sync run one after another; a removal or an unfollow waits for its
// Undo bar; "already in" is the app's own check. VK is the fake that does
// what real VK did on the test account (playlist_edits_support.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/outside_songs.dart';
import 'package:ownsemble/ui/playlists.dart';

import 'playlist_edits_support.dart';

const _account = SourceInfo(
  id: 7,
  kind: TrackSource.vk,
  name: 'Test',
  songCount: 0,
  goneCount: 0,
  account: '10000',
);

/// A library song of the account with the VK key [key].
Track librarySong(int id, String key, {int duration = 200}) => Track(
  id: id,
  sourceId: _account.id,
  source: TrackSource.vk,
  artist: 'Исполнитель',
  title: 'Песня $id',
  durationSec: duration,
  sourceKey: key,
  addedAt: 0,
);

void main() {
  late EditVk vk;
  late VkPlaylists playlists;
  late FakePlaylist mine;
  late FakePlaylist theirs;
  late Map<String, Track> libraryByKey;
  final logs = <String>[];

  String keyOf(FakePlaylist list) => '10000_${list.id}';
  List<String> shownKeys(FakePlaylist list) => [
    for (final song in playlists.songsOf(keyOf(list))) song.key,
  ];

  setUp(() async {
    vk = EditVk();
    logs.clear();
    for (final id in [1, 2, 3]) {
      vk.song(10000, id, trackId: 100 + id);
      vk.library.add('10000_$id');
    }
    vk.song(555, 7, trackId: 77);
    vk.song(555, 8, trackId: 88);
    libraryByKey = {
      for (final id in [1, 2, 3]) '10000_$id': librarySong(id, '10000_$id'),
    };
    theirs = vk.followed('Чужой', '555_3');
    theirs.songs.add(vk.known['555_8']!);
    mine = vk.made('Мой', [vk.known['10000_1']!, vk.known['10000_2']!]);
    playlists = VkPlaylists(
      accounts: () => [_account],
      apiOfSource: (id) => id == _account.id ? vk.call : null,
      outside: OutsideSongs(
        libraryCopyOfSong: (song) =>
            libraryByKey[song.sourceKey] ??
            // The same recording: a copy VK made of a library song.
            libraryByKey.values
                .where(
                  (track) =>
                      song.vkTrackId != null &&
                      song.vkTrackId == 100 + track.id,
                )
                .firstOrNull,
      ),
      log: logs.add,
    );
    await playlists.refresh();
    vk.calls.clear();
  });

  test('add puts a library song on top, written to VK and read back', () async {
    final edit = await playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    expect(edit.ok, isTrue, reason: edit.note);
    expect(edit.note, 'Added to Мой');
    expect(vk.keysOf(mine), ['10000_3', '10000_1', '10000_2']);
    expect(shownKeys(mine), ['10000_3', '10000_1', '10000_2']);
    expect(vk.calls.first, startsWith('audio.addToPlaylist'));
    expect(
      vk.calls.where((c) => c.startsWith('audio.getPlaylistById')),
      hasLength(1),
      reason: 'read back',
    );
  });

  test('a song of another owner goes in as VK\'s copy: the app keeps the '
      'copy\'s key and then knows it is in', () async {
    final outside = playlists.outside.trackOf(
      playlists.songsOf(keyOf(theirs)).single,
      _account.id,
    );
    final edit = await playlists.addSong(_account.id, keyOf(mine), outside);
    expect(edit.ok, isTrue, reason: edit.note);
    final copy = vk.keysOf(mine).first;
    expect(copy, isNot('555_8'));
    expect(shownKeys(mine).first, copy);
    vk.calls.clear();
    final again = await playlists.addSong(_account.id, keyOf(mine), outside);
    expect(again.ok, isFalse);
    expect(again.note, 'Already in Мой');
    expect(vk.calls, isEmpty, reason: 'no second copy on VK');
    expect(vk.keysOf(mine), hasLength(3));
  });

  test('already in: the library song itself, or a VK copy of it', () async {
    expect(playlists.hasSong(keyOf(mine), libraryByKey['10000_1']!), isTrue);
    expect(playlists.hasSong(keyOf(mine), libraryByKey['10000_3']!), isFalse);
    // A copy of song 3's recording (another key, the same track id).
    final copyOf3 = vk.song(10000, 50, trackId: 103);
    mine.songs.insert(0, copyOf3);
    mine.updateTime++;
    await playlists.refresh();
    expect(playlists.hasSong(keyOf(mine), libraryByKey['10000_3']!), isTrue);
  });

  test('a followed playlist takes no edits; none is sent', () async {
    expect(playlists.editableOf(_account.id).map((l) => l.title), ['Мой']);
    final edit = await playlists.addSong(
      _account.id,
      keyOf(theirs),
      libraryByKey['10000_3']!,
    );
    expect(edit.ok, isFalse);
    expect(vk.calls, isEmpty);
  });

  test('a removal hides the song at once and waits for its Undo bar: Undo '
      'sends nothing, closing the bar sends it', () async {
    final held = playlists.removeSong(_account.id, keyOf(mine), '10000_1');
    expect(shownKeys(mine), ['10000_2']);
    expect(vk.keysOf(mine), ['10000_1', '10000_2'], reason: 'not yet');
    held.undo();
    expect(shownKeys(mine), ['10000_1', '10000_2']);
    expect(vk.calls, isEmpty);

    final again = playlists.removeSong(_account.id, keyOf(mine), '10000_1');
    expect(shownKeys(mine), ['10000_2']);
    final edit = await again.commit();
    expect(edit.ok, isTrue, reason: edit.note);
    expect(vk.keysOf(mine), ['10000_2']);
    expect(shownKeys(mine), ['10000_2']);
    // Undo after the write is too late: nothing changes.
    again.undo();
    expect(shownKeys(mine), ['10000_2']);
  });

  test('move: shown at once, written by the read keys, read back', () async {
    vk.calls.clear();
    final moving = playlists.moveSong(
      _account.id,
      keyOf(mine),
      '10000_2',
      beforeKey: '10000_1',
    );
    expect(shownKeys(mine), ['10000_2', '10000_1'], reason: 'at once');
    final edit = await moving;
    expect(edit.ok, isTrue, reason: edit.note);
    expect(vk.keysOf(mine), ['10000_2', '10000_1']);
    expect(shownKeys(mine), ['10000_2', '10000_1']);
  });

  test(
    'a move VK did not make shows VK\'s order after the read-back',
    () async {
      // audio.reorder answers 1 even when nothing moved: the read-back
      // decides.
      vk.failing.add('audio.reorder');
      final edit = await playlists.moveSong(
        _account.id,
        keyOf(mine),
        '10000_2',
        beforeKey: '10000_1',
      );
      expect(edit.ok, isFalse);
      expect(edit.note, startsWith('VK did not answer'));
      expect(shownKeys(mine), ['10000_1', '10000_2']);
    },
  );

  test('rename: the new title at once and after the read-back; the place '
      'takes it by key', () async {
    final ref = playlists.refOf(
      _account.id,
      playlists.allOf(_account.id).firstWhere((l) => l.key == keyOf(mine)),
    );
    final renaming = playlists.rename(_account.id, keyOf(mine), 'Новое имя');
    expect(playlists.titleOf(ref), 'Новое имя');
    final edit = await renaming;
    expect(edit.ok, isTrue, reason: edit.note);
    expect(mine.title, 'Новое имя');
    expect(playlists.titleOf(ref), 'Новое имя');
    expect(ref.title, 'Мой', reason: 'the old ref is still the same place');
    expect(playlists.playlistOf(ref)!.title, 'Новое имя');
  });

  test(
    'create with a first song: on top of the account\'s playlists',
    () async {
      final edit = await playlists.create(
        _account.id,
        'Свежий',
        first: libraryByKey['10000_3']!,
      );
      expect(edit.ok, isTrue, reason: edit.note);
      final made = playlists.allOf(_account.id).first;
      expect(made.title, 'Свежий');
      expect(made.key, edit.key);
      expect(playlists.songsOf(made.key).map((s) => s.key), ['10000_3']);
      expect(vk.playlists.first.title, 'Свежий');
    },
  );

  test('delete: gone from VK and from the app', () async {
    final edit = await playlists.delete(_account.id, keyOf(mine));
    expect(edit.ok, isTrue, reason: edit.note);
    expect(vk.playlists.map((l) => l.title), ['Чужой']);
    expect(playlists.allOf(_account.id).map((l) => l.title), ['Чужой']);
    expect(playlists.songsOf(keyOf(mine)), isEmpty);
  });

  test('unfollow hides the playlist and waits for its bar; Undo brings it '
      'back with nothing sent', () async {
    List<String> shownTitles() => [
      for (final (account: _, :lists) in playlists.shown)
        for (final list in lists) list.title,
    ];
    final held = playlists.unfollow(_account.id, keyOf(theirs));
    expect(shownTitles(), ['Мой']);
    held.undo();
    expect(shownTitles(), ['Мой', 'Чужой']);
    expect(vk.calls, isEmpty);
    final again = playlists.unfollow(_account.id, keyOf(theirs));
    final edit = await again.commit();
    expect(edit.ok, isTrue, reason: edit.note);
    expect(vk.playlists.map((l) => l.title), ['Мой']);
    expect(shownTitles(), ['Мой']);
  });

  test('an edit asked while a refresh runs is written after it, so the '
      'refresh never brings back the old songs', () async {
    vk.gate = Completer<void>();
    mine.updateTime++;
    final refreshing = playlists.refresh();
    final adding = playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    await Future<void>.delayed(Duration.zero);
    vk.gate!.complete();
    vk.gate = null;
    await refreshing;
    final edit = await adding;
    expect(edit.ok, isTrue, reason: edit.note);
    final firstWrite = vk.calls.indexWhere(
      (c) => c.startsWith('audio.addToPlaylist'),
    );
    final lastRefreshRead = vk.calls.lastIndexWhere(
      (c) => c.startsWith('audio.getPlaylists'),
    );
    expect(lastRefreshRead, lessThan(firstWrite));
    expect(shownKeys(mine), ['10000_3', '10000_1', '10000_2']);
  });

  test('two quick adds of one song: the second finds it in', () async {
    final first = playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    final second = playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    expect((await first).ok, isTrue);
    expect((await second).note, 'Already in Мой');
    expect(
      vk.calls.where((c) => c.startsWith('audio.addToPlaylist')),
      hasLength(1),
    );
  });

  test('a write that failed after VK did it: the read-back shows it', () async {
    vk.failAfterDoing.add('audio.addToPlaylist');
    final edit = await playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    expect(edit.ok, isTrue, reason: 'VK has it: ${edit.note}');
    expect(shownKeys(mine), ['10000_3', '10000_1', '10000_2']);
  });

  test('a write and its read-back both failing: the last state VK gave '
      'stays and the note says VK did not answer', () async {
    vk.failing.addAll(['audio.addToPlaylist', 'audio.getPlaylistById']);
    final edit = await playlists.addSong(
      _account.id,
      keyOf(mine),
      libraryByKey['10000_3']!,
    );
    expect(edit.ok, isFalse);
    expect(edit.note, startsWith('VK did not answer'));
    expect(shownKeys(mine), ['10000_1', '10000_2']);
  });

  test('a made playlist is read again at every refresh: a reorder on '
      'vk.com moves neither its time nor its count (B17)', () async {
    mine.songs.insert(0, mine.songs.removeAt(1));
    await playlists.refresh();
    expect(shownKeys(mine), ['10000_2', '10000_1']);
    // A followed one is still read only when its time or count moved.
    expect(vk.calls, contains('audio.get album_id=${mine.id}'));
    expect(vk.calls, isNot(contains('audio.get album_id=${theirs.id}')));
  });

  test('an edit is saved to the cache: the next start shows it', () async {
    final dir = Directory.systemTemp.createTempSync('playlist_edits_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    VkPlaylists make() => VkPlaylists(
      accounts: () => [_account],
      apiOfSource: (id) => vk.call,
      outside: OutsideSongs(libraryCopyOfSong: (_) => null),
      cacheDir: dir.path,
    );
    final first = make();
    await first.refresh();
    await first.addSong(_account.id, keyOf(mine), libraryByKey['10000_3']!);
    final next = make();
    expect(next.songsOf(keyOf(mine)).map((s) => s.key), [
      '10000_3',
      '10000_1',
      '10000_2',
    ]);
  });
}
