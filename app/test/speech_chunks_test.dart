// Plan 10 I2c: Silero's chunks against gigaam_app's ChunkFinder on
// probability runs it was given (experiments/f2-timing/
// make_gigaam_fixtures.py), Python's rounding, and the window layout.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/speech_chunks.dart';

void main() {
  group('ChunkFinder as gigaam_app', () {
    final cases = (jsonDecode(
      File('test/fixtures/gigaam/chunks.json').readAsStringSync(),
    ) as List).cast<Map<String, Object?>>();

    for (final data in cases) {
      test('${data['name']} at ${data['threshold']}', () {
        final finder = ChunkFinder(
          data['samples'] as int,
          VadOptions(threshold: (data['threshold'] as num).toDouble()),
        );
        final chunks = <SampleRange>[];
        final probabilities = data['probabilities'] as List;
        for (var i = 0; i < probabilities.length; i++) {
          chunks.addAll(finder.feed(i, (probabilities[i] as num).toDouble()));
        }
        chunks.addAll(finder.finish());
        List<(int, int)> pairs(Object? list) => [
          for (final pair in (list as List).cast<List>())
            (pair[0] as int, pair[1] as int),
        ];
        expect([
          for (final c in chunks) (c.start, c.end),
        ], pairs(data['chunks']));
        expect([
          for (final r in finder.regions) (r.start, r.end),
        ], pairs(data['regions']));
        expect(
          finder.speechSeconds,
          closeTo((data['speech_seconds'] as num).toDouble(), 1e-9),
        );
      });
    }

    test('the fixtures cover forced cuts, silence and speech to the end', () {
      final names = {
        for (final c in cases)
          if ((c['chunks'] as List).isNotEmpty) c['name'],
      };
      expect(names, containsAll(['pauses', 'long', 'noise', 'to_end']));
      expect(
        cases
            .where((c) => c['name'] == 'silence')
            .every((c) => (c['chunks'] as List).isEmpty),
        isTrue,
      );
    });
  });

  test('pythonRound matches Python round(x, 1) and round(x, 3)', () {
    final rows = (jsonDecode(
      File('test/fixtures/gigaam/rounding.json').readAsStringSync(),
    ) as List).cast<List>();
    for (final [x as num, one as num, three as num] in rows) {
      expect(pythonRound(x.toDouble(), 1), one.toDouble(), reason: '$x, 1');
      expect(pythonRound(x.toDouble(), 3), three.toDouble(), reason: '$x, 3');
    }
    // Exact ties go to the even digit, as in Python.
    expect(pythonRoundTenth(0.25), 0.2);
    expect(pythonRoundTenth(0.75), 0.8);
    expect(pythonRound(0.0625, 3), 0.062);
  });

  group('sileroBlocks', () {
    test(
      'windows carry 64 samples of context and zero padding; state carried',
      () {
        final audio = Float32List.fromList([
          for (var i = 0; i < 1300; i++) i + 1.0,
        ]);
        final calls = <(int, Float32List, Float32List)>[];
        final firsts = <int>[];
        var step = 0;
        sileroBlocks(
          audio,
          (state, windows, count) {
            calls.add((count, Float32List.fromList(state), windows));
            step++;
            return (
              state: Float32List(sileroStateSize)
                ..fillRange(0, sileroStateSize, step.toDouble()),
              probabilities: Float32List(count),
            );
          },
          (first, probabilities) => firsts.add(first),
          block: 2,
        );
        // 1300 samples = 3 windows (the last padded), in blocks of 2.
        expect([for (final c in calls) c.$1], [2, 1]);
        expect(firsts, [0, 2]);
        // The first call starts from a zero state, the second gets the
        // state the first returned.
        expect(calls[0].$2.every((v) => v == 0), isTrue);
        expect(calls[1].$2.every((v) => v == 1), isTrue);
        const span = sileroContext + sileroWindow;
        final first = calls[0].$3;
        expect(first.length, 2 * span);
        // Window 0: 64 zeros, then samples 0..511.
        expect(first.sublist(0, 64).every((v) => v == 0), isTrue);
        expect(first[64], 1.0);
        expect(first[span - 1], 512.0);
        // Window 1: samples 448..1023.
        expect(first[span], 449.0);
        expect(first[2 * span - 1], 1024.0);
        // Window 2: samples 960..1299, then zeros.
        final last = calls[1].$3;
        expect(last[0], 961.0);
        expect(last[1300 - 960 - 1], 1300.0);
        expect(last.sublist(1300 - 960).every((v) => v == 0), isTrue);
      },
    );

    test('empty audio is one silent window', () {
      final counts = <int>[];
      sileroBlocks(Float32List(0), (state, windows, count) {
        counts.add(count);
        expect(windows.every((v) => v == 0), isTrue);
        return (state: state, probabilities: Float32List(count));
      }, (_, _) {});
      expect(counts, [1]);
    });
  });
}
