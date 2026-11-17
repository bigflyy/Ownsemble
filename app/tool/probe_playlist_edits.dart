// What VK does when a playlist is edited (plan 08, A2 / C1): makes a probe
// playlist on the TEST account, adds songs (also one twice), renames it,
// reorders it several ways, removes songs, follows and unfollows a public
// playlist, and watches update_time and the library's count throughout.
// At the end the probe playlist is deleted and the follow undone.
//
// Writes to VK: only for the test account's session file, never the second
// account (that one is read-only, user 2026-11-03).
//
// Prints an ALLOWLIST: songs as letters (a, b, c ...), counts, yes/no,
// seconds between update times, field names and VK error codes. Never a
// link, key, token, id, name of a song or whole reply.
//
// Run from app/:
//   dart run tool/probe_playlist_edits.dart --vk-session FILE
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

const probeTitle = 'Ownsemble probe A2';

/// Long numbers blanked, so an id inside an error text never shows.
String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

String keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 600));

Future<void> main(List<String> args) async {
  final at = args.indexOf('--vk-session');
  final path = at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  if (path == null || path.contains('session-2')) {
    print('give the TEST account: --vk-session ../.local/v2-test/session.json');
    exitCode = 2;
    return;
  }
  final client = VkClient(
    SessionCookie.loadAll(File(path)),
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
  );

  /// One call; a VK error is printed as its code and returned as null.
  Future<Object?> tryCall(
    String step,
    String method,
    Map<String, String> params,
  ) async {
    await pause();
    try {
      return await client.call(method, params);
    } on VkException catch (error) {
      print(
        '  $step: $method -> VK error ${error.code} '
        '(${blank(error.message).split(': ').skip(1).join(': ')})',
      );
      return null;
    }
  }

  // Letters for the probe's songs, so orders print without ids.
  final letterOf = <String, String>{};
  String lettersOf(Iterable<String> keys) =>
      keys.map((key) => letterOf[key] ?? '?').join(' ');

  late final int me;
  int? playlistId;
  Map<String, dynamic>? followedCopy;
  int? libraryCountAtStart;

  Future<int?> libraryCount() async {
    final reply = await tryCall('library', 'audio.get', {'count': '1'});
    return reply is Map ? reply['count'] as int? : null;
  }

  Future<Map<String, dynamic>?> playlistInfo(int ownerId, int id) async {
    final reply = await tryCall('info', 'audio.getPlaylistById', {
      'owner_id': '$ownerId',
      'playlist_id': '$id',
    });
    return reply is Map<String, dynamic> ? reply : null;
  }

  /// The probe playlist's songs in VK's order, as keys.
  Future<List<String>> songsOf(int id) async {
    final reply = await tryCall('songs', 'audio.get', {
      'owner_id': '$me',
      'playlist_id': '$id',
      'count': '100',
    });
    if (reply is! Map) return const [];
    return [
      for (final item in (reply['items'] as List).cast<Map<String, dynamic>>())
        keyOf(item),
    ];
  }

  int? lastUpdate;
  Future<void> show(String step) async {
    final id = playlistId!;
    final info = await playlistInfo(me, id);
    final songs = await songsOf(id);
    final update = info?['update_time'] as int?;
    final moved = update == null || lastUpdate == null
        ? '-'
        : '${update - lastUpdate!}s';
    lastUpdate = update ?? lastUpdate;
    print(
      '$step: songs [${lettersOf(songs)}] count ${info?['count']} '
      'title ${info?['title'] == probeTitle
          ? 'probe'
          : info?['title'] == '$probeTitle renamed'
          ? 'renamed'
          : 'other'} '
      'update_time moved $moved',
    );
  }

  try {
    await client.ensureToken();
    me = client.userId;
    libraryCountAtStart = await libraryCount();
    print('library count at start: $libraryCountAtStart');

    final lists = await tryCall('lists', 'audio.getPlaylists', {
      'owner_id': '$me',
      'count': '200',
    });
    if (lists is! Map) return;
    final listItems = (lists['items'] as List).cast<Map<String, dynamic>>();
    if (listItems.any((item) => '${item['title']}'.startsWith(probeTitle))) {
      print(
        'a probe playlist is there already (an earlier run): stop; '
        'delete it by hand or with --cleanup first',
      );
      if (!args.contains('--cleanup')) return;
      for (final item in listItems) {
        if ('${item['title']}'.startsWith(probeTitle)) {
          final gone = await tryCall('cleanup', 'audio.deletePlaylist', {
            'owner_id': '$me',
            'playlist_id': '${item['id']}',
          });
          print('cleanup: deleted ${gone == 1 ? 'yes' : 'reply $gone'}');
        }
      }
      return;
    }

    // Four library songs, from the middle of the library.
    final library = await tryCall('library', 'audio.get', {'count': '40'});
    if (library is! Map) return;
    final items = (library['items'] as List).cast<Map<String, dynamic>>();
    final picked = [
      for (final i in [5, 13, 21, 29]) items[i],
    ];
    final keys = [for (final item in picked) keyOf(item)];
    for (final (index, key) in keys.indexed) {
      letterOf[key] = 'abcd'[index];
    }
    final owners = picked.map(
      (item) => item['owner_id'] == me ? 'own' : 'other',
    );
    print('picked a b c d: owners ${owners.join(' ')}');
    final [a, b, c, d] = keys;

    // 1. Create, with songs in the same call.
    final made = await tryCall('create', 'audio.createPlaylist', {
      'owner_id': '$me',
      'title': probeTitle,
      'audio_ids': '$a,$b',
    });
    print(
      'create reply fields: '
      '${made is Map ? (made.keys.toList()..sort()).join(',') : made.runtimeType}',
    );
    if (made is! Map || made['id'] is! int) return;
    playlistId = made['id'] as int;
    await show('1 created with a b');

    // 2. Add one, then a repeat, then a repeat inside one call.
    final added = await tryCall('add', 'audio.addToPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids': c,
    });
    print(
      '  add reply: ${added is List ? 'list of ${added.length}${added.isEmpty ? '' : ', fields ${(added.first as Map).keys.join(',')}'}' : added.runtimeType}',
    );
    await show('2a add c');
    await tryCall('repeat', 'audio.addToPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids': a,
    });
    await show('2b add a again');
    await tryCall('repeat2', 'audio.addToPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids': '$d,$d',
    });
    await show('2c add d,d in one call');

    // 3. Rename only: does it keep the songs?
    await tryCall('rename', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'title': '$probeTitle renamed',
    });
    await show('3 rename only');

    // 4. Reorder, several ways.
    final now = await songsOf(playlistId);
    print('  before reorder: [${lettersOf(now)}]');
    final wanted = now.reversed.toList();
    await tryCall('reorder audio_ids', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'title': '$probeTitle renamed',
      'audio_ids': wanted.join(','),
    });
    await show('4a editPlaylist audio_ids reversed [${lettersOf(wanted)}]');

    final current = await songsOf(playlistId);
    if (current.length >= 2) {
      final last = current.last;
      final first = current.first;
      final lastParts = last.split('_');
      final firstParts = first.split('_');
      await tryCall('reorder', 'audio.reorder', {
        'owner_id': lastParts[0],
        'audio_id': lastParts[1],
        'before': firstParts[1],
        'playlist_id': '$playlistId',
      });
      await show('4b audio.reorder last before first');
      await tryCall('reorder actions', 'audio.editPlaylist', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
        'reorder_actions': jsonEncode([
          [first, last],
        ]),
      });
      await show('4c editPlaylist reorder_actions [[first,last]]');
      await tryCall('moveToPlaylist', 'audio.moveInPlaylist', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
        'audio_id': last,
        'before_audio_id': first,
      });
      await show('4d moveInPlaylist last before first');
    }

    // 5. Remove one key that is in twice.
    await tryCall('remove', 'audio.removeFromPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids': a,
    });
    await show('5a removeFromPlaylist a');
    await tryCall('remove2', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids_to_remove': b,
    });
    await show('5b editPlaylist audio_ids_to_remove b');
    await tryCall('add3', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids_to_add': a,
    });
    await show('5c editPlaylist audio_ids_to_add a');

    // 5d-5f. Does editPlaylist audio_ids also remove and add songs, keep a
    // repeat, and keep the order with a song from outside the library?
    await tryCall('subset', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'title': '$probeTitle renamed',
      'audio_ids': '$c,$b',
    });
    await show('5d editPlaylist audio_ids [c b] (d left out)');
    await tryCall('superset', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'title': '$probeTitle renamed',
      'audio_ids': '$b,$a,$c',
    });
    await show('5e editPlaylist audio_ids [b a c] (a is new)');
    await tryCall('repeat3', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'title': '$probeTitle renamed',
      'audio_ids': '$a,$b,$a,$c',
    });
    await show('5f editPlaylist audio_ids [a b a c] (a twice)');
    await tryCall('no title', 'audio.editPlaylist', {
      'owner_id': '$me',
      'playlist_id': '$playlistId',
      'audio_ids': '$c,$b,$a',
    });
    await show('5g editPlaylist audio_ids [c b a] without title');
    await tryCall('reorder after', 'audio.reorder', {
      'owner_id': c.split('_')[0],
      'audio_id': c.split('_')[1],
      'after': a.split('_')[1],
      'playlist_id': '$playlistId',
    });
    await show('5h audio.reorder c after a');

    // 5i-5m. A song of another owner, not in the library (most playlist
    // songs): add, move (song's owner, then the playlist's), remove.
    final search = await tryCall('search', 'audio.search', {
      'q': 'Кино',
      'count': '30',
    });
    final ownKeys = {for (final item in items) keyOf(item)};
    final foreign = search is Map
        ? (search['items'] as List).cast<Map<String, dynamic>>().where(
            (item) =>
                item['owner_id'] != me &&
                !ownKeys.contains(keyOf(item)) &&
                '${item['url'] ?? ''}'.isNotEmpty,
          )
        : const <Map<String, dynamic>>[];
    if (foreign.isNotEmpty) {
      final x = keyOf(foreign.first);
      letterOf[x] = 'x';
      final [xOwner, xId] = x.split('_');
      await tryCall('add x', 'audio.addToPlaylist', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
        'audio_ids': x,
      });
      await show('5i add x (other owner)');
      // The key the playlist itself gives for the new song.
      final read = await tryCall('songs', 'audio.get', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
        'count': '100',
      });
      final readItems = read is Map
          ? (read['items'] as List).cast<Map<String, dynamic>>()
          : const <Map<String, dynamic>>[];
      final fresh = readItems
          .where((item) => !letterOf.containsKey(keyOf(item)))
          .firstOrNull;
      if (fresh != null) {
        final xItem = foreign.first;
        print(
          '  x as read: same title ${fresh['title'] == xItem['title'] ? 'yes' : 'no'}, '
          'same artist ${fresh['artist'] == xItem['artist'] ? 'yes' : 'no'}, '
          'same owner ${fresh['owner_id'] == xItem['owner_id'] ? 'yes' : 'no'}, '
          'same id ${fresh['id'] == xItem['id'] ? 'yes' : 'no'}, '
          'owner ${fresh['owner_id'] == me
              ? 'me'
              : (fresh['owner_id'] as int) < 0
              ? 'group'
              : 'user'}, '
          'search owner ${xItem['owner_id'] == me
              ? 'me'
              : (xItem['owner_id'] as int) < 0
              ? 'group'
              : 'user'}',
        );
        // Which fields the copy shares with the original: names only.
        final same = <String>[], differ = <String>[], only = <String>[];
        for (final name in {...fresh.keys, ...xItem.keys}) {
          if (!fresh.containsKey(name) || !xItem.containsKey(name)) {
            only.add('$name(${fresh.containsKey(name) ? 'copy' : 'orig'})');
          } else if (jsonEncode(fresh[name]) == jsonEncode(xItem[name])) {
            same.add(name);
          } else {
            differ.add(name);
          }
        }
        print('  copy vs original: same ${(same..sort()).join(',')}');
        print(
          '  differ ${(differ..sort()).join(',')}; only ${(only..sort()).join(',')}',
        );
        final y = keyOf(fresh);
        letterOf[y] = 'y';
        await show('5i1 read key named y');
        await tryCall('add x again', 'audio.addToPlaylist', {
          'owner_id': '$me',
          'playlist_id': '$playlistId',
          'audio_ids': x,
        });
        await show('5i1b add x again (search key)');
        await tryCall('add y again', 'audio.addToPlaylist', {
          'owner_id': '$me',
          'playlist_id': '$playlistId',
          'audio_ids': y,
        });
        await show('5i1c add y again (read key)');
        final [yOwner, yId] = y.split('_');
        final before = await songsOf(playlistId);
        await tryCall('move y', 'audio.reorder', {
          'owner_id': yOwner,
          'audio_id': yId,
          'after': before.last.split('_')[1],
          'playlist_id': '$playlistId',
        });
        await show('5i2 reorder y after last, owner_id = y owner');
        await tryCall('move y me', 'audio.reorder', {
          'owner_id': '$me',
          'audio_id': yId,
          'before': before.first.split('_')[1],
          'playlist_id': '$playlistId',
        });
        await show('5i3 reorder y before first, owner_id = me');
        final whole = await songsOf(playlistId);
        await tryCall('full list', 'audio.editPlaylist', {
          'owner_id': '$me',
          'playlist_id': '$playlistId',
          'audio_ids': [...whole.where((k) => k != y), y].join(','),
        });
        await show('5i4 editPlaylist audio_ids with y last');
        await tryCall('remove y', 'audio.removeFromPlaylist', {
          'owner_id': '$me',
          'playlist_id': '$playlistId',
          'audio_ids': y,
        });
        await show('5i5 removeFromPlaylist y');
      }
      // The key with its access key: "owner_id_id_accesskey".
      if (foreign.length > 1 && foreign.elementAt(1)['access_key'] is String) {
        final z = foreign.elementAt(1);
        await tryCall('add z+ak', 'audio.addToPlaylist', {
          'owner_id': '$me',
          'playlist_id': '$playlistId',
          'audio_ids': '${keyOf(z)}_${z['access_key']}',
        });
        await show('5i6 add z as key_accesskey (count +1 = taken)');
      }
      final now = await songsOf(playlistId);
      await tryCall('move x', 'audio.reorder', {
        'owner_id': xOwner,
        'audio_id': xId,
        'after': now.last.split('_')[1],
        'playlist_id': '$playlistId',
      });
      await show('5j reorder x after last, owner_id = x owner');
      final now2 = await songsOf(playlistId);
      await tryCall('move x 2', 'audio.reorder', {
        'owner_id': '$me',
        'audio_id': xId,
        'before': now2.first.split('_')[1],
        'playlist_id': '$playlistId',
      });
      await show('5k reorder x before first, owner_id = me');
      final now3 = await songsOf(playlistId);
      final [firstOwner, firstId] = now3.first.split('_');
      await tryCall('move first', 'audio.reorder', {
        'owner_id': firstOwner,
        'audio_id': firstId,
        'after': xId,
        'playlist_id': '$playlistId',
      });
      await show('5l reorder first after x (by x id only)');
      await tryCall('remove x', 'audio.removeFromPlaylist', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
        'audio_ids': x,
      });
      await show('5m removeFromPlaylist x');
    } else {
      print('5i no song of another owner found');
    }
    print('library count now: ${await libraryCount()}');

    // 6. Follow and unfollow a public playlist.
    final found = await tryCall('search', 'audio.searchPlaylists', {
      'q': 'rock',
      'count': '10',
    });
    final candidates = found is Map
        ? (found['items'] as List)
              .cast<Map<String, dynamic>>()
              .where((item) => item['owner_id'] != me)
              .toList()
        : const <Map<String, dynamic>>[];
    print('6 public playlists found: ${candidates.length}');
    if (candidates.isNotEmpty) {
      final target = candidates.first;
      final followed = await tryCall('follow', 'audio.followPlaylist', {
        'owner_id': '${target['owner_id']}',
        'playlist_id': '${target['id']}',
        if (target['access_key'] is String)
          'access_key': target['access_key'] as String,
      });
      print(
        '  follow reply fields: '
        '${followed is Map ? (followed.keys.toList()..sort()).join(',') : followed.runtimeType}',
      );
      if (followed is Map<String, dynamic>) {
        followedCopy = followed;
        final copy = await playlistInfo(
          followed['owner_id'] as int,
          followed['playlist_id'] as int,
        );
        print(
          '  copy by getPlaylistById: original ${copy?['original'] is Map ? 'yes' : 'no'}, '
          'permissions ${copy?['permissions'] is Map ? ((copy!['permissions'] as Map).entries.map((e) => '${e.key}=${e.value}').join(' ')) : '-'}',
        );
      }
      final after = await tryCall('lists', 'audio.getPlaylists', {
        'owner_id': '$me',
        'count': '200',
      });
      if (after is Map) {
        final first = (after['items'] as List).first as Map<String, dynamic>;
        final original = first['original'];
        print(
          '  first list after follow: followed ${first['type'] == 1 || original != null ? 'yes' : 'no'}, '
          'original is target ${original is Map && original['playlist_id'] == target['id'] ? 'yes' : 'no'}, '
          'own entry is the reply ${followed is Map && first['id'] == followed['playlist_id'] ? 'yes' : 'no'}, '
          'count ${after['count']} (was ${lists['count']})',
        );
      }
    }
  } on VkException catch (error) {
    print('VK error: ${blank(error.message)}');
    exitCode = 1;
  } finally {
    // Undo: unfollow, delete the probe playlist.
    final copy = followedCopy;
    if (copy != null) {
      final viaUnfollow = await tryCall('unfollow', 'audio.unfollowPlaylist', {
        'owner_id': '${copy['owner_id']}',
        'playlist_id': '${copy['playlist_id']}',
      });
      print('7a unfollowPlaylist on the copy: reply $viaUnfollow');
      if (viaUnfollow == null) {
        final viaDelete = await tryCall('unfollow', 'audio.deletePlaylist', {
          'owner_id': '${copy['owner_id']}',
          'playlist_id': '${copy['playlist_id']}',
        });
        print('7b deletePlaylist on the copy: reply $viaDelete');
      }
    }
    if (playlistId != null) {
      final gone = await tryCall('delete', 'audio.deletePlaylist', {
        'owner_id': '$me',
        'playlist_id': '$playlistId',
      });
      print('8 deletePlaylist probe: reply $gone');
      final lists = await tryCall('lists', 'audio.getPlaylists', {
        'owner_id': '$me',
        'count': '200',
      });
      if (lists is Map) {
        final left = (lists['items'] as List).where(
          (item) => '${(item as Map)['title']}'.startsWith(probeTitle),
        );
        print(
          '  probe playlists left: ${left.length}, lists count ${lists['count']}',
        );
      }
      print(
        'library count at end: ${await libraryCount()} '
        '(start $libraryCountAtStart)',
      );
    }
    client.close();
  }
}
