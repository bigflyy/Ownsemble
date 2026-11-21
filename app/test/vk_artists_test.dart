// Tests for plan 09 C3: reading VK's artist page (scrubbed reply of the
// test account, plus made-up cases the fixture lacks, R11), paging Popular
// (R7) and the artist photo batch (R2).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_artists.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_recommendations.dart';

Map<String, dynamic> _fixture() => jsonDecode(
  File('test/fixtures/vk_artists/catalog_get_audio_artist.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

/// A made-up song item of VK.
Map<String, Object> _song(int id, {String title = 'Песня'}) => {
  'owner_id': -5,
  'id': id,
  'artist': 'Дайте танк (!)',
  'title': title,
  'duration': 180,
  'url': 'https://audio.invalid/$id.mp3',
  'main_artists': [
    {'id': '10000', 'name': 'Дайте танк (!)'},
  ],
};

/// A made-up album of [artistId].
Map<String, Object> _album(int id, String artistId, {String type = 'album'}) =>
    {
      'owner_id': -7,
      'id': id,
      'type': type,
      'title': 'Альбом $id',
      'count': id,
      'year': 2020,
      'access_key': 'k$id',
      'main_artists': [
        {'id': artistId, 'name': 'Кто-то'},
      ],
    };

void main() {
  group('the artist page', () {
    test('the scrubbed page of the test account: artist, Popular, '
        'Releases', () {
      final page = vkArtistPageOf(_fixture())!;
      expect(page.id, '10000');
      expect(page.name, 'Дайте танк (!)');
      expect(page.domain, 'daitetank');
      // The banner, about 800 px wide, not the 1510 one.
      expect(page.bannerUrl, 'https://example.invalid/1747.jpg');

      expect(page.popular.songs, hasLength(30));
      expect(page.popular.songs.first.key, '-10001_10002');
      expect(page.popular.blockId, 'opaque-9');
      expect(page.popular.nextFrom, 'opaque-10');
      expect(page.popular.hasMore, isTrue);
      expect(page.popularTotal, 132);

      // The Releases block's ten albums, in its order; not Appears on
      // (another artist's tribute) nor the users' lists (R11).
      expect(page.releases, hasLength(10));
      expect(page.releases.first.key, '-10061_10062');
      expect(page.releases.first.title, 'Радио Пепел');
      expect(page.releases.first.year, 2026);
      expect(page.releases.first.single, isFalse);
      expect(page.releases[1].single, isTrue);
      expect(page.releases.map((r) => r.key), isNot(contains('-10081_10082')));
      expect(page.releases.first.artists.single.vkId, '10000');

      // You may like: the four artist links, not the official group page.
      expect(page.similar.map((a) => a.name), [
        'Серебряная Свадьба',
        'Сова',
        'ТВОИ КОШМАРЫ',
        'Дела Поважнее',
      ]);
      // The fixture's links are scrubbed, so no address name.
      expect(page.similar.first.domain, isNull);
      expect(page.similar.first.photoUrl, isNotNull);
    });

    test('Releases are only this artist\'s albums: a page with Appears on '
        'and no releases of its own has none', () {
      final page = vkArtistPageOf({
        'artists': [
          {'id': '1', 'name': 'Новичок'},
        ],
        'audios': [_song(1)],
        'playlists': [_album(3, '99'), _album(4, '1', type: 'ugc')],
        'catalog': {
          'sections': [
            {
              'blocks': [
                {
                  'data_type': 'music_audios',
                  'id': 'b1',
                  'audios_ids': ['-5_1', '-5_404'],
                },
                {
                  'data_type': 'music_playlists',
                  'playlists_ids': ['-7_3'],
                },
                {
                  'data_type': 'music_playlists',
                  'playlists_ids': ['-7_4'],
                },
              ],
            },
          ],
        },
      })!;
      expect(page.releases, isEmpty);
      // A song id the reply has no song for is left out; no next page.
      expect(page.popular.songs.map((s) => s.key), ['-5_1']);
      expect(page.popular.hasMore, isFalse);
      expect(page.popularTotal, isNull);
      expect(page.similar, isEmpty);
      expect(page.bannerUrl, isNull);
    });

    test('similar artists open by the address name in their link', () {
      final page = vkArtistPageOf({
        'artists': [
          {'id': '1', 'name': 'Новичок'},
        ],
        'links': [
          {
            'id': 'l1',
            'title': 'Сова',
            'url': 'https://vk.com/artist/sova_band',
            'meta': {'content_type': 'artist'},
            'image': [
              {'url': 'https://img.invalid/72.jpg', 'width': 72, 'height': 72},
              {
                'url': 'https://img.invalid/270.jpg',
                'width': 270,
                'height': 270,
              },
            ],
          },
          {
            'id': 'l2',
            'title': 'Группа ВК',
            'url': 'https://vk.com/club1',
            'meta': {'content_type': 'group'},
          },
        ],
        'catalog': {
          'sections': [
            {
              'blocks': [
                {
                  'data_type': 'links',
                  'links_ids': ['l2'],
                },
                {
                  'data_type': 'links',
                  'links_ids': ['l1'],
                },
              ],
            },
          ],
        },
      })!;
      expect(page.similar.single.name, 'Сова');
      expect(page.similar.single.domain, 'sova_band');
      expect(page.similar.single.photoUrl, 'https://img.invalid/270.jpg');
    });

    test('a reply with no artist is no page', () {
      expect(vkArtistPageOf(null), isNull);
      expect(vkArtistPageOf({'artists': <Object>[]}), isNull);
      expect(
        vkArtistPageOf({
          'artists': [
            {'id': '', 'name': 'X'},
          ],
        }),
        isNull,
      );
    });

    test('address names in links', () {
      expect(
        artistDomainOfLink('https://vk.com/artist/daitetank'),
        'daitetank',
      );
      expect(artistDomainOfLink('https://vk.ru/artist/sova?from=page'), 'sova');
      expect(artistDomainOfLink('/artist/x_y'), 'x_y');
      expect(artistDomainOfLink('https://vk.com/artist/'), isNull);
      expect(artistDomainOfLink('https://vk.com/club1'), isNull);
      expect(artistDomainOfLink(null), isNull);
    });

    test('VK error 10 is asked once more; others fail', () async {
      var asked = 0;
      Future<Object?> flaky(String method, Map<String, String> params) async {
        asked++;
        expect(method, 'catalog.getAudioArtist');
        expect(params, {'artist_id': 'daitetank', 'need_blocks': '1'});
        if (asked == 1) throw VkException('no token check', code: 10);
        return _fixture();
      }

      final page = await fetchVkArtistPage(flaky, 'daitetank');
      expect(page!.id, '10000');
      expect(asked, 2);

      Future<Object?> refusing(String method, Map<String, String> params) =>
          throw VkException('denied', code: 15);
      expect(
        fetchVkArtistPage(refusing, '1'),
        throwsA(isA<VkException>().having((e) => e.code, 'code', 15)),
      );
    });
  });

  group('paging Popular', () {
    const first = VkSongBlock(songs: [], blockId: 'b1', nextFrom: 'n1');

    test(
      'adds the next songs in the block\'s order and its next mark',
      () async {
        Future<Object?> call(String method, Map<String, String> params) async {
          expect(method, 'catalog.getBlockItems');
          expect(params, {'block_id': 'b1', 'start_from': 'n1'});
          return {
            'audios': [_song(2), _song(1)],
            'block': {
              'audios_ids': ['-5_1', '-5_2'],
              'next_from': 'n2',
            },
          };
        }

        final next = await fetchVkBlockMore(call, first);
        expect(next.songs.map((s) => s.key), ['-5_1', '-5_2']);
        expect(next.nextFrom, 'n2');
        expect(next.blockId, 'b1');
      },
    );

    test('a page with nothing new, or the same mark again, ends paging '
        '(R7)', () async {
      final had = VkSongBlock(
        songs: [vkRecSongOf(_song(1))!],
        blockId: 'b1',
        nextFrom: 'n1',
      );
      Future<Object?> repeat(String method, Map<String, String> params) async =>
          {
            'audios': [_song(1)],
            'block': {
              'audios_ids': ['-5_1'],
              'next_from': 'n2',
            },
          };
      final again = await fetchVkBlockMore(repeat, had);
      expect(again.songs, hasLength(1));
      expect(again.hasMore, isFalse);

      Future<Object?> sameMark(
        String method,
        Map<String, String> params,
      ) async => {
        'audios': [_song(3)],
        'block': {
          'audios_ids': ['-5_3'],
          'next_from': 'n1',
        },
      };
      final stuck = await fetchVkBlockMore(sameMark, had);
      expect(stuck.songs, hasLength(2));
      expect(stuck.hasMore, isFalse);
    });

    test('a block with no next page asks nothing', () async {
      const done = VkSongBlock(songs: []);
      Future<Object?> call(String method, Map<String, String> params) =>
          throw StateError('asked');
      expect(await fetchVkBlockMore(call, done), same(done));
    });

    test("Releases page on past the first ten: this artist's albums, each "
        'once, until VK gives no next mark (user 2026-11-21: "not all the '
        'albums")', () async {
      final page = vkArtistPageOf(_fixture())!;
      // The fixture's Releases block says there is more.
      expect(page.hasMoreReleases, isTrue);
      final asked = <Map<String, String>>[];
      Future<Object?> call(String method, Map<String, String> params) async {
        expect(method, 'catalog.getBlockItems');
        asked.add(params);
        final first = asked.length == 1;
        return {
          // The live reply's shape (check_artist_readers, 2026-11-21):
          // block {id, data_type, layout, meta, playlists_ids, title} and
          // the playlists; a page without next_from is the last.
          'block': {
            'id': page.releasesBlockId,
            'playlists_ids': first
                ? ['-7_21', '-7_22', '-7_23', page.releases.first.key]
                : ['-7_24'],
            if (first) 'next_from': 'opaque-more',
          },
          'playlists': [
            _album(21, page.id),
            _album(22, '99'), // Another artist's: left out.
            _album(23, page.id, type: 'ugc'), // A user's list: left out.
            _album(24, page.id),
          ],
        };
      }

      final all = await fetchVkReleasesMore(call, page);
      expect(asked.map((p) => p['start_from']), [
        page.releasesNextFrom,
        'opaque-more',
      ]);
      expect(asked.first['block_id'], page.releasesBlockId);
      expect(all.releases.map((r) => r.key), [
        ...page.releases.map((r) => r.key),
        '-7_21',
        '-7_24',
      ]);
      expect(all.hasMoreReleases, isFalse);
      // The rest of the page stays.
      expect(all.popular, same(page.popular));
      expect(all.similar, same(page.similar));
      expect(all.popularTotal, page.popularTotal);
    });

    test('Releases paging stops on a page with nothing new', () async {
      final page = vkArtistPageOf(_fixture())!;
      var calls = 0;
      Future<Object?> call(String method, Map<String, String> params) async {
        calls++;
        return {
          'block': {
            'playlists_ids': [page.releases.first.key],
            'next_from': 'again-$calls',
          },
          'playlists': const [],
        };
      }

      final all = await fetchVkReleasesMore(call, page);
      expect(calls, 1);
      expect(all.releases, hasLength(page.releases.length));
    });

    test(
      "a page of only other artists' releases goes on; a failing "
      'request keeps the pages that came (Codex review 2026-11-21)',
      () async {
        final page = vkArtistPageOf(_fixture())!;
        var calls = 0;
        Future<Object?> call(String method, Map<String, String> params) async {
          calls++;
          return switch (calls) {
            1 => {
              'block': {
                'playlists_ids': ['-7_31'],
                'next_from': 'b',
              },
              'playlists': [_album(31, '99')],
            },
            2 => {
              'block': {
                'playlists_ids': ['-7_32'],
                'next_from': 'c',
              },
              'playlists': [_album(32, page.id)],
            },
            _ => throw VkException('busy', code: 6),
          };
        }

        final all = await fetchVkReleasesMore(call, page);
        expect(calls, 3);
        expect(all.releases.last.key, '-7_32');
        expect(all.releases, hasLength(page.releases.length + 1));

        // The first request failing: the error goes up.
        Future<Object?> failing(String method, Map<String, String> params) =>
            throw VkException('busy', code: 6);
        await expectLater(
          fetchVkReleasesMore(failing, page),
          throwsA(isA<VkException>()),
        );
      },
    );
  });

  group('artist photos', () {
    List<Map<String, Object>> photo(String base) => [
      {'url': '$base-200.jpg', 'width': 270, 'height': 200},
      {'url': '$base-270.jpg', 'width': 270, 'height': 270},
      {'url': '$base-135.jpg', 'width': 135, 'height': 135},
    ];

    test('one execute of searches by name; the answer with the same id, a '
        'failed search left out, none found is missing (R2)', () async {
      final artists = [
        (id: '1', name: 'Дайте танк (!)'),
        (id: '2', name: 'Группа "Кавычки"'),
        (id: '3', name: 'Сова'),
        (id: '4', name: 'Нет фото'),
      ];
      late String code;
      Future<Object?> call(String method, Map<String, String> params) async {
        expect(method, 'execute');
        code = params['code']!;
        return [
          [
            {'id': '9', 'name': 'Дайте танк', 'photo': photo('other')},
            {'id': '1', 'name': 'Дайте танк (!)', 'photo': photo('tank')},
          ],
          false,
          [
            {'id': '33', 'name': 'Сова', 'photo': photo('owl')},
          ],
          [
            {'id': '4', 'name': 'Нет фото'},
          ],
        ];
      }

      final photos = await fetchVkArtistPhotos(call, artists);
      expect(code, contains(r'"q": "Группа \"Кавычки\""'));
      expect('r.push('.allMatches(code), hasLength(4));
      final tank = photos['1']! as VkArtistPhotoFound;
      expect(tank.large, 'tank-270.jpg');
      expect(tank.small, 'tank-135.jpg');
      expect(photos.containsKey('2'), isFalse);
      expect(photos['3'], isA<VkArtistPhotoMissing>());
      expect(photos['4'], isA<VkArtistPhotoMissing>());
    });

    test('nothing to ask asks nothing; more than 25 is refused', () async {
      Future<Object?> call(String method, Map<String, String> params) =>
          throw StateError('asked');
      expect(await fetchVkArtistPhotos(call, const []), isEmpty);
      expect(
        () => fetchVkArtistPhotos(call, [
          for (var i = 0; i < 26; i++) (id: '$i', name: 'A$i'),
        ]),
        throwsArgumentError,
      );
    });
  });
}
