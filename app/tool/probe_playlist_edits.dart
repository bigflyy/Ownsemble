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
      if (followed is Map<String, dynamic>) followedCopy = followed;
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
