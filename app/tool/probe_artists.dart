// What VK gives for artists (plan 09, Stage A):
// 1. the library's songs: which carry main_artists / featured_artists, the
//    fields of an artist there, how many distinct artist ids, names shared by
//    several ids and ids under several names, songs with no artist id, and
//    how the artist text joins several artists;
// 2. an artist's page for the artists with the most library songs: what
//    catalog.getAudioArtist and the older audio.* artist methods give, paging
//    and time.
//
// READ ONLY: nothing is followed, added, edited or removed on VK.
//
// Prints an ALLOWLIST of named fields only: counts, field names, block kinds,
// yes/no flags, times and error codes; artist, song, album and section names
// only without --counts-only. Never a link, key, token, id or whole reply
// (artists are named "artist #N" by their place in this run).
//
// Run from app/:
//   dart run tool/probe_artists.dart --vk-session FILE [--counts-only]
//     [--artists N] [--fixtures DIR]
//
// --fixtures writes scrubbed copies (probe_recommendations.dart's Scrubber)
// of one artist page and its song list, for the unit tests' fakes; never
// with the second account.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';

import 'probe_recommendations.dart' show Scrubber;

/// Long numbers blanked, so an id inside an error text never shows.
String blank(Object? text) => '$text'.replaceAll(RegExp(r'\d{4,}'), 'N');

String keyOf(Map<String, dynamic> item) => '${item['owner_id']}_${item['id']}';

/// Field names of a map, one level into maps and lists of maps. No values.
Set<String> fieldPaths(Map<String, dynamic> map, [String prefix = '']) {
  final seen = <String>{};
  for (final MapEntry(:key, :value) in map.entries) {
    final path = '$prefix$key';
    seen.add(path);
    if (prefix.isNotEmpty) continue;
    if (value is Map<String, dynamic>) {
      seen.addAll(fieldPaths(value, '$path.'));
    } else if (value is List &&
        value.isNotEmpty &&
        value.first is Map<String, dynamic>) {
      seen.addAll(fieldPaths(value.first as Map<String, dynamic>, '$path[].'));
    }
  }
  return seen;
}

List<Map<String, dynamic>> artistsOf(Map<String, dynamic> song, String field) =>
    (song[field] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

/// How an artist text joins several artists, as a kind only.
String joinKind(String artist) {
  final lower = artist.toLowerCase();
  if (RegExp(r'\b(feat\.?|ft\.?|featuring)\s').hasMatch(lower)) return 'feat';
  if (lower.contains(' & ')) return '&';
  if (RegExp(r'\s[xх]\s').hasMatch(lower)) return 'x';
  if (lower.contains(',')) return 'comma';
  if (lower.contains(' и ') || lower.contains(' and ')) return 'and';
  return 'one';
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final countsOnly = args.contains('--counts-only');
  final maxArtists = int.parse(valueOf('--artists') ?? '3');
  final fixtureDir = countsOnly ? null : valueOf('--fixtures');
  final scrubber = Scrubber();
  void saveFixture(String name, Object? reply) {
    if (fixtureDir == null || reply == null) return;
    Directory(fixtureDir).createSync(recursive: true);
    File('$fixtureDir/$name.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(scrubber.scrub(reply)),
    );
    print('fixture $name written');
  }

  final client = VkClient(
    SessionCookie.loadAll(File(valueOf('--vk-session')!)),
    requestTimeout: const Duration(seconds: 90),
    silenceTimeout: const Duration(seconds: 45),
  );
  String name(Object? text) => countsOnly ? '(name)' : '"$text"';

  Future<(Object?, int)> ask(String method, Map<String, String> params) async {
    final clock = Stopwatch()..start();
    try {
      final reply = await client.call(method, params);
      return (reply, clock.elapsedMilliseconds);
    } on VkException catch (error) {
      print(
        '  $method: VK error ${error.code ?? 'other'} '
        '(${clock.elapsedMilliseconds} ms)',
      );
      return (null, clock.elapsedMilliseconds);
    }
  }

  try {
    await client.ensureToken();
    print('probe_artists ${DateTime.now().toIso8601String()}');

    // 1. The library's songs and their artists.
    final songs = <Map<String, dynamic>>[];
    var total = 0;
    for (var offset = 0; offset == 0 || offset < total; offset += 500) {
      final page = await client.call('audio.get', {
        'count': '500',
        'offset': '$offset',
      }) as Map<String, dynamic>;
      total = page['count'] as int;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      songs.addAll(items);
      if (items.isEmpty) break;
    }
    final libraryKeys = {for (final song in songs) keyOf(song)};
    // As the app's FoundMatcher: same VK track_id and a length within 3 s,
    // or the same artist and title (lower case, trimmed) and length.
    final byTrack = <String, List<int>>{};
    final byText = <String, List<int>>{};
    String textOf(Map<String, dynamic> s) =>
        '${'${s['artist']}'.trim().toLowerCase()} - '
        '${'${s['title']}'.trim().toLowerCase()}';
    for (final song in songs) {
      final length = song['duration'] as int? ?? 0;
      if (song['track_id'] != null) {
        byTrack.putIfAbsent('${song['track_id']}', () => []).add(length);
      }
      byText.putIfAbsent(textOf(song), () => []).add(length);
    }
    bool near(List<int>? lengths, Object? length) =>
        lengths != null &&
        lengths.any((l) => (l - (length as int? ?? 0)).abs() <= 3);
    bool inLibrary(Map<String, dynamic> s) =>
        libraryKeys.contains(keyOf(s)) ||
        near(byTrack['${s['track_id']}'], s['duration']) ||
        near(byText[textOf(s)], s['duration']);
    print('library: VK count $total, got ${songs.length} songs');

    final artistFields = <String>{};
    var withMain = 0, withFeatured = 0, withNeither = 0, mainMany = 0;
    final namesById = <String, Set<String>>{};
    final idsByName = <String, Set<String>>{};
    final songsById = <String, int>{};
    final textMatch = <String, int>{};
    final joins = <String, int>{};
    final joinsNoId = <String, int>{};
    final examples = <String, List<String>>{};
    void example(String kind, String text) {
      final list = examples.putIfAbsent(kind, () => []);
      if (list.length < 4) list.add(text);
    }

    for (final song in songs) {
      final main = artistsOf(song, 'main_artists');
      final featured = artistsOf(song, 'featured_artists');
      final text = '${song['artist'] ?? ''}'.trim();
      if (main.isNotEmpty) withMain++;
      if (main.length > 1) mainMany++;
      if (featured.isNotEmpty) withFeatured++;
      if (main.isEmpty && featured.isEmpty) {
        withNeither++;
        joinsNoId[joinKind(text)] = (joinsNoId[joinKind(text)] ?? 0) + 1;
      }
      joins[joinKind(text)] = (joins[joinKind(text)] ?? 0) + 1;
      for (final artist in [...main, ...featured]) {
        artistFields.addAll(fieldPaths(artist));
        final id = '${artist['id']}';
        final artistName = '${artist['name'] ?? ''}';
        namesById.putIfAbsent(id, () => {}).add(artistName);
        idsByName.putIfAbsent(artistName.toLowerCase(), () => {}).add(id);
      }
      for (final artist in main) {
        final id = '${artist['id']}';
        songsById[id] = (songsById[id] ?? 0) + 1;
      }
      if (main.isNotEmpty) {
        final joined = main.map((a) => '${a['name']}').join(', ');
        final kind = joined == text
            ? 'same'
            : joined.toLowerCase() == text.toLowerCase()
            ? 'same but case'
            : main.every(
                (a) =>
                    text.toLowerCase().contains('${a['name']}'.toLowerCase()),
              )
            ? 'text has every main name'
            : 'differs';
        textMatch[kind] = (textMatch[kind] ?? 0) + 1;
        if (kind == 'differs' || kind == 'text has every main name') {
          example(
            kind,
            '${name(text)} vs main ${name(joined)}'
            '${featured.isEmpty ? '' : ' feat ${name(featured.map((a) => a['name']).join(', '))}'}',
          );
        }
      }
    }
    print(
      'songs with main_artists $withMain, with more than one main $mainMany, '
      'with featured_artists $withFeatured, with neither $withNeither',
    );
    print('artist fields: ${(artistFields.toList()..sort()).join(' ')}');
    print(
      'distinct artist ids ${namesById.length}, '
      'distinct artist texts ${songs.map((s) => '${s['artist']}'.trim().toLowerCase()).toSet().length}',
    );
    final manyNames = namesById.entries.where((e) => e.value.length > 1);
    final manyIds = idsByName.entries.where((e) => e.value.length > 1);
    print(
      'ids under more than one name: ${manyNames.length}; '
      'names under more than one id: ${manyIds.length}',
    );
    for (final entry in manyNames.take(4)) {
      print('  one id, names ${entry.value.map(name).join(' / ')}');
    }
    for (final entry in manyIds.take(4)) {
      print('  name ${name(entry.key)}: ${entry.value.length} ids');
    }
    print('artist text vs joined main names: $textMatch');
    for (final MapEntry(:key, :value) in examples.entries) {
      for (final line in value) {
        print('  $key: $line');
      }
    }
    print('artist text joins (all songs): $joins');
    print('artist text joins (songs with no artist id): $joinsNoId');
    final songCounts = songsById.values.toList()..sort((a, b) => b - a);
    final once = songCounts.where((c) => c == 1).length;
    print(
      'songs per artist id (main): top ${songCounts.take(10).join(', ')}; '
      'artists with 1 song $once of ${songCounts.length}',
    );
    // Songs with no artist id: does their text name an artist the library
    // knows by id (exactly one id, several ids, or none)? And their text cut
    // at " feat. " / " ft. ".
    final noId = songs.where(
      (s) =>
          artistsOf(s, 'main_artists').isEmpty &&
          artistsOf(s, 'featured_artists').isEmpty,
    );
    final fit = <String, int>{};
    for (final song in noId) {
      final text = '${song['artist'] ?? ''}'.trim().toLowerCase();
      final cut = text.split(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+')).first;
      final ids = idsByName[text] ?? idsByName[cut];
      final kind = ids == null
          ? 'no known artist'
          : ids.length == 1
          ? (idsByName[text] != null
                ? 'one known artist'
                : 'one after cutting feat')
          : 'several ids';
      fit[kind] = (fit[kind] ?? 0) + 1;
    }
    print('songs with no artist id, their text vs artists known by id: $fit');
    final uploads = songs.where((s) => s['track_code'] == null).length;
    print('songs without track_code (uploads?) $uploads');

    // 2. Pages of the artists with the most library songs.
    final top = songsById.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var number = 0;
    for (final MapEntry(key: artistId, value: librarySongs) in top.take(
      maxArtists,
    )) {
      number++;
      print(
        '\nartist #$number ${name(namesById[artistId]!.first)}: '
        '$librarySongs library songs',
      );

      // 2a. VK's web client artist page.
      final (page, pageMs) = await ask('catalog.getAudioArtist', {
        'artist_id': artistId,
        'need_blocks': '1',
      });
      if (page is Map<String, dynamic>) {
        if (number == 1) saveFixture('catalog_get_audio_artist', page);
        final lists = [
          for (final MapEntry(:key, :value) in page.entries)
            if (value is List) '$key ${value.length}',
        ];
        print('  catalog.getAudioArtist $pageMs ms: lists ${lists.join(', ')}');
        final artists = (page['artists'] as List? ?? const [])
            .whereType<Map<String, dynamic>>();
        if (artists.isNotEmpty) {
          print(
            '  artists[] fields: '
            '${(fieldPaths(artists.first).toList()..sort()).join(' ')}',
          );
        }
        final pageSongs = (page['audios'] as List? ?? const [])
            .whereType<Map<String, dynamic>>();
        final pageInLibrary = pageSongs.where(inLibrary);
        final byThem = pageSongs.where(
          (s) => [
            ...artistsOf(s, 'main_artists'),
            ...artistsOf(s, 'featured_artists'),
          ].any((a) => '${a['id']}' == artistId),
        );
        print(
          '  page songs ${pageSongs.length}: in library ${pageInLibrary.length}, '
          'carry this artist id ${byThem.length}, '
          'no link ${pageSongs.where((s) => '${s['url'] ?? ''}'.isEmpty).length}',
        );
        final pagePlaylists = (page['playlists'] as List? ?? const [])
            .whereType<Map<String, dynamic>>();
        final kinds = <String, int>{};
        for (final list in pagePlaylists) {
          final kind = '${list['type']}/${list['album_type'] ?? '-'}';
          kinds[kind] = (kinds[kind] ?? 0) + 1;
        }
        print('  page playlists by type/album_type: $kinds');
        if (!countsOnly) {
          for (final list in pagePlaylists.take(6)) {
            print(
              '    ${name(list['title'])} ${list['year'] ?? ''} '
              '(${list['count']} songs, ${list['album_type'] ?? list['type']})',
            );
          }
        }
        final links = (page['links'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (links.isNotEmpty) {
          print(
            '  links[] fields: '
            '${(fieldPaths(links.first).toList()..sort()).join(' ')}',
          );
          if (!countsOnly) {
            for (final link in links) {
              final url = '${link['url'] ?? ''}';
              print(
                '    link ${name(link['title'])} '
                '${name(link['subtitle'])} kind '
                '${url.contains('artist')
                    ? 'artist'
                    : url.startsWith('http')
                    ? 'outside'
                    : 'other'}',
              );
            }
          }
        }
        // Similar-artist links: the shape of their address (no address is
        // printed) and whether the artist page opens by the domain in it.
        for (final link in links) {
          final url = Uri.tryParse('${link['url'] ?? ''}');
          final segments = url?.pathSegments ?? const <String>[];
          if (segments.length != 2 || segments.first != 'artist') continue;
          final shape = RegExp(r'^\d+$').hasMatch(segments[1])
              ? 'digits'
              : 'letters';
          final (byDomain, byDomainMs) = await ask('catalog.getAudioArtist', {
            'artist_id': segments[1],
            'need_blocks': '1',
          });
          final opened = byDomain is Map<String, dynamic>
              ? (byDomain['artists'] as List? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .firstOrNull
              : null;
          print(
            '  similar link /artist/<$shape>: page by it $byDomainMs ms, '
            'opens ${opened == null ? 'no' : name(opened['name'])}, '
            'its id is a number ${RegExp(r'^\d+$').hasMatch('${opened?['id']}')}, '
            'domain equals the link ${opened?['domain'] == segments[1]}',
          );
          break;
        }
        // Our own artist by its domain, as a song's main_artists gives it.
        final domain = artists.firstOrNull?['domain'];
        if (domain != null) {
          final (own, ownMs) = await ask('catalog.getAudioArtist', {
            'artist_id': '$domain',
            'need_blocks': '1',
          });
          final opened = own is Map<String, dynamic>
              ? (own['artists'] as List? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .firstOrNull
              : null;
          print(
            '  this artist by its domain: $ownMs ms, same artist '
            '${'${opened?['id']}' == artistId}',
          );
        }
        final catalog = page['catalog'] as Map<String, dynamic>?;
        final sections = (catalog?['sections'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        print(
          '  sections ${sections.length}, default is the first: '
          '${sections.isNotEmpty && catalog?['default_section'] == sections.first['id']}',
        );
        for (final section in sections) {
          final blocks = (section['blocks'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          print(
            '  section ${name(section['title'])}: ${blocks.length} blocks, '
            'next_from ${section['next_from'] != null}',
          );
          for (final block in blocks) {
            final layout = block['layout'] as Map<String, dynamic>?;
            final ids = [
              for (final MapEntry(:key, :value) in block.entries)
                if (key.endsWith('_ids') && value is List)
                  '$key ${value.length}',
            ];
            final buttons = (block['buttons'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map((b) => '${b['action']?['type'] ?? b['title']}');
            print(
              '    block ${block['data_type']} layout ${layout?['name']}'
              '${layout?['title'] == null ? '' : ' ${name(layout!['title'])}'}'
              '${ids.isEmpty ? '' : ' ${ids.join(', ')}'}'
              '${block['next_from'] == null ? '' : ' next_from'}'
              '${buttons.isEmpty ? '' : ' buttons ${buttons.join('/')}'}',
            );
          }
        }

        // 2b. Past the page: every song or release block with a next_from, paged;
        // and each section other than the first, opened.
        for (final section in sections) {
          for (final block
              in (section['blocks'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>()) {
            if (block['data_type'] == 'music_playlists' &&
                block['next_from'] != null) {
              var from = '${block['next_from']}';
              var pages = 0, got = 0;
              final kinds = <String, int>{};
              final clock = Stopwatch()..start();
              while (pages < 10) {
                final (more, _) = await ask('catalog.getBlockItems', {
                  'block_id': '${block['id']}',
                  'start_from': from,
                });
                if (more is! Map<String, dynamic>) break;
                pages++;
                for (final list
                    in (more['playlists'] as List? ?? const [])
                        .whereType<Map<String, dynamic>>()) {
                  got++;
                  final kind = list['count'] == 1
                      ? 'one song'
                      : (list['count'] as int? ?? 0) <= 6
                      ? '2-6 songs'
                      : '7+ songs';
                  kinds[kind] = (kinds[kind] ?? 0) + 1;
                }
                final next = (more['block'] as Map?)?['next_from'];
                if (next == null || '$next'.isEmpty) break;
                from = '$next';
              }
              print(
                '  releases block paged: $pages pages, $got more '
                'playlists in ${clock.elapsedMilliseconds} ms, by size $kinds',
              );
              continue;
            }
            if (block['data_type'] != 'music_audios' ||
                block['next_from'] == null) {
              continue;
            }
            var from = '${block['next_from']}';
            var pages = 0;
            final keys = <String>{};
            var have = 0;
            final clock = Stopwatch()..start();
            while (pages < 10) {
              final (more, _) = await ask('catalog.getBlockItems', {
                'block_id': '${block['id']}',
                'start_from': from,
              });
              if (more is! Map<String, dynamic>) break;
              pages++;
              for (final song
                  in (more['audios'] as List? ?? const [])
                      .whereType<Map<String, dynamic>>()) {
                if (keys.add(keyOf(song)) && inLibrary(song)) have++;
              }
              final next = (more['block'] as Map?)?['next_from'];
              if (next == null || '$next'.isEmpty) break;
              from = '$next';
            }
            print(
              '  popular songs paged: $pages pages, ${keys.length} more '
              'songs in ${clock.elapsedMilliseconds} ms, in library $have',
            );
          }
        }
        for (final section in sections.skip(1).take(3)) {
          final (other, otherMs) = await ask('catalog.getSection', {
            'section_id': '${section['id']}',
          });
          if (other is Map<String, dynamic>) {
            final body = other['section'] as Map<String, dynamic>?;
            final blocks = (body?['blocks'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map((b) => '${b['data_type']}')
                .toList();
            print(
              '  getSection ${name(section['title'])} $otherMs ms: '
              'audios ${(other['audios'] as List?)?.length}, '
              'playlists ${(other['playlists'] as List?)?.length}, '
              'blocks $blocks, next_from ${body?['next_from'] != null}',
            );
          }
        }
      }

      // 2c. The older audio.* artist methods.
      final (byId, byIdMs) = await ask('audio.getArtistById', {
        'artist_id': artistId,
      });
      if (byId is Map<String, dynamic>) {
        print(
          '  audio.getArtistById $byIdMs ms: fields '
          '${(fieldPaths(byId).toList()..sort()).join(' ')}',
        );
      }
      final (bySongs, bySongsMs) = await ask('audio.getAudiosByArtist', {
        'artist_id': artistId,
        'count': '100',
      });
      if (bySongs is Map<String, dynamic>) {
        if (number == 1) saveFixture('audio_get_audios_by_artist', bySongs);
        final items = (bySongs['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        print(
          '  audio.getAudiosByArtist $bySongsMs ms: count '
          '${bySongs['count']}, items ${items.length}, in library '
          '${items.where(inLibrary).length}, '
          'repeats ${items.length - items.map(keyOf).toSet().length}',
        );
        if (!countsOnly) {
          for (final song in items.take(3)) {
            print('    ${song['artist']} - ${song['title']}');
          }
        }
        // A second page, to see whether offset pages.
        final (second, secondMs) = await ask('audio.getAudiosByArtist', {
          'artist_id': artistId,
          'count': '100',
          'offset': '100',
        });
        if (second is Map<String, dynamic>) {
          final more = (second['items'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(keyOf)
              .toSet();
          print(
            '  offset 100 $secondMs ms: items ${more.length}, '
            'overlap with the first page '
            '${more.intersection(items.map(keyOf).toSet()).length}',
          );
        }
      }
      final (albums, albumsMs) = await ask('audio.getAlbumsByArtist', {
        'artist_id': artistId,
        'count': '100',
      });
      if (albums is Map<String, dynamic>) {
        final items = (albums['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        final kinds = <String, int>{};
        for (final list in items) {
          final kind = '${list['type']}/${list['album_type'] ?? '-'}';
          kinds[kind] = (kinds[kind] ?? 0) + 1;
        }
        print(
          '  audio.getAlbumsByArtist $albumsMs ms: count '
          '${albums['count']}, items ${items.length}, kinds $kinds',
        );
        if (items.isNotEmpty) {
          print(
            '  album fields: '
            '${(fieldPaths(items.first).toList()..sort()).join(' ')}',
          );
        }
      }
    }
  } finally {
    client.close();
  }
}
