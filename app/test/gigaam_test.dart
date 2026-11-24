// Plan 10 I2c: the GigaAM port against gigaam_app's own results on small
// fixtures (experiments/f2-timing/make_gigaam_fixtures.py).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/gigaam.dart';
import 'package:ownsemble/lyrics/npz.dart';

List<Map<String, Object?>> _cases() => (jsonDecode(
  File('test/fixtures/gigaam/rnnt_small.json').readAsStringSync(),
) as List).cast<Map<String, Object?>>();

RnntHead _head(Map<String, Object?> data) => RnntHead.fromArrays(
  readNpz(base64Decode(data['npz_base64'] as String)),
  blankId: data['blank_id'] as int,
);

Float32List _encoded(Map<String, Object?> data) => Float32List.fromList([
  for (final x in data['encoded'] as List) (x as num).toDouble(),
]);

List<String> _vocab(Map<String, Object?> data) =>
    (data['vocab'] as List).cast<String>();

void main() {
  group('npz', () {
    test('reads numpy.savez arrays with their shapes (zip64 headers)', () {
      for (final data in _cases()) {
        final arrays = readNpz(base64Decode(data['npz_base64'] as String));
        final shapes = (data['shapes'] as Map).cast<String, Object?>();
        expect(arrays.keys.toSet(), shapes.keys.toSet());
        for (final MapEntry(:key, :value) in shapes.entries) {
          expect(arrays[key]!.shape, (value as List).cast<int>(), reason: key);
          expect(
            arrays[key]!.values.length,
            arrays[key]!.shape.fold(1, (a, b) => a * b),
          );
        }
      }
    });

    test('refuses what it cannot read', () {
      expect(
        () => readNpz(Uint8List.fromList(utf8.encode('not a zip at all'))),
        throwsA(isA<NpzFormatError>()),
      );
      final npy = BytesBuilder()
        ..add([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0])
        ..add([0x30, 0])
        ..add(
          latin1.encode(
            "{'descr': '<f8', 'fortran_order': False, 'shape': (2,), }"
                .padRight(47),
          ),
        )
        ..add([0x0A])
        ..add(Uint8List(16));
      expect(
        () => readNpy(npy.toBytes()),
        throwsA(
          isA<NpzFormatError>().having(
            (e) => e.message,
            'message',
            contains('<f8'),
          ),
        ),
      );
    });

    test('reads the real head.npz when the test bundle is there', () {
      final file = File(
        '../.local/v2-test/stt-i2a/models/hear-words-1/gigaam/head.npz',
      );
      if (!file.existsSync()) {
        markTestSkipped('no test bundle');
        return;
      }
      final head = RnntHead.fromArrays(
        readNpz(file.readAsBytesSync()),
        blankId: 1024,
      );
      expect(head.hidden, 320);
      expect(head.encoderDim, 768);
      expect(head.jointDim, 320);
      expect(head.outputs, 1025);
    });
  });

  group('letter groups', () {
    test(
      'match gigaam_app: case, punctuation and yo folded, the mark kept',
      () {
        final data = _cases().first;
        final vocab = _vocab(data);
        final groups = letterGroups(vocab, data['blank_id'] as int);
        expect(
          [for (final g in groups) g?.toList()],
          [
            for (final g in data['groups'] as List)
              g == null ? null : (g as List).cast<int>(),
          ],
        );
      },
    );

    test('keys', () {
      expect(letterKey('▁Вы'), '▁вы');
      expect(letterKey('▁вы,'), '▁вы');
      expect(letterKey('Ёж'), 'еж');
      expect(letterKey(','), '');
      expect(letterKey('▁'), wordStartMark);
      expect(letterKey('Ab1.'), 'ab1');
    });
  });

  group('RNNT decoding', () {
    test('tokens, frames and confidences as gigaam_app', () {
      for (final data in _cases()) {
        final head = _head(data);
        final groups = letterGroups(_vocab(data), data['blank_id'] as int);
        final tokens = head.decode(_encoded(data), groups: groups);
        final expected = (data['tokens'] as List).cast<List>();
        expect(
          [for (final t in tokens) (t.token, t.frame)],
          [for (final t in expected) (t[0] as int, t[1] as int)],
        );
        for (var i = 0; i < tokens.length; i++) {
          final want = expected[i][2] as num?;
          if (want == null) {
            expect(tokens[i].confidence, isNull, reason: 'token $i');
          } else {
            expect(
              tokens[i].confidence,
              closeTo(want, 1e-5),
              reason: 'token $i',
            );
          }
        }
        // Without groups the same tokens, no confidences.
        final plain = head.decode(_encoded(data));
        expect(
          [for (final t in plain) (t.token, t.frame)],
          [
            for (final t in (data['plain_tokens'] as List).cast<List>())
              (t[0] as int, t[1] as int),
          ],
        );
        expect(plain.every((t) => t.confidence == null), isTrue);
      }
    });

    test(
      'both fixture cases are exercised: the symbol limit and early blanks',
      () {
        final [many, few] = _cases();
        int most(Map<String, Object?> data) {
          final perFrame = <int, int>{};
          for (final t in (data['tokens'] as List).cast<List>()) {
            perFrame.update(t[1] as int, (n) => n + 1, ifAbsent: () => 1);
          }
          return perFrame.values.reduce((a, b) => a < b ? a : b);
        }

        expect((many['words'] as List).length, greaterThan(10));
        expect(most(few), lessThan(10));
      },
    );

    test('a chunk of no frames decodes to nothing', () {
      final head = _head(_cases().first);
      expect(head.decode(Float32List(0)), isEmpty);
    });

    test('encoded frames of the wrong width are refused', () {
      final head = _head(_cases().first);
      expect(() => head.decode(Float32List(5)), throwsArgumentError);
    });
  });

  group('words', () {
    test('texts, times and confidences as gigaam_app', () {
      for (final data in _cases()) {
        final model = _model(data);
        final head = _head(data);
        final tokens = head.decode(_encoded(data), groups: model.groups);
        final words = model.words(tokens, (data['offset'] as num).toDouble());
        final expected = (data['words'] as List).cast<List>();
        expect(
          [for (final w in words) w.text],
          [for (final w in expected) w[2]],
        );
        expect(
          [for (final w in words) (w.start, w.end)],
          [
            for (final w in expected)
              ((w[0] as num).toDouble(), (w[1] as num).toDouble()),
          ],
        );
        for (var i = 0; i < words.length; i++) {
          final want = expected[i][3] as num?;
          if (want == null) {
            expect(words[i].confidence, isNull);
          } else {
            expect(words[i].confidence, closeTo(want, 1e-9), reason: 'word $i');
          }
        }
      }
    });

    test('pieces join into words at the start mark; punctuation-only words have no confidence', () {
      final model = _model(_cases().first);
      // 0 = mark+Vy, 2 = la, 3 = ',', 4 = bare mark, 1 = mark+vy,
      final words = model.words([
        (token: 0, frame: 1, confidence: 0.9),
        (token: 2, frame: 2, confidence: 0.6),
        (token: 3, frame: 3, confidence: null),
        (token: 4, frame: 5, confidence: null),
        (token: 3, frame: 6, confidence: null),
        (token: 1, frame: 8, confidence: 0.7),
      ], 1.0);
      expect([for (final w in words) w.text], ['Выла,', ',', 'вы,']);
      expect(words[0].start, 1.04);
      expect(words[0].end, 1.16);
      expect(words[0].confidence, 0.6);
      expect(words[1].confidence, isNull);
      expect(words[1].start, 1.24);
      expect(words[2].confidence, 0.7);
    });
  });

  group('hearing a song', () {
    test('no singing: no chunks, no words, mean 0, not Russian', () {
      final model = _model(_cases().first);
      var encoded = 0;
      final result = hearRussian(
        Float32List(16000 * 20),
        model,
        scan: (state, windows, count) =>
            (state: state, probabilities: Float32List(count)),
        encode: (samples) {
          encoded++;
          return Float32List(0);
        },
      );
      expect(result.chunks, isEmpty);
      expect(result.words, isEmpty);
      expect(result.speechSeconds, 0);
      expect(result.meanConfidence, 0);
      expect(result.isRussian, isFalse);
      expect(encoded, 0);
    });

    test('empty audio: one window searched, nothing heard', () {
      final model = _model(_cases().first);
      var windows = 0;
      final result = hearRussian(
        Float32List(0),
        model,
        scan: (state, w, count) {
          windows += count;
          return (state: state, probabilities: Float32List(count));
        },
        encode: (samples) => Float32List(0),
      );
      expect(windows, 1);
      expect(result.chunks, isEmpty);
    });

    test('chunks go to the encoder in order, words get the chunk offset', () {
      final data = _cases().first;
      final model = _model(data);
      final audio = Float32List(16000 * 30);
      final seen = <int>[];
      var vadDone = false;
      final progress = <(int, int)>[];
      final result = hearRussian(
        audio,
        model,
        // Speech from window 100 to 600 (3.2 s to 19.2 s).
        scan: (state, windows, count) => (
          state: state,
          probabilities: Float32List.fromList([
            for (var i = 0; i < count; i++) i >= 100 && i < 600 ? 0.9 : 0.0,
          ]),
        ),
        onVadDone: () => vadDone = true,
        encode: (samples) {
          expect(vadDone, isTrue);
          seen.add(samples.length);
          return _encoded(data);
        },
        onChunk: (done, total) => progress.add((done, total)),
      );
      expect(result.chunks, hasLength(1));
      final range = result.chunks.single.range;
      // Silero's padding (0.25 s) and 0.1 s rounding (gigaam_app gives
      // the same for this run).
      expect(range, (start: 48000, end: 310400));
      expect(seen, [range.end - range.start]);
      expect(progress, [(1, 1)]);
      final words = result.words;
      expect(words, isNotEmpty);
      expect(words.first.start, greaterThanOrEqualTo(range.start / 16000));
      expect(result.chunks.single.frames, data['frames']);
    });

    test('the route: mean word confidence at 0.80 or more is Russian', () {
      GigaamResult withConfidences(List<double?> values) => GigaamResult(
        samples: 1,
        speechSeconds: 1,
        chunks: [
          (
            range: (start: 0, end: 1),
            frames: 0,
            tokens: const [],
            words: [for (final c in values) HeardWord(0, 1, 'w', c)],
          ),
        ],
      );
      expect(withConfidences([0.8, 0.8]).isRussian, isTrue);
      expect(withConfidences([0.9, 0.69]).isRussian, isFalse);
      // Punctuation-only words do not count.
      expect(withConfidences([0.85, null, null]).meanConfidence, 0.85);
      expect(withConfidences([null]).meanConfidence, 0);
      expect(withConfidences([null]).isRussian, isFalse);
    });
  });
}

GigaamModel _model(Map<String, Object?> data) {
  // A model folder as the bundle holds it, made from the fixture.
  final dir = Directory.systemTemp.createTempSync('gigaam_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final npz = base64Decode(data['npz_base64'] as String);
  final vocab = utf8.encode(jsonEncode(data['vocab']));
  File('${dir.path}/head.npz').writeAsBytesSync(npz);
  File('${dir.path}/vocab.json').writeAsBytesSync(vocab);
  File('${dir.path}/encoder.onnx').writeAsBytesSync([1, 2, 3]);
  File('${dir.path}/model.json').writeAsStringSync(
    jsonEncode({
      'format': 1,
      'name': 'small',
      'type': 'rnnt',
      'sample_rate': 16000,
      'frame_seconds': 0.04,
      'blank_id': data['blank_id'],
      'files': {
        'encoder': {'name': 'encoder.onnx', 'size': 3},
        'vocab': {'name': 'vocab.json', 'size': vocab.length},
        'head': {'name': 'head.npz', 'size': npz.length},
      },
    }),
  );
  return GigaamModel.load(dir.path);
}
