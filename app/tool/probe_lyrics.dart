// Read-only probe for plan 10 (lyrics): what VK gives for a song's lyrics.
//
//   dart run tool/probe_lyrics.dart --vk-session FILE [--count 200]
//       [--asks 60]
//
// Steps: audio.get (the account's songs); count the lyrics flags; then
// audio.getLyrics for songs with and without the flag, in a few argument
// forms, and print the reply's field paths, line and timestamp counts,
// timing units against the song length and how long each call took.
// No song name, lyric line, link, key or token is printed: only field
// names, counts, numbers and error codes.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
  );
  final asks = int.parse(valueOf('--asks') ?? '60');
  try {
    final reply = await client.call('audio.get', {
      'count': valueOf('--count') ?? '200',
    }) as Map<String, dynamic>;
    final songs = (reply['items'] as List).cast<Map<String, dynamic>>();
    print('${songs.length} songs');

    // Every field on a song whose name mentions lyrics, with its kinds.
    final lyricFields = <String, Map<String, int>>{};
    for (final song in songs) {
      for (final MapEntry(:key, :value) in song.entries) {
        if (!key.toLowerCase().contains('lyric')) continue;
        final byValue = lyricFields.putIfAbsent(key, () => {});
        final shown = switch (value) {
          bool() || int() => '$value',
          null => 'empty',
          _ => kindOf(value),
        };
        byValue[shown] = (byValue[shown] ?? 0) + 1;
      }
    }
    print('lyrics fields on songs: $lyricFields');

    bool flagged(Map<String, dynamic> song) =>
        song['has_lyrics'] == true ||
        song['has_lyrics'] == 1 ||
        song['lyrics_id'] != null;
    final withFlag = songs.where(flagged).toList();
    final withoutFlag = songs.where((song) => !flagged(song)).toList();
    print('flagged ${withFlag.length}, not flagged ${withoutFlag.length}');

    // Which argument form works, on the first flagged song.
    if (withFlag.isNotEmpty) {
      final song = withFlag.first;
      final full = '${song['owner_id']}_${song['id']}';
      final forms = <String, Map<String, String>>{
        'audio_id=owner_id': {'audio_id': full},
        'audio_id=id + owner_id': {
          'audio_id': '${song['id']}',
          'owner_id': '${song['owner_id']}',
        },
        if (song['lyrics_id'] != null)
          'lyrics_id': {'lyrics_id': '${song['lyrics_id']}'},
        if (song['access_key'] != null)
          'audio_id=owner_id_key': {
            'audio_id': '${full}_${song['access_key']}',
          },
      };
      for (final MapEntry(key: name, value: params) in forms.entries) {
        await pause();
        final clock = Stopwatch()..start();
        try {
          final answer = await client.call('audio.getLyrics', params);
          print(
            'form $name: OK in ${clock.elapsedMilliseconds} ms, '
            'paths ${pathsOf(answer).join(', ')}',
          );
        } on VkException catch (error) {
          print(
            'form $name: error ${error.code} in '
            '${clock.elapsedMilliseconds} ms',
          );
        }
      }
    }

    // Many songs with the working form: counts and timing units.
    final pathCounts = <String, int>{};
    final outcomes = <String, int>{};
    final callMs = <int>[];
    var timed = 0, plainOnly = 0, cyrillic = 0, latin = 0, mixed = 0;
    final languages = <String, int>{};
    final endVsLength = <String>[];
    var textLines = 0, emptyTextLines = 0, creditsSet = 0;
    final md5s = <String, String>{};
    Future<void> ask(Map<String, dynamic> song, String group) async {
      await pause();
      final clock = Stopwatch()..start();
      try {
        final answer = await client.call('audio.getLyrics', {
          'audio_id': '${song['owner_id']}_${song['id']}',
        });
        callMs.add(clock.elapsedMilliseconds);
        for (final path in pathsOf(answer)) {
          pathCounts[path] = (pathCounts[path] ?? 0) + 1;
        }
        final lyrics = answer is Map ? answer['lyrics'] : null;
        if (lyrics is! Map) {
          bump(outcomes, '$group: no lyrics object');
          return;
        }
        final credits = answer is Map ? answer['credits'] : null;
        if (credits is String && credits.trim().isNotEmpty) creditsSet++;
        final md5 = answer is Map ? answer['md5'] : null;
        if (md5 is String) md5s['${song['owner_id']}_${song['id']}'] = md5;
        final language = lyrics['language'];
        if (language != null) bump(languages, '$language');
        final stamps = lyrics['timestamps'];
        final text = lyrics['text'];
        final lines = <String>[
          if (stamps is List)
            for (final stamp in stamps)
              if (stamp is Map && stamp['line'] is String)
                stamp['line'] as String,
          if (text is List)
            for (final line in text)
              if (line is String) line,
          if (text is String) ...text.split('\n'),
        ];
        if (text is List) {
          textLines += text.length;
          emptyTextLines += text
              .where((line) => '${line ?? ''}'.trim().isEmpty)
              .length;
        }
        final hasCyr = lines.any(
          (l) => l.runes.any((c) => c >= 0x400 && c <= 0x4FF),
        );
        final hasLat = lines.any((l) => RegExp('[A-Za-z]').hasMatch(l));
        if (hasCyr && hasLat) {
          mixed++;
        } else if (hasCyr) {
          cyrillic++;
        } else if (hasLat) {
          latin++;
        }
        if (stamps is List && stamps.isNotEmpty) {
          timed++;
          final ends = [
            for (final stamp in stamps)
              if (stamp is Map && stamp['end'] is num) stamp['end'] as num,
          ];
          final begins = [
            for (final stamp in stamps)
              if (stamp is Map && stamp['begin'] is num) stamp['begin'] as num,
          ];
          final empty = stamps
              .where((s) => s is Map && '${s['line'] ?? ''}'.trim().isEmpty)
              .length;
          final sorted = [
            for (var i = 1; i < begins.length; i++) begins[i] >= begins[i - 1],
          ].every((ok) => ok);
          if (endVsLength.length < 12) {
            endVsLength.add(
              '${stamps.length} stamps (empty lines $empty, in order '
              '$sorted), first begin ${begins.isEmpty ? '-' : begins.first}, '
              'last end ${ends.isEmpty ? '-' : ends.last}, '
              'song ${song['duration']} s',
            );
          }
          bump(outcomes, '$group: timed');
        } else if (lines.isNotEmpty) {
          plainOnly++;
          bump(outcomes, '$group: text only');
        } else {
          bump(outcomes, '$group: empty');
        }
      } on VkException catch (error) {
        callMs.add(clock.elapsedMilliseconds);
        bump(outcomes, '$group: error ${error.code}');
      }
    }

    final flaggedAsks = withFlag.take(asks).toList();
    final plainAsks = withoutFlag.take(asks ~/ 3).toList();
    for (final song in flaggedAsks) {
      await ask(song, 'flagged');
    }
    for (final song in plainAsks) {
      await ask(song, 'not flagged');
    }
    print('asked ${flaggedAsks.length} flagged, ${plainAsks.length} not');
    print('outcomes: $outcomes');
    print('timed $timed, text only $plainOnly');
    print('scripts: cyrillic $cyrillic, latin $latin, mixed $mixed');
    print('languages: $languages');
    final paths = pathCounts.keys.toList()..sort();
    for (final path in paths) {
      print('${pathCounts[path].toString().padLeft(4)}  $path');
    }
    callMs.sort();
    if (callMs.isNotEmpty) {
      print(
        'call ms: p50 ${callMs[callMs.length ~/ 2]}, '
        'p90 ${callMs[(callMs.length * 0.9).floor().clamp(0, callMs.length - 1)]}, '
        'max ${callMs.last}',
      );
    }
    endVsLength.forEach(print);
    print(
      'text lines $textLines, of them empty (stanza breaks?) '
      '$emptyTextLines; credits filled $creditsSet',
    );

    // The same song asked again: does md5 stay the same?
    var sameMd5 = 0, otherMd5 = 0;
    for (final song in flaggedAsks.take(5)) {
      await pause();
      final id = '${song['owner_id']}_${song['id']}';
      final again = await client.call('audio.getLyrics', {'audio_id': id});
      if (again is Map && again['md5'] == md5s[id]) {
        sameMd5++;
      } else {
        otherMd5++;
      }
    }
    print('asked again: md5 same $sameMd5, different $otherMd5');

    // Songs without lyrics: do other VK uploads of the same song have them?
    final alternatives = int.parse(valueOf('--alternatives') ?? '15');
    var helped = 0;
    for (final song in withoutFlag.take(alternatives)) {
      await pause();
      try {
        final found = await client.call('audio.search', {
          'q': '${song['artist']} ${song['title']}',
          'count': '30',
        }) as Map<String, dynamic>;
        final items = (found['items'] as List).cast<Map<String, dynamic>>();
        final length = song['duration'] as int? ?? 0;
        final flaggedFound = items.where(flagged).toList();
        final sameLength = flaggedFound
            .where(
              (item) => ((item['duration'] as int? ?? -99) - length).abs() <= 2,
            )
            .length;
        if (sameLength > 0) helped++;
        print(
          'no-lyrics song: ${items.length} found, ${flaggedFound.length} '
          'with lyrics, $sameLength of them the same length',
        );
      } on VkException catch (error) {
        print('no-lyrics song: search error ${error.code}');
      }
    }
    print(
      'songs without lyrics with a same-length VK upload that has them: '
      '$helped of ${withoutFlag.take(alternatives).length}',
    );
  } on Object catch (error) {
    print(
      'failed: ${error.runtimeType} ${error is VkException ? error.code : ''}',
    );
  } finally {
    client.close();
  }
}

void bump(Map<String, int> counts, String key) =>
    counts[key] = (counts[key] ?? 0) + 1;

/// Stays under VK's few calls a second.
Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 400));

String kindOf(Object? value) => switch (value) {
  Map() => 'object',
  List() => 'list',
  String() => 'text',
  int() || double() => 'number',
  bool() => 'yes/no',
  null => 'empty',
  _ => 'other',
};

/// Field paths with kinds, into objects and the first element of lists.
List<String> pathsOf(Object? value, [String prefix = '', int depth = 0]) {
  final out = <String>[];
  if (value is Map) {
    for (final MapEntry(:key, value: inner) in value.entries) {
      final path = '$prefix$key';
      out.add('$path (${kindOf(inner)})');
      if (depth < 4) out.addAll(pathsOf(inner, '$path.', depth + 1));
    }
  } else if (value is List && value.isNotEmpty && depth < 4) {
    final first = value.first;
    if (first is Map || first is List) {
      out.addAll(
        pathsOf(
          first,
          '${prefix.replaceAll(RegExp(r'\.$'), '')}[].',
          depth + 1,
        ),
      );
    }
  }
  return out;
}
