import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  late Directory folder;
  late LibraryStore store;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-metadata-');
    store = LibraryStore(folder);
    store.merge([
      const Track('1_2', 'Generated', 'Fixture', 180),
    ], discoveredAt: 1609459200000);
  });
  tearDown(() async {
    store.close();
    await folder.delete(recursive: true);
  });

  test('import date survives later refresh and reopening instead of becoming today', () {
    store.merge([
      const Track('1_2', 'Renamed', 'Fixture', 180),
    ], discoveredAt: 1704067200000);
    expect(store.importedAt('1_2')!.millisecondsSinceEpoch, 1609459200000);
    store.close();
    store = LibraryStore(folder);
    expect(store.importedAt('1_2')!.millisecondsSinceEpoch, 1609459200000);
    expect(store.metadata('1_2')['vkAddedAt'], isNull);
  });

  test('partial metadata enriches without erasing previous fields or persisting URLs', () {
    store.mergeMetadata('1_2', {
      'album': 'Generated album',
      'subtitle': 'Live',
      'uploadedAt': 1514764800,
      'explicit': true,
      'artists': ['Fixture'],
      'artworkURL': 'https://test.userapi.com/temp.jpg',
    });
    store.mergeMetadata('1_2', {'album': '', 'subtitle': null});
    final meta = store.metadata('1_2');
    expect(meta['album'], 'Generated album');
    expect(meta['subtitle'], 'Live');
    expect(meta['uploadedAt'], 1514764800);
    expect(meta['vkAddedAt'], isNull);
    expect(meta.containsKey('artworkURL'), isFalse);
    expect(meta.containsKey('token'), isFalse);
  });

  test('additive metadata migration preserves v1 cache, pins, listens and Pile occurrences', () {
    final pile = store.createPile('Generated pile');
    store.addToPile(pile, '1_2');
    store.addToPile(pile, '1_2');
    store.pinTrack('1_2', true);
    store.saveAsset(
      const CachedAudio('1_2', 'generated.mp3', 'generated', 100, 180),
    );
    store.startPlay('1_2');
    store.close();
    store = LibraryStore(folder);
    store.mergeMetadata('1_2', {'album': 'Generated album'});
    expect(store.rows(pile: pile).length, 2);
    expect(store.isPinned('1_2'), isTrue);
    expect(store.asset('1_2'), isNotNull);
    expect(store.rows(view: 'recent').length, 1);
    expect(store.db.select('PRAGMA user_version').first.values.first, 1);
  });

  test(
    'lyrics preserve successful content across transient failures and restart',
    () {
      store.saveLyrics('1_2', {
        'text': 'Generated line',
        'lines': [
          {'time_ms': 1000, 'text': 'Generated line'},
        ],
      }, state: 'available');
      store.saveLyrics('1_2', null, state: 'failed');
      store.close();
      store = LibraryStore(folder);
      expect(store.lyrics('1_2')['state'], 'available');
      expect(store.lyrics('1_2')['text'], 'Generated line');
      expect(store.lyrics('1_2')['lines'][0]['time_ms'], 1000);
    },
  );

  test('artwork keys cannot escape the app cache', () {
    expect(
      () => store.saveArtwork('1_2', '../../outside.png'),
      throwsA(isA<ProofFailure>()),
    );
    store.saveArtwork('1_2', '${'a' * 64}.img');
    expect(store.artworkKey('1_2'), '${'a' * 64}.img');
  });
}
