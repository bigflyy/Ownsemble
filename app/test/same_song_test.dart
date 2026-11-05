import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/merge_plan.dart';
import 'package:ownsemble/library/same_song.dart';

/// Which rows are copies when VK gives every row the same file: then the
/// candidate rule ([isSameSong]) alone decides.
Map<int, int> findSameSongs(List<SongRow> rows) => planMerges([
  for (final row in rows)
    MergeRow(row, print: const FilePrint(bytes: 1, sample: 1, seconds: 200)),
], mergeLikely: false).copies;

/// A row with the fields the duplicate key reads. [id] also orders the rows:
/// a lower id has been in the library for longer.
SongRow row(
  int id,
  int source,
  String text, {
  int seconds = 200,
  int? trackId,
  String? key,
  int? sameAs,
}) => SongRow(
  id: id,
  sourceId: source,
  sourceKey: key ?? '${source}_$id',
  text: text,
  seconds: seconds,
  vkTrackId: trackId,
  sameAs: sameAs,
);

void main() {
  group('the text of a song', () {
    test('ignores case, punctuation and the dots of ё', () {
      expect(
        songMatchText('АЛЁНА', 'Пой!  (live)'),
        songMatchText('алена', 'пой live'),
      );
    });

    test('keeps artist and title apart from other words', () {
      expect(songMatchText('Кино', 'Группа крови'), 'кино группа крови');
    });
  });

  group('two accounts', () {
    test('the same VK key is one song', () {
      final found = findSameSongs([
        row(1, 1, 'a', key: '5_9'),
        row(2, 2, 'other text', key: '5_9', seconds: 100),
      ]);
      expect(found, {2: 1});
    });

    test('the same track id and a length within 2 s is one song', () {
      final found = findSameSongs([
        row(1, 1, 'a', trackId: 77, seconds: 200),
        row(2, 2, 'relabeled', trackId: 77, seconds: 202),
      ]);
      expect(found, {2: 1});
    });

    test('the same track id with another length stays apart', () {
      final found = findSameSongs([
        row(1, 1, 'a', trackId: 77, seconds: 200),
        row(2, 2, 'a', trackId: 77, seconds: 203),
      ]);
      expect(found, isEmpty);
    });

    test('the same text and exact length is one song without track ids', () {
      expect(findSameSongs([row(1, 1, 'a'), row(2, 2, 'a')]), {2: 1});
    });

    test('the same text and exact length is one song with one track id', () {
      expect(findSameSongs([row(1, 1, 'a', trackId: 5), row(2, 2, 'a')]), {
        2: 1,
      });
    });

    test('different track ids mean VK says the songs differ', () {
      expect(
        findSameSongs([row(1, 1, 'a', trackId: 5), row(2, 2, 'a', trackId: 6)]),
        isEmpty,
      );
    });

    test('the same text with another length stays apart', () {
      expect(
        findSameSongs([row(1, 1, 'a'), row(2, 2, 'a', seconds: 201)]),
        isEmpty,
      );
    });

    test('a song with no text or no length is never matched by text', () {
      expect(findSameSongs([row(1, 1, ''), row(2, 2, '')]), isEmpty);
      expect(
        findSameSongs([row(1, 1, 'a', seconds: 0), row(2, 2, 'a', seconds: 0)]),
        isEmpty,
      );
    });
  });

  group('inside one account', () {
    test('a song listed twice stays twice', () {
      expect(
        findSameSongs([row(1, 1, 'a', trackId: 5), row(2, 1, 'a', trackId: 5)]),
        isEmpty,
      );
    });

    test('only one of its two rows takes the other account\'s song', () {
      final found = findSameSongs([
        row(1, 1, 'a', trackId: 5),
        row(2, 1, 'a', trackId: 5),
        row(3, 2, 'a', trackId: 5),
      ]);
      expect(found, {3: 1});
    });
  });

  group('more accounts', () {
    test('all copies point at the row that was there first', () {
      final found = findSameSongs([
        row(1, 1, 'a', trackId: 5),
        row(2, 2, 'a', trackId: 5),
        row(3, 3, 'a', trackId: 5),
      ]);
      expect(found, {2: 1, 3: 1});
    });

    test('a song new in an older account joins the row already shown', () {
      // Source 2 had the song first, so its row stays the one in History.
      final found = findSameSongs([
        row(7, 2, 'a', trackId: 5),
        row(9, 1, 'a', trackId: 5),
      ]);
      expect(found, {9: 7});
    });

    test('a third account matches a merged song through either copy', () {
      final found = findSameSongs([
        row(1, 1, 'a', trackId: 5, seconds: 200),
        row(2, 2, 'b', trackId: 5, seconds: 202, sameAs: 1),
        row(3, 3, 'b', seconds: 202),
      ]);
      expect(found, {2: 1, 3: 1});
    });
  });

  group('what is merged already', () {
    test('stays merged', () {
      expect(
        findSameSongs([
          row(1, 1, 'a', trackId: 5),
          row(2, 2, 'a', trackId: 5, sameAs: 1),
        ]),
        {2: 1},
      );
    });

    test('stays merged when VK changes its details but not its file', () {
      expect(
        findSameSongs([
          row(1, 1, 'a'),
          row(2, 2, 'renamed', seconds: 300, sameAs: 1),
        ]),
        {2: 1},
      );
    });

    test('a copy joins the oldest row it is one song with', () {
      expect(
        findSameSongs([
          row(1, 1, 'a', trackId: 5),
          row(2, 2, 'x', trackId: 8),
          row(3, 3, 'a', trackId: 5, sameAs: 2),
        ]),
        {3: 1},
      );
    });

    test('one row per account in a group', () {
      expect(
        findSameSongs([
          row(1, 1, 'a', trackId: 5),
          row(2, 2, 'a', trackId: 5, sameAs: 1),
          row(3, 2, 'a', trackId: 5),
        ]),
        {2: 1},
      );
    });
  });
}
