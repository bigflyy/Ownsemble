import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/merge_plan.dart';
import 'package:ownsemble/library/same_song.dart';

/// VK's file "A": the same print on two rows means the same file.
const fileA = FilePrint(bytes: 8770917, sample: 11, seconds: 219.2);

/// Another upload of the same recording: another size, another sample.
const fileB = FilePrint(bytes: 8774052, sample: 22, seconds: 219.3);

/// Another recording under the same `track_id`: the live one.
const fileLive = FilePrint(bytes: 9062443, sample: 33, seconds: 226.5);

/// A row of account [source]; [id] also orders the rows (lower is older).
MergeRow row(
  int id,
  int source, {
  String text = 'операция пластилин ты и я',
  int seconds = 219,
  int? trackId = 74440157,
  String? key,
  int? sameAs,
  FilePrint? print,
  bool likely = false,
}) => MergeRow(
  SongRow(
    id: id,
    sourceId: source,
    sourceKey: key ?? '${source}_$id',
    text: text,
    seconds: seconds,
    vkTrackId: trackId,
    sameAs: sameAs,
  ),
  print: print,
  likely: likely,
);

MergePlan plan(List<MergeRow> rows, {bool likely = false}) =>
    planMerges(rows, mergeLikely: likely);

void main() {
  group('the certain rule', () {
    test('the same file in two accounts is one row', () {
      final merged = plan([row(1, 1, print: fileA), row(2, 2, print: fileA)]);
      expect(merged.copies, {2: 1});
      expect(merged.likely, isEmpty);
    });

    test('the same VK upload is one row without reading its file', () {
      expect(plan([row(1, 1, key: '5_9'), row(2, 2, key: '5_9')]).copies, {
        2: 1,
      });
    });

    test('two files of one track_id and length stay two rows', () {
      expect(
        plan([row(1, 1, print: fileA), row(2, 2, print: fileB)]).copies,
        isEmpty,
      );
    });

    test('equal files of other songs are not merged', () {
      // The print only confirms a candidate; other titles and track_ids
      // are never compared by file.
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, text: 'кино звезда', trackId: 1, print: fileA),
        ]).copies,
        isEmpty,
      );
    });

    test('a copy VK gives no file for stays its own row', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, print: const FilePrint.noFile()),
        ]).copies,
        isEmpty,
      );
      expect(
        plan([
          row(1, 1, print: const FilePrint.noFile()),
          row(2, 2, print: const FilePrint.noFile()),
        ]).copies,
        isEmpty,
      );
    });

    test('rows of one account never merge', () {
      expect(
        plan([row(1, 1, print: fileA), row(2, 1, print: fileA)]).copies,
        isEmpty,
      );
    });
  });

  group('the likely rule', () {
    test('merges files within 1 s, marked, only when switched on', () {
      final rows = [row(1, 1, print: fileA), row(2, 2, print: fileB)];
      expect(plan(rows).copies, isEmpty);
      final merged = plan(rows, likely: true);
      expect(merged.copies, {2: 1});
      expect(merged.likely, {2});
    });

    test('never merges another recording', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, print: fileLive),
        ], likely: true).copies,
        isEmpty,
      );
    });

    test('needs the same track_id', () {
      expect(
        plan([
          row(1, 1, trackId: null, print: fileA),
          row(2, 2, trackId: null, print: fileB),
        ], likely: true).copies,
        isEmpty,
      );
    });

    test('needs listed lengths within 2 s', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, seconds: 222, print: fileB),
        ], likely: true).copies,
        isEmpty,
      );
    });

    test('needs both real lengths', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, print: const FilePrint(bytes: 1, sample: 1)),
        ], likely: true).copies,
        isEmpty,
      );
    });

    test('a certain partner wins over a likely one', () {
      final merged = plan([
        row(1, 1, print: fileA),
        row(2, 2, print: fileB),
        row(3, 3, print: fileA),
      ], likely: true);
      expect(merged.copies, {2: 1, 3: 1});
      expect(merged.likely, {2});
    });
  });

  group('a stored merge', () {
    test('that no longer holds is undone', () {
      expect(
        plan([row(1, 1, print: fileA), row(2, 2, sameAs: 1, print: fileLive)])
            .copies,
        isEmpty,
      );
    });

    test('stays while a file is not read yet', () {
      expect(plan([row(1, 1, print: fileA), row(2, 2, sameAs: 1)]).copies, {
        2: 1,
      });
    });

    test('a likely one not read yet goes when the setting is off', () {
      final rows = [
        row(1, 1, print: fileA),
        row(2, 2, sameAs: 1, likely: true),
      ];
      expect(plan(rows).copies, isEmpty);
      expect(plan(rows, likely: true).likely, {2});
    });

    test('a pair never merged is not merged before both are read', () {
      expect(plan([row(1, 1, print: fileA), row(2, 2)]).copies, isEmpty);
    });
  });

  group('more accounts', () {
    test('all copies point at the oldest row', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, print: fileA),
          row(3, 3, print: fileA),
        ]).copies,
        {2: 1, 3: 1},
      );
    });

    test('a third account matches through either copy', () {
      // Row 3 shares the text with row 2 only, and row 2's file.
      expect(
        plan([
          row(1, 1, text: 'a', print: fileA),
          row(2, 2, text: 'b', print: fileA),
          row(3, 3, text: 'b', trackId: null, print: fileA),
        ]).copies,
        {2: 1, 3: 1},
      );
    });

    test('one row per account in a group', () {
      expect(
        plan([
          row(1, 1, print: fileA),
          row(2, 2, print: fileA),
          row(3, 2, print: fileA),
        ]).copies,
        {2: 1},
      );
    });
  });

  group('rows to print', () {
    SongRow song(int id, int source, {String? key, int? trackId = 5}) =>
        row(id, source, key: key, trackId: trackId).song;

    test('candidates in two accounts under two keys', () {
      expect(rowsToPrint([song(1, 1), song(2, 2), song(3, 1)]), {1, 2, 3});
    });

    test('not one upload in two accounts, nor a single account', () {
      expect(
        rowsToPrint([song(1, 1, key: 'k'), song(2, 2, key: 'k')]),
        isEmpty,
      );
      expect(rowsToPrint([song(1, 1), song(2, 1)]), isEmpty);
    });

    test('not songs that are no candidates', () {
      expect(
        rowsToPrint([row(1, 1, trackId: 5).song, row(2, 2, trackId: 6).song]),
        isEmpty,
      );
    });
  });

  group('the print', () {
    test('samples the start and the quarters', () {
      expect(printOffsets(8000), [0, 2000, 4000, 6000]);
    });

    test('hashes bytes with FNV-1a 64', () {
      // Known values of FNV-1a 64: the empty input and "a".
      expect(fnv1a64([]), 0xcbf29ce484222325);
      expect(
        fnv1a64([
          [0x61],
        ]),
        0xaf63dc4c8601ec8c,
      );
      expect(
        fnv1a64([
          [1, 2],
          [3],
        ]),
        fnv1a64([
          [1, 2, 3],
        ]),
      );
    });
  });
}
