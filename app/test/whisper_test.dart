// Plan 10 I2d: the Whisper words against gigaam_app's own results on small
// fixtures (experiments/f2-timing/make_whisper_fixtures.py), the chunk
// loop on a fake recogniser, and the bridge's refusals.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/whisper.dart';
import 'package:ownsemble/lyrics/whisper_cpp.dart';
import 'package:path/path.dart' as p;

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

List<WhisperToken> _tokens(List<Object?> data) => [
  for (final item in data.cast<List<Object?>>())
    (
      bytes: _hex(item[0] as String),
      start: (item[1] as int) * whisperTimeStep,
      end: (item[2] as int) * whisperTimeStep,
      probability: (item[3] as num).toDouble(),
    ),
];

WhisperToken _token(String text, double start, double end, double p) =>
    (bytes: utf8.encode(text), start: start, end: end, probability: p);

/// The bridge of a release build, if one was built, or the one named by
/// OWNSEMBLE_WHISPER_BRIDGE (built on its own: native/whisper_bridge).
String? _builtBridge() {
  final named = Platform.environment['OWNSEMBLE_WHISPER_BRIDGE'];
  if (named != null && File(named).existsSync()) return named;
  final path = p.absolute(
    'build',
    'windows',
    'x64',
    'runner',
    'Release',
    whisperBridgeName,
  );
  return File(path).existsSync() ? path : null;
}

void main() {
  group('whisperWords', () {
    final cases = (jsonDecode(
      File('test/fixtures/whisper/words.json').readAsStringSync(),
    ) as List).cast<Map<String, Object?>>();

    test('matches gigaam_app on every fixture case', () {
      var words = 0;
      for (final (index, data) in cases.indexed) {
        final heard = whisperWords(
          _tokens(data['tokens'] as List<Object?>),
          (data['offset'] as num).toDouble(),
          (data['duration'] as num?)?.toDouble(),
        );
        final expected = (data['words'] as List).cast<List<Object?>>();
        expect(heard.length, expected.length, reason: 'case $index');
        for (final (i, word) in heard.indexed) {
          final [start, end, text, confidence] = expected[i];
          final reason = 'case $index word $i';
          expect(word.start, (start as num).toDouble(), reason: reason);
          expect(word.end, (end as num).toDouble(), reason: reason);
          expect(word.text, text, reason: reason);
          expect(
            word.confidence,
            (confidence as num?)?.toDouble(),
            reason: reason,
          );
        }
        words += heard.length;
      }
      expect(words, greaterThan(2000));
    });

    test('joins a Cyrillic letter split between tokens before decoding', () {
      final bytes = utf8.encode('мир');
      final words = whisperWords([
        (
          bytes: Uint8List.fromList([0x20, ...bytes.sublist(0, 3)]),
          start: 1.0,
          end: 1.2,
          probability: 0.9,
        ),
        (
          bytes: Uint8List.fromList(bytes.sublist(3)),
          start: 1.2,
          end: 1.5,
          probability: 0.6,
        ),
      ], 10.0);
      expect(words.single.text, 'мир');
      expect(words.single.start, 11.0);
      expect(words.single.end, 11.5);
      // 0.6 lies between the scale's 0.5 -> 0.80 and 0.7 -> 0.97.
      expect(words.single.confidence, 0.885);
    });

    test('keeps times inside the chunk and in order', () {
      final words = whisperWords(
        [
          _token(' a', 3.0, 4.0, 0.9),
          _token(' b', 1.0, 2.0, 0.9),
          _token(' c', 9.0, 12.0, 0.9),
        ],
        100.0,
        5.0,
      );
      expect([for (final w in words) w.start], [103.0, 103.0, 105.0]);
      expect([for (final w in words) w.end], [104.0, 103.0, 105.0]);
    });

    test('punctuation alone has no confidence', () {
      final words = whisperWords([
        _token(' ...', 0, 1, 0.2),
        _token(' la', 1, 2, 0.99),
      ], 0);
      expect(words.first.confidence, isNull);
      expect(words.last.confidence, isNotNull);
    });
  });

  test('a NaN probability gives what gigaam_app gives', () {
    // Python: min(1.0, max(0.0, nan)) is 0.0; min(lowest, nan) keeps lowest,
    // min(nan, p) keeps nan (values from gigaam_app's own functions).
    expect(whisperConfidence(double.nan), 0.0);
    final first = whisperWords([
      _token(' la', 0.0, 0.5, double.nan),
      _token('la', 0.5, 0.7, 0.6),
    ], 0);
    expect(first.single.confidence, 0.0);
    final second = whisperWords([
      _token(' la', 0.0, 0.5, 0.6),
      _token('la', 0.5, 0.7, double.nan),
    ], 0);
    expect(second.single.confidence, 0.885);
  });

  test('a byte order mark at the start is kept, as Python keeps it', () {
    final words = whisperWords([
      (
        bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x61]),
        start: 0.0,
        end: 0.5,
        probability: 0.9,
      ),
    ], 0);
    expect(words.single.text, '\ufeffa');
    expect(pythonDecode(Uint8List.fromList([0xEF, 0xBB, 0xBF])), '\ufeff');
  });

  test('whisperConfidence matches gigaam_app', () {
    final values = (jsonDecode(
      File('test/fixtures/whisper/confidence.json').readAsStringSync(),
    ) as List).cast<List<Object?>>();
    for (final [probability, expected] in values) {
      expect(
        whisperConfidence((probability as num).toDouble()),
        (expected as num).toDouble(),
        reason: '$probability',
      );
    }
  });

  test('tokenHasLetters counts a part of a character as a letter', () {
    expect(tokenHasLetters(utf8.encode(' a')), isTrue);
    expect(tokenHasLetters(utf8.encode(' 7')), isTrue);
    expect(tokenHasLetters(utf8.encode(' ,!')), isFalse);
    expect(tokenHasLetters(Uint8List.fromList([0xE4, 0xBD])), isTrue);
    expect(tokenHasLetters(Uint8List(0)), isFalse);
  });

  test('pythonStrip removes what str.strip removes', () {
    expect(pythonStrip('\u001c a  　'), 'a');
    expect(pythonStrip('﻿a'), '﻿a');
    expect(pythonStrip('   '), '');
  });

  test('hearWithWhisper moves each chunk by its start', () {
    final audio = Float32List(16000 * 40);
    final seen = <int>[];
    final languages = ['en', 'ja'];
    final result = hearWithWhisper(
      audio,
      (
        ranges: [
          (start: 16000, end: 16000 * 11),
          (start: 16000 * 20, end: 16000 * 22),
        ],
        speechSeconds: 12.5,
      ),
      transcribe: (samples) {
        seen.add(samples.length);
        return (
          language: languages[seen.length - 1],
          tokens: [
            _token(' one', 0.5, 0.9, 0.95),
            _token(' two', 1.0, 9.0, 0.4),
          ],
        );
      },
    );
    expect(seen, [160000, 32000]);
    expect(result.speechSeconds, 12.5);
    expect([for (final c in result.chunks) c.language], languages);
    final words = result.words;
    expect([for (final w in words) w.start], [1.5, 2.0, 20.5, 21.0]);
    // The second chunk is 2 s long: its last word ends there.
    expect([for (final w in words) w.end], [1.9, 10.0, 20.9, 22.0]);
    expect(result.meanConfidence, closeTo((0.995 + 0.64) / 2, 1e-9));
  });

  group('the bridge', () {
    final bridge = _builtBridge();

    test('refuses a folder without whisper.cpp', () {
      final empty = Directory.systemTemp.createTempSync('ow-empty');
      addTearDown(() => empty.deleteSync());
      expect(
        () => WhisperLibrary.load(bridge!, empty.path),
        throwsA(
          isA<WhisperError>().having(
            (e) => e.message,
            'message',
            contains('ggml-base'),
          ),
        ),
      );
    }, skip: bridge == null ? 'no release build' : false);

    test(
      'a folder with only part of whisper.cpp is refused and left unlocked',
      () {
        final source = _bundleLibraries();
        final partial = Directory.systemTemp.createTempSync('ow-partial');
        addTearDown(() {
          if (partial.existsSync()) partial.deleteSync(recursive: true);
        });
        final copy = File(p.join(source!, 'ggml-base.dll'))
            .copySync(p.join(partial.path, 'ggml-base.dll'));
        expect(
          () => WhisperLibrary.load(bridge!, partial.path),
          throwsA(
            isA<WhisperError>().having(
              (e) => e.message,
              'message',
              contains('ggml.dll'),
            ),
          ),
        );
        // Windows cannot delete a DLL that is still loaded: the bridge
        // closed ggml-base again after the failure.
        copy.deleteSync();
        expect(copy.existsSync(), isFalse);
      },
      skip: bridge == null || _bundleLibraries() == null
          ? 'no release build or no test bundle'
          : false,
    );

    test(
      'after a failed load the bundle loads, offers no GPU, refuses one',
      () {
        // A folder with ggml-base.dll alone: ggml-base loads (and sets its
        // terminate handler), the load fails, ggml-base is unloaded. The
        // next load used to abort the process in ggml's own assert (plan
        // 10 I2i1): the bridge now puts the old handler back.
        final source = _bundleLibraries()!;
        final partial = Directory.systemTemp.createTempSync('ow-partial2');
        addTearDown(() {
          if (partial.existsSync()) partial.deleteSync(recursive: true);
        });
        File(p.join(source, 'ggml-base.dll'))
            .copySync(p.join(partial.path, 'ggml-base.dll'));
        expect(
          () => WhisperLibrary.load(bridge!, partial.path),
          throwsA(isA<WhisperError>()),
        );
        final library = WhisperLibrary.load(bridge!, source);
        expect(library.gpus, isEmpty);
        expect(
          () => library.open('no-model.bin', gpu: 0),
          throwsA(
            isA<WhisperError>().having(
              (e) => e.message,
              'message',
              contains('no GPU 0'),
            ),
          ),
        );
      },
      skip: bridge == null || _bundleLibraries() == null
          ? 'no release build or no test bundle'
          : false,
    );
  });
}

/// The whisper.cpp folder of the test bundle, if it was downloaded
/// (.local/v2-test/stt-i2a, tool/check_stt_bundles.dart).
String? _bundleLibraries() {
  final folder = p.absolute(
    '..',
    '.local',
    'v2-test',
    'stt-i2a',
    'models',
    'whisper-turbo-1',
    'whisper.cpp',
  );
  return File(p.join(folder, 'ggml-base.dll')).existsSync() ? folder : null;
}
