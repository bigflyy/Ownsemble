// Tests for the VK search, add, delete and restore calls (plan 06, C1), on
// the answer shapes VK gave the A1 and A2 probes on 2026-11-08. Ids and keys
// here are made up.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/vk/vk_catalog.dart';
import 'package:ownsemble/vk/vk_client.dart';

/// One call the code under test made.
typedef SentCall = ({String method, Map<String, String> params});

/// A [VkApiCall] that records each call and answers with [answer].
({VkApiCall call, List<SentCall> sent}) fakeVk(
  Object? Function(String method, Map<String, String> params) answer,
) {
  final sent = <SentCall>[];
  Future<Object?> call(String method, Map<String, String> params) async {
    sent.add((method: method, params: params));
    return answer(method, params);
  }

  return (call: call, sent: sent);
}

/// One audio as `audio.search`, `audio.get` and `audio.restore` give it.
Map<String, dynamic> audio(
  int owner,
  int id, {
  String artist = 'Кино',
  String title = 'Группа крови',
  String? accessKey = 'k1',
}) => {
  'id': id,
  'owner_id': owner,
  'artist': artist,
  'title': title,
  'duration': 285,
  'date': 1762600000,
  'access_key': ?accessKey,
  'url': 'https://audio.invalid/a.mp3',
  'track_id': 4242,
  'main_color': '#3a5f8c',
  'album': {
    'id': 77,
    'owner_id': -2000,
    'access_key': 'ak',
    'title': 'Группа крови',
    'thumb': {
      'photo_135': 'https://img.invalid/135.jpg',
      'photo_600': 'https://img.invalid/600.jpg',
    },
  },
};

void main() {
  group('searchVkSongs', () {
    test('sends the query and the page, reads the songs with Cyrillic '
        'names', () async {
      final vk = fakeVk(
        (_, _) => {
          'count': 1234,
          'items': [
            audio(-2000, 1),
            audio(371, 2, artist: 'Сплин', title: 'Выхода нет'),
          ],
        },
      );
      final page = await searchVkSongs(vk.call, '  Кино группа  ', offset: 50);
      expect(vk.sent.single.method, 'audio.search');
      expect(vk.sent.single.params, {
        'q': 'Кино группа',
        'count': '$vkSearchPageSize',
        'offset': '50',
      });
      expect(page.total, 1234);
      expect([for (final s in page.songs) s.sourceKey], ['-2000_1', '371_2']);
      final second = page.songs[1];
      expect((second.artist, second.title), ('Сплин', 'Выхода нет'));
      expect(second.accessKey, 'k1');
      expect(second.album, 'Группа крови');
      expect(second.durationSec, 285);
      expect(second.vkTrackId, 4242);
      expect(second.vkAlbumKey, '-2000_77');
      expect(second.coverUrl, 'https://img.invalid/135.jpg');
    });

    test(
      'the next page starts after the requested count, not after the '
      'songs received (VK leaves blocked songs out but counts them)',
      () async {
        final vk = fakeVk(
          (_, _) => {
            'count': 120,
            'items': [audio(1, 1), audio(1, 2)],
          },
        );
        final first = await searchVkSongs(vk.call, 'x');
        expect(first.nextOffset, 50);
        expect(first.hasMore, isTrue);
        final last = await searchVkSongs(vk.call, 'x', offset: 100);
        expect(last.nextOffset, 150);
        expect(last.hasMore, isFalse);
      },
    );

    test('a song VK lists twice on a page is kept once', () async {
      final vk = fakeVk(
        (_, _) => {
          'count': 3,
          'items': [audio(1, 1), audio(1, 1), audio(1, 2)],
        },
      );
      final page = await searchVkSongs(vk.call, 'x');
      expect([for (final s in page.songs) s.sourceKey], ['1_1', '1_2']);
    });

    test('an empty query asks VK nothing', () async {
      final vk = fakeVk((_, _) => fail('VK was asked'));
      final page = await searchVkSongs(vk.call, '   ');
      expect(page.songs, isEmpty);
      expect(page.hasMore, isFalse);
      expect(vk.sent, isEmpty);
    });

    test('an odd answer is an empty page, not a crash', () async {
      for (final odd in <Object?>[
        null,
        <Object?>[],
        {'count': 5},
        {
          'count': 5,
          'items': ['x', 3],
        },
      ]) {
        final page = await searchVkSongs(fakeVk((_, _) => odd).call, 'x');
        expect(page.songs, isEmpty, reason: '$odd');
      }
    });
  });

  group('addVkSong', () {
    test('sends the found song and reads the new copy from the batch '
        '(A1)', () async {
      final vk = fakeVk(
        (_, _) => {
          'items_count': 1,
          'errors_count': 0,
          'items': [
            {
              'new_audio_id': 456239200,
              'new_owner_id': 900,
              'audio_raw_id': '-2000_1',
            },
          ],
          'errors': <Object?>[],
        },
      );
      final result = await addVkSong(vk.call, '-2000_1', accessKey: 'k1');
      expect(vk.sent.single.method, 'audio.add');
      expect(vk.sent.single.params, {
        'audio_id': '1',
        'owner_id': '-2000',
        'access_key': 'k1',
      });
      expect(result.added, isTrue);
      expect(result.newKey, '900_456239200');
      expect(result.errorCode, isNull);
    });

    test('without an access key none is sent', () async {
      final vk = fakeVk(
        (_, _) => {
          'items': [
            {'new_audio_id': 5, 'new_owner_id': 900},
          ],
        },
      );
      await addVkSong(vk.call, '371_2');
      await addVkSong(vk.call, '371_2', accessKey: '');
      for (final sent in vk.sent) {
        expect(sent.params.containsKey('access_key'), isFalse);
      }
    });

    test('a blocked song comes back as an error in the batch, code 15 as '
        'text (A2, real shape)', () async {
      final vk = fakeVk(
        (_, _) => {
          'items_count': 0,
          'errors_count': 1,
          'items': <Object?>[],
          'errors': [
            {
              'audio_raw_id': '900_17',
              'error_code': '15;Access denied',
              'error_msg': 'no access to audio',
            },
          ],
        },
      );
      final result = await addVkSong(vk.call, '900_17');
      expect(result.added, isFalse);
      expect(result.newKey, isNull);
      expect(result.errorCode, vkNoAccessCode);
      expect(result.noAccess, isTrue);
      expect(result.errorText, 'Access denied: no access to audio');
    });

    test('an error code as a plain number or with no words is read '
        'too', () {
      final plain = readVkAddReply({
        'errors': [
          {'error_code': 15, 'error_msg': 'no access to audio'},
        ],
      });
      expect((plain.errorCode, plain.errorText), (15, 'no access to audio'));
      final bare = readVkAddReply({
        'errors': [
          {'error_code': '15'},
        ],
      });
      expect((bare.errorCode, bare.errorText), (15, null));
      final none = readVkAddReply({
        'errors': [
          {'error_msg': 'Неизвестная ошибка'},
        ],
      });
      expect((none.errorCode, none.errorText), (null, 'Неизвестная ошибка'));
    });

    test('an answer with neither a song nor an error throws', () {
      for (final odd in <Object?>[
        null,
        456239200,
        {'items_count': 0, 'errors_count': 0, 'items': [], 'errors': []},
        {
          'items': [
            {'new_audio_id': '5'},
          ],
        },
      ]) {
        expect(
          () => readVkAddReply(odd),
          throwsA(isA<VkException>()),
          reason: '$odd',
        );
      }
    });

    test('a refusal VK sends as an error passes through', () {
      final vk = fakeVk((_, _) => throw VkException('audio.add error 14'));
      expect(addVkSong(vk.call, '1_2'), throwsA(isA<VkException>()));
    });
  });

  group('deleteVkSong', () {
    test('sends the copy and reads audio_ids, which lists whole keys '
        '(real shape)', () async {
      final vk = fakeVk(
        (_, _) => {
          'audio_ids': ['900_456239200'],
        },
      );
      expect(await deleteVkSong(vk.call, '900_456239200'), isTrue);
      expect(vk.sent.single.method, 'audio.delete');
      expect(vk.sent.single.params, {
        'audio_id': '456239200',
        'owner_id': '900',
      });
    });

    test('an answer that does not name the song is a no', () {
      for (final reply in <Object?>[
        {'audio_ids': <Object?>[]},
        {
          'audio_ids': ['900_6'],
        },
        // Same audio id, another owner.
        {
          'audio_ids': ['901_5'],
        },
        null,
        0,
      ]) {
        expect(readVkDeleteReply(reply, '900_5'), isFalse, reason: '$reply');
      }
    });

    test('a bare audio id and the old bare 1 are a yes', () {
      expect(
        readVkDeleteReply({
          'audio_ids': [5],
        }, '900_5'),
        isTrue,
      );
      expect(readVkDeleteReply(1, '900_5'), isTrue);
    });
  });

  group('restoreVkSong', () {
    test('sends the removed copy and reads the song VK gives back '
        '(A2)', () async {
      final vk = fakeVk(
        (_, _) =>
            audio(900, 456239200, artist: 'Ария', title: 'Беспечный ангел'),
      );
      final song = await restoreVkSong(vk.call, '900_456239200');
      expect(vk.sent.single.method, 'audio.restore');
      expect(vk.sent.single.params, {
        'audio_id': '456239200',
        'owner_id': '900',
      });
      expect(song.sourceKey, '900_456239200');
      expect((song.artist, song.title), ('Ария', 'Беспечный ангел'));
    });

    test('an answer without the song throws', () {
      for (final odd in <Object?>[
        null,
        1,
        {'id': 5},
      ]) {
        expect(
          restoreVkSong(fakeVk((_, _) => odd).call, '900_5'),
          throwsA(isA<VkException>()),
          reason: '$odd',
        );
      }
    });
  });

  group('splitVkKey', () {
    test('reads user and group owners', () {
      expect(splitVkKey('900_5'), (900, 5));
      expect(splitVkKey('-2000_77'), (-2000, 77));
    });

    test('anything else is refused before VK is asked', () async {
      for (final bad in ['', '900', '900_', '_5', '900_5_k', 'a_b', '9 _5']) {
        expect(() => splitVkKey(bad), throwsFormatException, reason: bad);
      }
      final vk = fakeVk((_, _) => fail('VK was asked'));
      expect(addVkSong(vk.call, 'oops'), throwsFormatException);
      expect(vk.sent, isEmpty);
    });
  });
}
