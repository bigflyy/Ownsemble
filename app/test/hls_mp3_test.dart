import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/hls_mp3.dart';
import 'package:ownsemble/media/audio_policy.dart';

Uint8List frame([int value = 0]) =>
    Uint8List.fromList([255, 251, 144, 0, ...List.filled(413, value)]);

void main() {
  test(
    'MP3 normalization strips metadata while retaining every audio frame byte',
    () {
      final audio = frame(1);
      final info = frame()..setRange(36, 40, 'Info'.codeUnits);
      final input = Uint8List.fromList([
        73,
        68,
        51,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        ...info,
        ...audio,
        ...audio,
      ]);
      expect(normalizeMp3Segment(input), [...audio, ...audio]);
    },
  );
  test('MP3 normalization rejects truncated frames, broken tags and junk', () {
    for (final input in [
      frame().sublist(0, 400),
      [73, 68, 51, 4, 0, 0, 0, 0, 0, 20],
      [1, 2, 3, 4, 5],
    ]) {
      expect(
        () => normalizeMp3Segment(Uint8List.fromList(input)),
        throwsA(isA<ProofFailure>()),
      );
    }
  });
  test(
    'MP3 HLS honors implicit sequence IV, key rotation, explicit IV and NONE',
    () async {
      final folder = await Directory.systemTemp.createTemp('ownsemble-mp3-iv-');
      try {
        final algorithm = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
        for (final n in [0, 1]) {
          await File('${folder.path}/part-$n.key')
              .writeAsBytes(List.filled(16, n + 7));
        }
        final audio = frame(1);
        for (final item in [(2, 7, 7), (3, 8, 10)]) {
          final box = await algorithm.encrypt(
            audio,
            secretKey: SecretKey(List.filled(16, item.$2)),
            nonce: [...List.filled(15, 0), item.$3],
          );
          await File('${folder.path}/part-${item.$1}.ts')
              .writeAsBytes(box.cipherText);
        }
        await File('${folder.path}/part-4.ts').writeAsBytes(audio);
        expect(
          await materializeHlsAudio(folder, [
            '#EXTM3U',
            '#EXT-X-MEDIA-SEQUENCE:7',
            '#EXT-X-KEY:METHOD=AES-128,URI="part-0.key"',
            'part-2.ts',
            '#EXT-X-KEY:METHOD=AES-128,URI="part-1.key",IV=0x0a',
            'part-3.ts',
            '#EXT-X-KEY:METHOD=NONE',
            'part-4.ts',
            '#EXT-X-ENDLIST',
          ]),
          'audio.mp3',
        );
        expect(await File('${folder.path}/audio.mp3').readAsBytes(), [
          ...audio,
          ...audio,
          ...audio,
        ]);
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'non-MP3 content keeps HLS and malformed encryption is rejected',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-mp3-reject-',
      );
      try {
        await File('${folder.path}/part-0.ts')
            .writeAsBytes(List.filled(100, 3));
        expect(
          await materializeHlsAudio(folder, [
            '#EXTM3U',
            'part-0.ts',
            '#EXT-X-ENDLIST',
          ]),
          isNull,
        );
        expect(await File('${folder.path}/audio.mp3').exists(), isFalse);
        await File('${folder.path}/part-1.key')
            .writeAsBytes(List.filled(16, 7));
        await expectLater(
          materializeHlsAudio(folder, [
            '#EXTM3U',
            '#EXT-X-KEY:METHOD=AES-128,URI="part-1.key"',
            'part-0.ts',
            '#EXT-X-ENDLIST',
          ]),
          throwsA(isA<ProofFailure>()),
        );
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
}
