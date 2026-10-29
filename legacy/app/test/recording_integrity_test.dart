import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/vk_provider.dart';
import 'package:ownsemble/data/library_store.dart';

void main() {
  test(
    'an offline identity marker belongs to the exact current cache digest',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-identity-marker-',
      );
      final store = LibraryStore(folder)
        ..merge([const Track('1_1', 'Generated', 'Fixture', 12)]);
      const first = CachedAudio('1_1', 'generated.mp3', 'first', 3, 12),
          replacement = CachedAudio(
            '1_1',
            'generated.mp3',
            'replacement',
            3,
            12,
          );
      try {
        store.saveAsset(first);
        expect(store.verifiedAssetIds(), isEmpty);
        expect(store.markAssetIdentity(first), isTrue);
        expect(store.verifiedAssetIds(), {'1_1'});
        store.saveAsset(replacement);
        expect(store.verifiedAssetIds(), isEmpty);
        expect(store.markAssetIdentity(first), isFalse);
        expect(store.verifiedAssetIds(), isEmpty);
      } finally {
        store.close();
        await folder.delete(recursive: true);
      }
    },
  );
  test('cancellation after archiving restores the old publication instead of publishing a replacement', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-replace-cancel-',
    );
    final first = AudioCache(
      folder,
      (_) async => 12,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList([1, 2, 3]),
    );
    const track = Track('1_1', 'Generated', 'Fixture', 12);
    final old = await first.save(
      track,
      Uri.parse('https://test.vkuseraudio.ru/old.mp3'),
    );
    final replacement = AudioCache(
      folder,
      (_) async => 12,
      cancelled: () =>
          Directory('${folder.path}/quarantine').existsSync() &&
          Directory('${folder.path}/quarantine').listSync().isNotEmpty,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList([4, 5, 6]),
    );
    try {
      await expectLater(
        replacement.save(
          track,
          Uri.parse('https://test.vkuseraudio.ru/selected.mp3'),
          recordingEvidence: 'metadata_row',
          preserveExisting: true,
        ),
        throwsA(isA<ProofFailure>()),
      );
      expect(File(old.entry).readAsBytesSync(), [1, 2, 3]);
    } finally {
      first.cancel();
      replacement.cancel();
      await folder.delete(recursive: true);
    }
  });
  test('a resolver result for another recording cannot be played or cached under this one', () {
    final wrong = ResolvedAudio(
      Uri.parse('https://test.vkuseraudio.ru/next.mp3'),
      'Fixture',
      recordingId: '1_2',
      evidence: 'metadata_row',
    );
    expect(
      () => wrong.requireTrack(const Track('1_1', 'Generated', 'Fixture', 12)),
      throwsA(isA<ProofFailure>()),
    );
  });
  test('legacy cache needs identity proof and replacement preserves its original files', () async {
    final folder = await Directory.systemTemp.createTemp('ownsemble-receipt-');
    var value = 1;
    final cache = AudioCache(
      folder,
      (_) async => 12,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList([value, 2, 3]),
    );
    const track = Track('1_1', 'Generated', 'Fixture', 12);
    try {
      final legacy = await cache.save(
        track,
        Uri.parse('https://test.vkuseraudio.ru/old.mp3'),
      );
      await expectLater(
        cache.verify(legacy, expectedTrack: track, requireIdentity: true),
        throwsA(
          isA<ProofFailure>().having(
            (failure) => failure.category,
            'category',
            'cache_identity_unverified',
          ),
        ),
      );
      expect(File(legacy.entry).readAsBytesSync(), [1, 2, 3]);
      value = 4;
      final repaired = await cache.save(
        track,
        Uri.parse('https://test.vkuseraudio.ru/selected.mp3'),
        recordingEvidence: 'metadata_row',
        preserveExisting: true,
      );
      await cache.verify(repaired, expectedTrack: track, requireIdentity: true);
      expect(File(repaired.entry).readAsBytesSync(), [4, 2, 3]);
      final originals = Directory('${folder.path}/quarantine')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('audio.mp3'));
      expect(originals.length, 1);
      expect(originals.single.readAsBytesSync(), [1, 2, 3]);
      await expectLater(
        cache.verify(
          repaired,
          expectedTrack: const Track('1_2', 'Other', 'Fixture', 12),
          requireIdentity: true,
        ),
        throwsA(isA<ProofFailure>()),
      );
    } finally {
      cache.cancel();
      await folder.delete(recursive: true);
    }
  });
  test('the only network request may be the next song prefetch and is not recording proof', () {
    final next = Uri.parse('https://test.vkuseraudio.ru/next.m3u8');
    expect(
      () => selectSource({next}, requireBinding: true),
      throwsA(
        isA<ProofFailure>().having(
          (failure) => failure.category,
          'category',
          'audio_identity_unverified',
        ),
      ),
    );
    final selected = Uri.parse('https://test.vkuseraudio.ru/selected.m3u8');
    expect(
      selectSource({next}, requireBinding: true, boundSource: selected),
      selected,
    );
  });
  test('a complete but longer different recording is not accepted as the requested song', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-recording-integrity-',
    );
    final cache = AudioCache(
      folder,
      (_) async => 12,
      resourceLoader: (_, {required userAgent, required limit}) async =>
          Uint8List.fromList([1, 2, 3]),
    );
    try {
      await expectLater(
        cache.save(
          const Track('1_1', 'Requested', 'Generated', 4),
          Uri.parse('https://test.vkuseraudio.ru/next.mp3'),
        ),
        throwsA(
          isA<ProofFailure>().having(
            (failure) => failure.category,
            'category',
            'audio_duration_mismatch',
          ),
        ),
      );
      expect(folder.listSync(), isEmpty);
    } finally {
      cache.cancel();
      await folder.delete(recursive: true);
    }
  });

  test(
    'a legacy cached mismatch cannot pass by verifying its own wrong bytes',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-legacy-identity-',
      );
      final cache = AudioCache(
        folder,
        (_) async => 12,
        resourceLoader: (_, {required userAgent, required limit}) async =>
            Uint8List.fromList([1, 2, 3]),
      );
      try {
        final old = await cache.save(
          const Track('1_1', 'Generated next recording', 'Fixture', 12),
          Uri.parse('https://test.vkuseraudio.ru/next.mp3'),
        );
        await expectLater(
          cache.verify(
            old,
            expectedTrack: const Track(
              '1_1',
              'Generated requested',
              'Fixture',
              4,
            ),
          ),
          throwsA(
            isA<ProofFailure>().having(
              (failure) => failure.category,
              'category',
              'audio_duration_mismatch',
            ),
          ),
        );
        expect(File(old.entry).existsSync(), isTrue);
      } finally {
        cache.cancel();
        await folder.delete(recursive: true);
      }
    },
  );
}
