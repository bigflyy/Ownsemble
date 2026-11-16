// Plan 07 A6 and C5 probes, TEST ACCOUNT ONLY.
//
// A6: which feedback methods VK knows for a recommended song (a dislike or
// "not interested"), found by calling each candidate name with no
// parameters: VK answers 3 "Unknown method" for a name it does not know and
// 100 "a parameter is missing" for one it knows, and with no song named
// nothing can change. With --dislike, one VK Mix song is disliked, the song's
// `dislike` flag is read back, the mix is read again, and the dislike is
// taken back so the account ends as it started.
//
// C5: audio.getRecommendations with target_audio for songs other than an
// own song: a found (not owned) song, with and without its access key; an
// own upload with no VK track id; a restricted song; an id that does not
// exist.
//
// Also prints the update_time of the account's generated lists (A3).
//
// Prints an ALLOWLIST of named fields only (codes, counts, times, flags);
// never a link, key, token, id or whole reply.
//
// Run from app/:
//   dart run tool/probe_recs_feedback.dart --vk-session FILE [--dislike]
//     [--fixtures DIR]
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

import 'probe_recommendations.dart' show Scrubber, blank, keyOf, topShape;

/// Feedback-like method names. None can act without a song named; names
/// that could act on nothing (a "reset all") are left out on purpose.
const candidates = [
  'audio.addDislike',
  'audio.removeDislike',
  'audio.dislike',
  'audio.undislike',
  'audio.setDislike',
  'audio.dislikeAudio',
  'audio.dislikeTrack',
  'audio.getDislikes',
  'audio.hide',
  'audio.hideAudio',
  'audio.hideRecommendation',
  'audio.notInterested',
  'audio.ban',
  'audio.skip',
  'audio.sendStartEvent',
  'audio.sendStopEvent',
  'audio.sendListenEvent',
  'audio.sendEvent',
  'audio.trackEvent',
  'audio.addLike',
  'catalog.hide',
  'catalog.hideBlock',
  'catalog.hideItem',
  'catalog.dislike',
  'catalog.sendEvent',
  'stats.trackEvents',
];

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final fixtureDir = valueOf('--fixtures');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    // The music page once took 30 s and once gave no reply in 15 s.
    requestTimeout: const Duration(seconds: 60),
    silenceTimeout: const Duration(seconds: 45),
  );
  final scrubber = Scrubber();

  void save(String name, Object? reply) {
    if (fixtureDir == null) return;
    Directory(fixtureDir).createSync(recursive: true);
    File('$fixtureDir/$name.json').writeAsStringSync(
      '${const JsonEncoder.withIndent(' ').convert(scrubber.scrub(reply))}\n',
    );
    print('  fixture $name.json saved');
  }

  /// Calls [method]; prints the time and the reply's shape or VK's code.
  Future<(Object?, int?)> timed(
    String label,
    String method,
    Map<String, String> params, {
    String? fixture,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final reply = await client.call(method, params);
      print(
        '$label: OK in ${watch.elapsedMilliseconds} ms: ${topShape(reply)}',
      );
      if (fixture != null) save(fixture, reply);
      return (reply, null);
    } on VkException catch (error) {
      print(
        '$label: VK error code ${error.code} in '
        '${watch.elapsedMilliseconds} ms: ${blank(error.message)}',
      );
      if (fixture != null) {
        save(fixture, {
          'error': {
            'error_code': error.code,
            'error_msg': blank(error.message),
          },
        });
      }
      return (null, error.code);
    }
  }

  List<Map<String, dynamic>> itemsOf(Object? reply) => switch (reply) {
    {'items': final List items} =>
      items.whereType<Map<String, dynamic>>().toList(),
    final List items => items.whereType<Map<String, dynamic>>().toList(),
    _ => const [],
  };

  try {
    await client.ensureToken();
    print('probe_recs_feedback ${DateTime.now().toIso8601String()}');

    // The library: own keys and track ids, and an own upload with no track id.
    final library = await client.call('audio.get', {'count': '500'}) as Map;
    final own = (library['items'] as List).cast<Map<String, dynamic>>();
    final ownKeys = own.map(keyOf).toSet();
    final ownTracks = {
      for (final i in own)
        if (i['track_id'] != null) '${i['track_id']}',
    };
    print(
      'library: ${library['count']} songs, '
      '${own.where((i) => i['track_id'] == null).length} with no track id',
    );
    bool owned(Map<String, dynamic> i) =>
        ownKeys.contains(keyOf(i)) ||
        (i['track_id'] != null && ownTracks.contains('${i['track_id']}'));

    // A6 part 1: which names VK knows.
    print('\n== A6: feedback method names (no parameters) ==');
    final known = <String, int?>{};
    for (final name in candidates) {
      final (_, code) = await timed(name, name, const {});
      if (code != 3) known[name] = code;
    }
    print('known names (not code 3): $known');

    // A3: when VK last updated the generated lists.
    print('\n== A3: generated lists update_time ==');
    final (page, _) = await timed('catalog.getAudio', 'catalog.getAudio', {
      'need_blocks': '1',
    });
    final generated = [
      for (final p in ((page as Map?)?['playlists'] as List? ?? const []))
        if (p is Map<String, dynamic> && p['type'] == 'generated') p,
    ];
    for (final (index, p) in generated.indexed) {
      final reply = await client.call('audio.getPlaylistById', {
        'owner_id': '${p['owner_id']}',
        'playlist_id': '${p['id']}',
        'access_key': '${p['access_key']}',
      }) as Map;
      String at(Object? seconds) => seconds is int
          ? DateTime.fromMillisecondsSinceEpoch(
              seconds * 1000,
              isUtc: true,
            ).toIso8601String()
          : '-';
      print(
        '  list ${index + 1} "${reply['title']}": update_time '
        '${at(reply['update_time'])} UTC, create_time '
        '${at(reply['create_time'])} UTC, page says ${at(p['update_time'])}',
      );
    }

    // C5: target_audio with other kinds of songs.
    print('\n== C5: getRecommendations target_audio ==');
    final (plain, _) = await timed(
      'getRecommendations (to pick a found song)',
      'audio.getRecommendations',
      {'count': '30'},
    );
    final found = itemsOf(plain)
        .where((i) => !owned(i) && i['content_restricted'] == null)
        .toList();
    Future<void> similar(String label, String target, String? fixture) async {
      final (reply, _) = await timed(label, 'audio.getRecommendations', {
        'target_audio': target,
        'count': '30',
      }, fixture: fixture);
      final items = itemsOf(reply);
      if (reply != null) {
        print(
          '  ${items.length} songs, ${items.where(owned).length} owned, '
          '${items.where((i) => i['content_restricted'] != null).length} restricted, '
          'count field ${(reply as dynamic) is Map ? (reply as Map)['count'] : '-'}',
        );
      }
    }

    if (found.isNotEmpty) {
      final song = found.first;
      print(
        'found song: track id ${song['track_id'] == null ? 'none' : 'yes'}, '
        'access key ${song['access_key'] == null ? 'none' : 'yes'}',
      );
      await similar(
        'target = found song (owner_id)',
        keyOf(song),
        'audio_get_recommendations_target_found',
      );
      if (song['access_key'] != null) {
        await similar(
          'target = found song with access key',
          '${keyOf(song)}_${song['access_key']}',
          null,
        );
      }
      // Twice the same target: the same songs or reshuffled?
      final (a, _) = await timed(
        'same target again (1)',
        'audio.getRecommendations',
        {'target_audio': keyOf(song), 'count': '30'},
      );
      final (b, _) = await timed(
        'same target again (2)',
        'audio.getRecommendations',
        {'target_audio': keyOf(song), 'count': '30'},
      );
      final ka = itemsOf(a).map(keyOf).toSet(),
          kb = itemsOf(b).map(keyOf).toSet();
      print(
        '  same target twice: ${ka.length} and ${kb.length}, '
        '${ka.intersection(kb).length} in both',
      );
      // Paging: an offset.
      final (paged, _) = await timed(
        'same target offset 30',
        'audio.getRecommendations',
        {'target_audio': keyOf(song), 'count': '30', 'offset': '30'},
      );
      final kp = itemsOf(paged).map(keyOf).toSet();
      print(
        '  offset 30: ${kp.length} songs, ${kp.intersection(ka).length} '
        'also in the first page',
      );
    } else {
      print('no found song to try');
    }
    final noTrack = own.where((i) => i['track_id'] == null).firstOrNull;
    if (noTrack != null) {
      await similar(
        'target = own upload with no track id',
        keyOf(noTrack),
        'audio_get_recommendations_target_no_track_id',
      );
    }
    // Every upload with no track id: does its VK release, or the first
    // search hit with a track id, give similar songs instead?
    var withRelease = 0, releaseGives = 0, searchGives = 0, tried = 0;
    for (final upload in own.where((i) => i['track_id'] == null)) {
      tried++;
      final release = upload['release_audio_id'] as String?;
      if (release != null && release.isNotEmpty) {
        withRelease++;
        final reply = await client.call('audio.getRecommendations', {
          'target_audio': release,
          'count': '30',
        });
        if (itemsOf(reply).isNotEmpty) releaseGives++;
      }
      final hits = itemsOf(
        await client.call('audio.search', {
          'q': '${upload['artist']} ${upload['title']}',
          'count': '10',
        }),
      ).where((i) => i['track_id'] != null);
      if (hits.isNotEmpty) {
        final reply = await client.call('audio.getRecommendations', {
          'target_audio': keyOf(hits.first),
          'count': '30',
        });
        if (itemsOf(reply).isNotEmpty) searchGives++;
      }
    }
    print(
      'uploads with no track id: $tried; with release_audio_id $withRelease, '
      'release gives songs $releaseGives; first search hit with a track id '
      'gives songs $searchGives',
    );
    final restricted = itemsOf(plain)
        .where((i) => i['content_restricted'] != null)
        .firstOrNull;
    if (restricted != null) {
      await similar(
        'target = restricted song '
        '(code ${restricted['content_restricted']})',
        keyOf(restricted),
        null,
      );
    }
    await similar(
      'target = an id that does not exist',
      '${client.userId}_1',
      'audio_get_recommendations_target_missing',
    );
    await similar('target = not an id', 'nonsense', null);

    // A6 part 2: dislike one mix song and take it back.
    if (args.contains('--dislike')) {
      print('\n== A6: dislike experiment ==');
      final before = <String>{};
      final artistsBefore = <String>{};
      Map<String, dynamic>? victim;
      for (var round = 1; round <= 3; round++) {
        final (reply, _) = await timed(
          'mix before, round $round',
          'audio.getStreamMixAudios',
          {'mix_id': 'common', 'count': '10'},
        );
        for (final i in itemsOf(reply)) {
          before.add(keyOf(i));
          artistsBefore.add('${i['artist']}'.toLowerCase());
          if (victim == null && !owned(i)) victim = i;
        }
      }
      if (victim == null) {
        print('no mix song to dislike');
      } else {
        final key = keyOf(victim);
        final withKey = '${key}_${victim['access_key']}';
        Future<Object?> flag(String when) async {
          final reply = await client.call('audio.getById', {'audios': withKey});
          final item = itemsOf(reply).firstOrNull;
          print('  dislike flag $when: ${item?['dislike']}');
          return item?['dislike'];
        }

        await flag('before');
        // Parameter names tried in order until VK accepts one.
        final tries = <Map<String, String>>[
          {'audio_ids': key},
          {'audio_id': key},
          {'audio_ids': withKey},
          {'owner_id': '${victim['owner_id']}', 'audio_id': '${victim['id']}'},
          {'audios': key},
        ];
        String? used;
        Map<String, String>? usedParams;
        for (final name in [
          'audio.addDislike',
          'audio.dislike',
          'audio.setDislike',
        ]) {
          if (!known.containsKey(name)) continue;
          for (final params in tries) {
            final (reply, code) = await timed(
              '$name with ${params.keys.join('+')}',
              name,
              params,
              fixture: 'audio_add_dislike',
            );
            if (code == null) {
              print(
                '  reply: ${reply is int || reply is bool ? reply : topShape(reply)}',
              );
              used = name;
              usedParams = params;
              break;
            }
          }
          if (used != null) break;
        }
        if (used == null) {
          print('no dislike call was accepted');
        } else {
          await flag('after $used');
          final after = <String>{};
          var repeatArtists = 0;
          for (var round = 1; round <= 6; round++) {
            final (reply, _) = await timed(
              'mix after, round $round',
              'audio.getStreamMixAudios',
              {'mix_id': 'common', 'count': '10'},
            );
            for (final i in itemsOf(reply)) {
              after.add(keyOf(i));
              if ('${i['artist']}'.toLowerCase() ==
                  '${victim['artist']}'.toLowerCase()) {
                repeatArtists++;
              }
            }
          }
          print(
            '  mix after: ${after.length} songs, disliked song again: '
            '${after.contains(key)}, same artist songs: $repeatArtists, '
            'songs also seen before: ${after.intersection(before).length}',
          );
          // Take it back.
          final undo = used == 'audio.addDislike'
              ? 'audio.removeDislike'
              : used == 'audio.dislike'
              ? 'audio.undislike'
              : null;
          if (undo != null && known.containsKey(undo)) {
            await timed(
              '$undo with ${usedParams!.keys.join('+')}',
              undo,
              usedParams,
              fixture: 'audio_remove_dislike',
            );
            await flag('after $undo');
          } else {
            print('  NO UNDO METHOD: the dislike stays on the test account');
          }
        }
      }
    }
  } on VkException catch (error) {
    print('failed: code ${error.code}: ${blank(error.message)}');
  } finally {
    client.close();
  }
}
