// What VK gives as recommendations to the web client (plan 07, A1-A4): the
// sections and blocks of the music page (catalog.getAudio, catalog.getSection),
// the songs and playlists they point at, a few older recommendation methods,
// and whether the songs stream.
//
// READ ONLY: nothing is added, removed, liked or hidden on VK.
//
// Prints an ALLOWLIST of named fields only: section, block and playlist titles,
// kinds, counts, artist, title, length, yes/no flags and error codes. Never a
// link, key, token, id or whole reply. With --counts-only (for the second
// account) no song or playlist name is printed either.
//
// Run from app/:
//   dart run tool/probe_recommendations.dart --vk-session FILE [--counts-only]
//     [--streams N] [--decode N] [--save-lists FILE] [--fixtures DIR]
//
// --fixtures writes scrubbed copies of the replies (Scrubber) for the unit
// tests' fakes; never with the second account.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ownsemble/vk/vk_client.dart';

/// Long numbers blanked, so an id inside an error text never shows.
String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

/// A song's key as VK's block lists name it: ownerId_audioId.
String keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

/// Lowercase "artist - title", for the same-name match with the library.
String textOf(Map<String, dynamic> item) =>
    '${item['artist']} - ${item['title']}'.toLowerCase().trim();

bool isQuestionMarkName(Map<String, dynamic> item) =>
    '${item['artist']}${item['title']}'.contains('??');

/// Who owns a playlist, as a kind only: the account itself, a group (VK's own
/// lists live in groups) or another user.
String ownerKind(Object? ownerId, int me) => switch (ownerId) {
  final int id when id == me => 'own',
  final int id when id < 0 => 'group',
  int() => 'user',
  _ => 'none',
};

/// Field paths of a song (names and kinds only, one level deep).
Set<String> fieldPaths(Map<String, dynamic> map, [String prefix = '']) {
  final seen = <String>{};
  for (final MapEntry(:key, :value) in map.entries) {
    final path = '$prefix$key';
    seen.add(path);
    if (value is Map<String, dynamic> && prefix.isEmpty) {
      seen.addAll(fieldPaths(value, '$path.'));
    } else if (value is List &&
        value.isNotEmpty &&
        value.first is Map<String, dynamic> &&
        prefix.isEmpty) {
      seen.addAll(fieldPaths(value.first as Map<String, dynamic>, '$path[].'));
    }
  }
  return seen;
}

/// The shape of a reply's top level: key names with the length of lists and
/// the key names of objects. No values.
String topShape(Object? reply) => switch (reply) {
  Map() => [
    for (final MapEntry(:key, :value) in reply.entries)
      switch (value) {
        List() => '$key[${value.length}]',
        Map() => '$key{${value.keys.join(',')}}',
        _ => '$key(${value.runtimeType})',
      },
  ].join(' '),
  List() => 'list of ${reply.length}',
  _ => 'a ${reply.runtimeType}',
};

/// Decodes the first 3 s of [link] with ffmpeg (no sound output) and says
/// how much audio came out. ffmpeg's own text is never printed: its errors
/// would name the link.
Future<String> decode(Uri link) async {
  final watch = Stopwatch()..start();
  final result = await Process.run('ffmpeg', [
    '-hide_banner', '-nostats', '-loglevel', 'quiet', //
    '-t', '3', '-i', '$link', '-f', 'null', '-progress', 'pipe:1', '-',
  ]);
  final times = RegExp(r'out_time_us=(\d+)')
      .allMatches('${result.stdout}')
      .map((m) => int.parse(m.group(1)!));
  final seconds = times.isEmpty ? 0 : times.last / 1e6;
  return 'decoded ${seconds.toStringAsFixed(1)} s '
      '(ffmpeg exit ${result.exitCode}, ${watch.elapsedMilliseconds} ms)';
}

/// Makes a real reply safe to commit as a test fixture (A5) while keeping its
/// shape: every key, list length, number kind and reference stays, and only
/// the values that could identify or open something are replaced.
///
/// - Links become `https://example.invalid/N` (an .m3u8 link keeps its
///   ending, so a fake can still tell a playlist link).
/// - Ids (numbers of 5 or more digits, and "owner_id" texts such as
///   `-123_456` or `123_456_key`) get made-up ids, the same real id always
///   the same made-up one, so `audios_ids` still point at the `audios` list.
/// - Keys, hashes, codes and other opaque texts become `opaque-N`, again
///   consistently (section and block ids, next_from stay usable).
/// - Kept as they are: names a user reads (artist, title, list titles and
///   VK's own texts), short lower-case kinds (`music_audios`, `generated`)
///   and times (date, create_time, update_time).
class Scrubber {
  final _ids = <int, int>{};
  final _texts = <String, String>{};

  static const _readable = {
    'artist',
    'title',
    'name',
    'subtitle',
    'percentage_title',
    'text',
    'main_color',
    'color',
  };

  /// Lists whose every text is made opaque: people (other users who own a
  /// "listen to each other" playlist, the account itself) and groups.
  static const _people = {'profiles', 'groups'};
  static const _times = {'date', 'create_time', 'update_time'};

  int _id(int real) =>
      _ids.putIfAbsent(real.abs(), () => 10000 + _ids.length) * real.sign;

  String _opaque(String real) =>
      _texts.putIfAbsent(real, () => 'opaque-${_texts.length + 1}');

  Object? scrub(Object? value, [String key = '', bool person = false]) =>
      switch (value) {
        Map() => {
          for (final MapEntry(key: k, value: v) in value.entries)
            '$k': scrub(v, '$k', person || _people.contains(k)),
        },
        List() => [for (final v in value) scrub(v, key, person)],
        final int number when _times.contains(key) => number,
        final int number when number.abs() >= 10000 => _id(number),
        final String text when person && text.isNotEmpty =>
          text.startsWith('http') ? _scrubText(text, '') : _opaque(text),
        final String text => _scrubText(text, key),
        _ => value,
      };

  String _scrubText(String text, String key) {
    if (text.isEmpty) return text;
    if (RegExp(r'^https?://').hasMatch(text)) {
      // The path's ending stays (.mp3, .m3u8, .jpg): a fake may need it.
      final uri = Uri.tryParse(text);
      final ending =
          RegExp(r'\.\w{2,5}$').firstMatch(uri?.path ?? '')?[0] ?? '';
      // A page link such as vk.ru/audios<id>?section=general keeps its
      // section (the path holds the account id, so it goes); signed links
      // lose their whole query.
      final query = uri != null && uri.queryParameters.keys.join() == 'section'
          ? '?section=${uri.queryParameters['section']}'
          : '';
      return _texts.putIfAbsent(
        text,
        () => 'https://example.invalid/${_texts.length + 1}$ending$query',
      );
    }
    // "owner_id", "owner_id_key" and "owner_id_id_key" texts: ids remapped,
    // a trailing key made opaque.
    // The account's generated lists have small negative ids ("me_-21").
    // Small numbers stay as they are, as in [scrub], so a text id and the
    // object it names still agree.
    final ids = RegExp(r'^(-?\d+)_(-?\d+)(?:_(\w+))?$').firstMatch(text);
    int part(String digits) {
      final number = int.parse(digits);
      return number.abs() >= 10000 ? _id(number) : number;
    }

    if (ids != null) {
      final owner = part(ids.group(1)!);
      final id = part(ids.group(2)!);
      final rest = ids.group(3);
      return '${owner}_$id${rest == null ? '' : '_${_opaque(rest)}'}';
    }
    if (RegExp(r'^-?\d+$').hasMatch(text)) {
      final number = int.parse(text);
      return number.abs() >= 10000 ? '${_id(number)}' : text;
    }
    // Keys and hashes can look like short lower-case words: they go first.
    if (key.contains('key') || key.contains('hash')) return _opaque(text);
    if (_readable.contains(key)) return text;
    if (RegExp(r'^[a-z_]{1,40}$').hasMatch(text)) return text;
    return _opaque(text);
  }
}

class Probe {
  Probe(this.client, {required this.countsOnly});

  final VkClient client;
  final bool countsOnly;

  /// Every song seen in any reply, by key.
  final songs = <String, Map<String, dynamic>>{};

  /// Every playlist seen in any reply, by ownerId_playlistId.
  final playlists = <String, Map<String, dynamic>>{};

  /// Which lists (block or playlist titles) each song was in.
  final listsOf = <String, Set<String>>{};

  /// The first song block that has a next page: its id and next_from.
  (String, String)? pagedBlock;

  /// Section ids already asked for, so a section is read once.
  final readSections = <String>{};

  final ownKeys = <String>{};
  final ownTracks = <String>{};
  final ownTexts = <String, List<int>>{};

  /// Where scrubbed copies of replies go (A5), or null.
  String? fixtureDir;
  final scrubber = Scrubber();

  Future<Object?> timed(
    String label,
    String method,
    Map<String, String> p, {
    String? fixture,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final reply = await client.call(method, p);
      print(
        '$label: OK in ${watch.elapsedMilliseconds} ms: ${topShape(reply)}',
      );
      if (fixture != null && fixtureDir != null) saveFixture(fixture, reply);
      return reply;
    } on VkException catch (error) {
      print(
        '$label: VK error code ${error.code} in '
        '${watch.elapsedMilliseconds} ms: ${blank(error.message)}',
      );
    } catch (error) {
      print('$label: failed ${error.runtimeType}: ${blank(error)}');
    }
    return null;
  }

  /// Writes a scrubbed copy of [reply] as `<name>.json`, once per name.
  void saveFixture(String name, Object? reply) {
    final file = File('$fixtureDir/$name.json');
    if (file.existsSync() && _saved.contains(name)) return;
    _saved.add(name);
    // A paged list keeps its first 12 songs, the reply VK gives to count=12
    // (count stays the whole list's length), so the files stay small.
    if (reply case {'items': final List items} when items.length > 12) {
      reply = {...reply, 'items': items.take(12).toList()};
    }
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent(' ').convert(scrubber.scrub(reply))}\n',
    );
    print('  fixture $name.json saved');
  }

  final _saved = <String>{};

  /// Remembers the songs and playlists a catalog reply carries.
  void collect(Map<String, dynamic> reply) {
    for (final item in (reply['audios'] as List? ?? const [])) {
      if (item is Map<String, dynamic>) songs[keyOf(item)] = item;
    }
    for (final item in (reply['playlists'] as List? ?? const [])) {
      if (item is Map<String, dynamic>) playlists[keyOf(item)] = item;
    }
  }

  String songLine(Map<String, dynamic> item) {
    final flags = <String>[
      if ((item['url'] as String? ?? '').isEmpty) 'NO LINK',
      if (item['content_restricted'] != null)
        'restricted ${item['content_restricted']}',
      if (item['access_key'] == null) 'no key',
      if (item['track_code'] == null) 'no track_code',
      if (item['album'] == null) 'no album',
      if (item['release_audio_id'] != null) 'has release',
      if (item['is_explicit'] == true) 'explicit',
      if (isQuestionMarkName(item)) 'QUESTION MARKS',
      if (owned(item) case final why?) 'OWNED ($why)',
    ];
    final name = countsOnly ? 'song' : '${item['artist']} - ${item['title']}';
    return '$name (${item['duration']} s)'
        '${flags.isEmpty ? '' : ' [${flags.join(', ')}]'}';
  }

  /// Why the library already has [item], or null: same key, same VK track
  /// id, or the same name with a length within 2 s.
  String? owned(Map<String, dynamic> item) {
    if (ownKeys.contains(keyOf(item))) return 'same key';
    final trackId = (item['track_id'] ?? '').toString();
    if (trackId.isNotEmpty && ownTracks.contains(trackId)) return 'track id';
    final lengths = ownTexts[textOf(item)];
    final length = item['duration'] as int? ?? -99;
    if (lengths != null && lengths.any((l) => (l - length).abs() <= 2)) {
      return 'name and length';
    }
    if (lengths != null) return 'name only, other length';
    return null;
  }

  /// Prints a section's blocks and the songs they point at.
  void describeBlocks(String sectionTitle, List blocks) {
    for (final block in blocks.whereType<Map<String, dynamic>>()) {
      final layout = block['layout'] as Map<String, dynamic>? ?? const {};
      final title = (layout['title'] as String?) ?? '';
      final lists = <String>[
        for (final MapEntry(:key, :value) in block.entries)
          if (key.endsWith('_ids') && value is List) '$key ${value.length}',
      ];
      final buttons = [
        for (final b in (block['buttons'] as List? ?? const []))
          if (b is Map)
            '${(b['action'] as Map?)?['type']}'
                '${countsOnly ? '' : ' "${b['title']}"'}',
      ];
      print(
        '  block ${block['data_type']} / ${layout['name']}'
        '${title.isEmpty || countsOnly ? '' : ' "$title"'}'
        '${lists.isEmpty ? '' : ': ${lists.join(', ')}'}'
        '${block['next_from'] == null ? '' : ', has next_from'}'
        '${buttons.isEmpty ? '' : ', buttons ${buttons.join('; ')}'}',
      );
      if (pagedBlock == null &&
          block['data_type'] == 'music_audios' &&
          block['next_from'] != null) {
        pagedBlock = ('${block['id']}', '${block['next_from']}');
      }
      final label =
          '$sectionTitle / ${title.isEmpty ? block['data_type'] : title}';
      for (final id in (block['audios_ids'] as List? ?? const [])) {
        (listsOf['$id'] ??= {}).add(label);
      }
      if (!countsOnly) {
        for (final id in (block['audios_ids'] as List? ?? const []).take(8)) {
          final item = songs['$id'];
          print('    ${item == null ? 'song not in reply' : songLine(item)}');
        }
        for (final id in (block['playlists_ids'] as List? ?? const []).take(
          12,
        )) {
          final item = playlists['$id'];
          print(
            '    ${item == null ? 'playlist not in reply' : playlistLine(item)}',
          );
        }
      }
    }
  }

  String playlistLine(Map<String, dynamic> item) {
    final me = client.userId;
    final title = countsOnly ? 'playlist' : '"${item['title']}"';
    return 'playlist $title, ${item['count']} songs, type ${item['type']}, '
        'owner ${ownerKind(item['owner_id'], me)}'
        '${item['access_key'] == null ? '' : ', has access_key'}'
        '${item['is_following'] == true ? ', followed' : ''}';
  }

  /// Reads one catalog section by id and prints it.
  Future<void> readSection(String id, String title) async {
    if (!readSections.add(id)) return;
    final reply = await timed(
      'catalog.getSection "${countsOnly ? 'section' : title}"',
      'catalog.getSection',
      {'section_id': id},
    );
    if (reply is! Map<String, dynamic>) return;
    collect(reply);
    final section = reply['section'] as Map<String, dynamic>? ?? const {};
    describeBlocks(title, section['blocks'] as List? ?? const []);
    if (section['next_from'] != null) print('  section has next_from');
  }

  /// Reads the songs of one playlist: getPlaylistById, then audio.get.
  Future<void> readPlaylist(Map<String, dynamic> item) async {
    final params = {
      'owner_id': '${item['owner_id']}',
      'playlist_id': '${item['id']}',
      if (item['access_key'] != null) 'access_key': '${item['access_key']}',
    };
    final name = countsOnly ? 'playlist' : '"${item['title']}"';
    final generated = item['type'] == 'generated';
    await timed(
      'audio.getPlaylistById $name',
      'audio.getPlaylistById',
      params,
      fixture: generated ? 'audio_get_playlist_by_id_generated' : null,
    );
    final reply = await timed('audio.get of $name', 'audio.get', {
      'owner_id': params['owner_id']!,
      'album_id': params['playlist_id']!,
      if (params['access_key'] != null) 'access_key': params['access_key']!,
      'count': '100',
    }, fixture: generated ? 'audio_get_generated_playlist' : null);
    if (reply is! Map<String, dynamic>) return;
    final items = (reply['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    print('  count ${reply['count']}, items ${items.length}');
    for (final song in items) {
      songs.putIfAbsent(keyOf(song), () => song);
      (listsOf[keyOf(song)] ??= {}).add('playlist ${item['title']}');
    }
    if (!countsOnly) {
      for (final song in items.take(6)) {
        print('    ${songLine(song)}');
      }
    }
  }
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final countsOnly = args.contains('--counts-only');
  final streamChecks = int.parse(valueOf('--streams') ?? '12');
  final decodes = int.parse(valueOf('--decode') ?? '4');
  final saveLists = valueOf('--save-lists');
  final fixtureDir = valueOf('--fixtures');
  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    // A big library comes in one slow reply (the sync's limits).
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
  );
  final probe = Probe(client, countsOnly: countsOnly)
    ..fixtureDir = countsOnly ? null : fixtureDir;
  if (fixtureDir != null) Directory(fixtureDir).createSync(recursive: true);
  try {
    await client.ensureToken();
    print('probe_recommendations ${DateTime.now().toIso8601String()}');

    // The library, to tell which recommended songs the account already has.
    // Pages of 500: one big reply fails with code 13 "response size is too
    // big" on a 2000-song library.
    var total = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final library = await client.call('audio.get', {
        'count': '500',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      total = library['count'] as int;
      for (final item
          in (library['items'] as List).cast<Map<String, dynamic>>()) {
        probe.ownKeys.add(keyOf(item));
        if (item['track_id'] != null) {
          probe.ownTracks.add('${item['track_id']}');
        }
        (probe.ownTexts[textOf(item)] ??= []).add(
          item['duration'] as int? ?? 0,
        );
      }
    }
    print('library: $total songs');

    // 1. The music page as the web client loads it.
    print('\n== catalog.getAudio ==');
    final page = await probe.timed('catalog.getAudio', 'catalog.getAudio', {
      'need_blocks': '1',
    }, fixture: 'catalog_get_audio');
    final sections = <(String, String, String)>[];
    if (page is Map<String, dynamic>) {
      probe.collect(page);
      final catalog = page['catalog'] as Map<String, dynamic>? ?? const {};
      print('default section is set: ${catalog['default_section'] != null}');
      for (final s
          in (catalog['sections'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        final url = Uri.tryParse('${s['url'] ?? ''}');
        final tab = url?.queryParameters['section'] ?? url?.path ?? '';
        sections.add(('${s['id']}', '${s['title']}', tab));
        final isDefault = s['id'] == catalog['default_section'];
        print(
          'section ${countsOnly ? '' : '"${s['title']}" '}'
          '(url section=$tab)${isDefault ? ' DEFAULT' : ''}'
          '${s['blocks'] == null ? '' : ', ${(s['blocks'] as List).length} blocks inline'}',
        );
        if (s['blocks'] is List) {
          probe.readSections.add('${s['id']}');
          probe.describeBlocks('${s['title']}', s['blocks'] as List);
        }
      }
    }

    // 2. Every section's blocks.
    print('\n== sections ==');
    for (final (id, title, _) in sections) {
      await probe.readSection(id, title);
    }

    // 3. Pages the web client opens by link (tabs of vk.com/audio).
    print('\n== catalog.getAudio by url ==');
    for (final tab in ['recoms', 'explore', 'all', 'my', 'recent']) {
      final reply = await probe.timed(
        'catalog.getAudio section=$tab',
        'catalog.getAudio',
        {'url': 'https://vk.com/audio?section=$tab', 'need_blocks': '1'},
      );
      if (reply is Map<String, dynamic>) {
        probe.collect(reply);
        final catalog = reply['catalog'] as Map<String, dynamic>? ?? const {};
        for (final s
            in (catalog['sections'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()) {
          if (s['blocks'] is List && probe.readSections.add('${s['id']}')) {
            print('  section ${countsOnly ? '' : '"${s['title']}"'}');
            probe.describeBlocks('${s['title']}', s['blocks'] as List);
          }
        }
      }
    }

    // 4. Older methods.
    print('\n== older methods ==');
    final firstOwn = probe.ownKeys.isEmpty ? null : probe.ownKeys.first;
    for (final (label, method, params) in [
      ('audio.getRecommendations', 'audio.getRecommendations', {'count': '30'}),
      if (firstOwn != null)
        (
          'audio.getRecommendations target_audio (similar to an own song)',
          'audio.getRecommendations',
          {'target_audio': firstOwn, 'count': '30'},
        ),
      (
        'audio.getStreamMixAudios mix_id=common',
        'audio.getStreamMixAudios',
        {'mix_id': 'common', 'count': '10'},
      ),
      ('audio.getPopular', 'audio.getPopular', {'count': '10'}),
    ]) {
      final reply = await probe.timed(
        label,
        method,
        params,
        fixture: method == 'audio.getPopular'
            ? null
            : params.containsKey('target_audio')
            ? 'audio_get_recommendations_target'
            : method == 'audio.getRecommendations'
            ? 'audio_get_recommendations'
            : 'audio_get_stream_mix_audios',
      );
      final items = switch (reply) {
        {'items': final List items} => items,
        final List items => items,
        _ => const [],
      };
      final list = items.whereType<Map<String, dynamic>>().toList();
      for (final song in list) {
        probe.songs.putIfAbsent(keyOf(song), () => song);
        (probe.listsOf[keyOf(song)] ??= {}).add(label);
      }
      if (!countsOnly) {
        for (final song in list.take(5)) {
          print('    ${probe.songLine(song)}');
        }
      }
    }

    // 5. The songs of the recommended playlists (group-owned, i.e. VK's).
    // The account's own "generated" lists (For you, daily playlists) first:
    // their count is 0 in the page, so only reading them shows their songs.
    print('\n== playlists ==');
    final generated = probe.playlists.values
        .where((p) => p['type'] == 'generated')
        .toList();
    final others = probe.playlists.values
        .where(
          (p) =>
              p['type'] != 'generated' &&
              ownerKind(p['owner_id'], client.userId) != 'own',
        )
        .take(3)
        .toList();
    for (final item in [...generated, ...others]) {
      await probe.readPlaylist(item);
    }

    // The shapes of the mix and of the "listen to each other" entries.
    if (page is Map<String, dynamic>) {
      for (final name in ['audio_stream_mixes', 'recommended_playlists']) {
        final first = (page[name] as List? ?? const []).firstOrNull;
        if (first is Map<String, dynamic>) {
          print(
            '$name[0] keys: ${first.keys.join(', ')}'
            '${first['percentage'] == null ? '' : '; percentage ${first['percentage']}'}'
            '${first['audios'] is List ? '; audios ${(first['audios'] as List).length}' : ''}',
          );
        }
      }
    }

    // VK Mix: does each call give new songs?
    print('\n== VK Mix, 4 calls ==');
    final mixSeen = <String>{};
    for (var round = 1; round <= 4; round++) {
      final reply = await probe.timed(
        'audio.getStreamMixAudios round $round',
        'audio.getStreamMixAudios',
        {'mix_id': 'common', 'count': '10'},
      );
      if (reply is List) {
        final keys = reply.whereType<Map<String, dynamic>>().map(keyOf);
        final fresh = keys.where(mixSeen.add).length;
        print('  ${keys.length} songs, $fresh not seen in earlier rounds');
      }
    }

    // Paging of a song block: the next page by the block's next_from.
    print('\n== block paging ==');
    if (probe.pagedBlock case (final blockId, final nextFrom)?) {
      final reply = await probe.timed(
        'catalog.getBlockItems',
        'catalog.getBlockItems',
        {'block_id': blockId, 'start_from': nextFrom},
        fixture: 'catalog_get_block_items',
      );
      if (reply is Map<String, dynamic>) {
        final block = reply['block'] as Map<String, dynamic>? ?? const {};
        print(
          '  next page: ${(block['audios_ids'] as List? ?? const []).length} '
          'songs, next_from again: ${block['next_from'] != null}',
        );
      }
    }

    // Why restricted songs cannot play: one popup per code.
    print('\n== restriction popups ==');
    final byCode = <Object?, Map<String, dynamic>>{};
    for (final item in probe.songs.values) {
      final code = item['content_restricted'];
      if (code != null) byCode.putIfAbsent(code, () => item);
    }
    for (final MapEntry(key: code, value: item) in byCode.entries) {
      await probe.timed(
        '  audio.getById of a code $code song',
        'audio.getById',
        {'audios': '${keyOf(item)}_${item['access_key']}'},
        fixture: 'audio_get_by_id_restricted_$code',
      );
      try {
        final popup = await client.call('audio.getRestrictionPopup', {
          'audio_id': keyOf(item),
        });
        if (probe.fixtureDir != null) {
          probe.saveFixture('audio_get_restriction_popup_$code', popup);
        }
        if (popup is Map<String, dynamic>) {
          print('  code $code: "${popup['title']}" / "${popup['text']}"');
        } else {
          print('  code $code: popup ${popup.runtimeType}');
        }
      } on VkException catch (error) {
        print('  code $code: VK error code ${error.code}');
      }
    }

    // 6. Do the songs stream?
    // A sample of recommended songs the account does not have (seeded, so a
    // rerun picks alike), plus up to 5 restricted ones.
    final notOwned =
        probe.songs.values
            .where(
              (i) => probe.owned(i) == null && i['content_restricted'] == null,
            )
            .toList()
          ..shuffle(Random(7));
    final restrictedSongs = probe.songs.values
        .where((i) => i['content_restricted'] != null)
        .take(5);
    final sample = [...notOwned.take(streamChecks), ...restrictedSongs];
    print(
      '\n== streams (audio.getById: $streamChecks not owned, '
      '${restrictedSongs.length} restricted; first $decodes mp3 decoded 3 s) ==',
    );
    final kinds = <String, int>{};
    var decoded = 0;
    for (final item in sample) {
      final watch = Stopwatch()..start();
      try {
        final stream = await client.resolveStream(
          keyOf(item),
          item['access_key'] as String?,
        );
        final kind = stream.link == null
            ? (stream.restricted
                  ? 'no link, restricted'
                  : stream.untilRelease
                  ? 'no link, until release'
                  : 'no link')
            : stream.link!.path.toLowerCase().endsWith('.m3u8')
            ? 'playlist link'
            : 'mp3 link';
        kinds[kind] = (kinds[kind] ?? 0) + 1;
        final code = item['content_restricted'];
        var line =
            '  ${code == null ? '' : 'restricted $code: '}'
            '$kind in ${watch.elapsedMilliseconds} ms';
        if (kind == 'mp3 link' && decoded < decodes) {
          decoded++;
          line += ', ${await decode(stream.link!)}';
        }
        print(line);
      } on VkException catch (error) {
        print('  VK error code ${error.code}: ${blank(error.message)}');
      }
    }
    print('stream kinds: $kinds');

    // 7. Summary over every song seen.
    print('\n== summary ==');
    final all = probe.songs.values.toList();
    final paths = <String, int>{};
    for (final item in all) {
      for (final path in fieldPaths(item)) {
        paths[path] = (paths[path] ?? 0) + 1;
      }
    }
    final owned = <String, int>{};
    for (final item in all) {
      final why = probe.owned(item) ?? 'not owned';
      owned[why] = (owned[why] ?? 0) + 1;
    }
    final restricted = <String, int>{};
    for (final item in all) {
      final code = '${item['content_restricted'] ?? '-'}';
      restricted[code] = (restricted[code] ?? 0) + 1;
    }
    final repeated = probe.listsOf.values.where((l) => l.length > 1).length;
    print('songs seen: ${all.length}; in more than one list: $repeated');
    print('owned: $owned');
    print('content_restricted: $restricted');
    print(
      'no link in the reply: '
      '${all.where((i) => (i['url'] as String? ?? '').isEmpty).length}; '
      'question-mark names: ${all.where(isQuestionMarkName).length}',
    );
    print('playlists seen: ${probe.playlists.length}');
    // Names per list, to compare runs (local file, never committed).
    if (saveLists != null && !countsOnly) {
      final lines = <String>[
        for (final MapEntry(:key, :value) in probe.listsOf.entries)
          if (probe.songs[key] case final item?)
            for (final list in value)
              '$list\t${item['artist']} - ${item['title']}',
      ]..sort();
      File(saveLists).writeAsStringSync('${lines.join('\n')}\n');
      print('lists saved: ${lines.length} lines');
    }
    print('song fields (of ${all.length}):');
    for (final path in paths.keys.toList()..sort()) {
      print('  $path ${paths[path]}');
    }
  } on VkException catch (error) {
    print('failed: code ${error.code}: ${blank(error.message)}');
  } finally {
    client.close();
  }
}
