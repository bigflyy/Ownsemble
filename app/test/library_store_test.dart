import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_cache.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  late Directory folder;
  late LibraryStore store;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('ownsemble-library-');
    store = LibraryStore(folder);
    store.merge(const [
      Track('1_1', 'Отголоски', 'Северный свет', 120),
      Track('1_2', 'Another', 'Artist', 40),
      Track('1_3', 'Third', 'Artist', 60),
    ]);
  });
  tearDown(() async {
    store.close();
    await folder.delete(recursive: true);
  });
  test(
    'adding music references preserves an existing v1 catalog and organization',
    () {
      final pile = store.createPile('Generated pile');
      store.addToPile(pile, '1_1');
      store.pinTrack('1_1', true);
      store.startPlay('1_1');
      store.saveAsset(
        const CachedAudio('1_1', 'generated.mp3', 'generated', 100, 120),
      );
      store.db.execute('DROP TABLE music_refs');
      store.close();
      store = LibraryStore(folder);
      expect(store.count, 3);
      expect(store.rows(pile: pile).single.track.id, '1_1');
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_1').pinned,
        isTrue,
      );
      expect(store.asset('1_1'), isNotNull);
      expect(store.rows(view: 'recent').single.track.id, '1_1');
      expect(store.db.select('PRAGMA user_version').first.values.first, 1);
      store.saveMusicReference('1_1', 'generated_track_reference');
      store.close();
      store = LibraryStore(folder);
      expect(store.musicReference('1_1'), 'generated_track_reference');
      expect(store.musicReference('1_2'), isNull);
      expect(
        () => store.saveMusicReference('1_1', 'invalid reference'),
        throwsA(isA<ProofFailure>()),
      );
    },
  );
  test(
    'availability refresh preserves the library and unrelated playback errors',
    () {
      store.trackError('1_1', 'audio_network_failed');
      store.noteAvailability('1_1', false);
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_1').error,
        'audio_network_failed',
      );
      store.noteAvailability('1_2', true);
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_2').error,
        'audio_restricted',
      );
      store.noteAvailability('1_2', false);
      expect(
        store.rows().firstWhere((row) => row.track.id == '1_2').error,
        isNull,
      );
      expect(store.count, 3);
    },
  );

  test('old inferred unavailable statuses become retryable without losing saved data', () {
    store.trackError('1_1', 'audio_source_unavailable');
    store.trackError('1_2', 'audio_network_failed');
    store.setSetting('availability_status_version', 1);
    final pile = store.createPile('Generated recovery');
    store.addToPile(pile, '1_1');
    store.pinTrack('1_1', true);
    store.close();
    store = LibraryStore(folder);
    expect(
      store.rows().firstWhere((row) => row.track.id == '1_1').error,
      'audio_source_not_resolved',
    );
    expect(
      store.rows().firstWhere((row) => row.track.id == '1_2').error,
      'audio_network_failed',
    );
    expect(store.rows(pile: pile).single.track.id, '1_1');
    expect(store.isPinned('1_1'), isTrue);
    expect(store.count, 3);
    expect(store.db.select('PRAGMA user_version').first.values.first, 1);
  });

  test('VK order survives restart and late discovery does not put old records first', () {
    store.merge([
      const Track('2_1', 'Generated late discovery', 'Fixture', 180),
    ], discoveredAt: store.now + 1000);
    expect(store.rows().first.track.id, '2_1');
    store.transaction(() {
      store.noteProviderPosition('1_1', 0, 10);
      store.noteProviderPosition('1_2', 1, 10);
      store.noteProviderPosition('2_1', 100, 10);
    });
    expect(store.rows().take(3).map((row) => row.track.id), [
      '1_1',
      '1_2',
      '2_1',
    ]);
    final pile = store.createPile('Generated pile order');
    store.addToPile(pile, '1_1');
    store.addToPile(pile, '2_1');
    expect(store.rows(pile: pile).map((row) => row.track.id), ['2_1', '1_1']);
    store.close();
    store = LibraryStore(folder);
    expect(store.rows().first.track.id, '1_1');
    store.noteProviderPosition('1_2', 0, 11);
    expect(store.rows().first.track.id, '1_2');
    expect(store.count, 4);
  });

  test('partial scans merge idempotently without deleting unseen tracks', () {
    store.merge(const [Track('1_1', 'Updated', 'Северный свет', 121)]);
    expect(store.count, 3);
    expect(store.track('1_1')!.title, 'Updated');
    expect(store.track('1_2'), isNotNull);
  });
  test('3000 pinned records and Cyrillic case-insensitive literal search', () {
    store.merge(
      List.generate(3000, (i) => Track('2_$i', 'Song $i', 'Fixture', 30)),
    );
    expect(store.count, 3003);
    store.transaction(() {
      for (var i = 0; i < 3000; i++) {
        store.pinTrack('2_$i', true);
      }
    });
    final watch = Stopwatch()..start();
    expect(store.rows().where((row) => row.pinned), hasLength(3000));
    // Timing is diagnostic, never a machine-dependent pass condition.
    debugPrint(
      'Generated 3003-row pinned library read: ${watch.elapsedMilliseconds} ms',
    );
    expect(store.rows(query: 'СЕВЕРНЫЙ СВЕТ').single.track.id, '1_1');
    expect(store.rows(query: "'; DROP TABLE tracks; --"), isEmpty);
    expect(store.rows(query: '%'), isEmpty);
    expect(store.count, 3003);
  });
  test('A B A occurrences remain independent across restart and deletion', () {
    final pile = store.piles().first.id;
    final a = store.addToPile(pile, '1_1');
    store.addToPile(pile, '1_2');
    final again = store.addToPile(pile, '1_1');
    expect(store.rows(pile: pile).map((r) => r.track.id), [
      '1_1',
      '1_2',
      '1_1',
    ]);
    expect(a, isNot(again));
    store.close();
    store = LibraryStore(folder);
    store.removeOccurrence(again);
    expect(store.rows(pile: pile).map((r) => r.occurrence), contains(a));
    expect(store.count, 3);
  });
  test('overlapping track and list pins release independently', () {
    final first = store.piles().first.id, second = store.createPile('Second');
    store.addToPile(first, '1_1');
    store.addToPile(second, '1_1');
    store.pinTrack('1_1', true);
    store.pinPile(first, true);
    store.pinPile(second, true);
    store.pinTrack('1_1', false);
    store.pinPile(first, false);
    expect(store.isPinned('1_1'), isTrue);
    store.deletePile(second);
    expect(store.isPinned('1_1'), isFalse);
  });
  test(
    'pinned list grows with additions and removing an occurrence retains audio',
    () {
      final pile = store.piles().first.id;
      store.pinPile(pile, true);
      final entry = store.addToPile(pile, '1_2');
      expect(store.isPinned('1_2'), isTrue);
      store.removeOccurrence(entry);
      expect(store.isPinned('1_2'), isTrue);
      expect(store.pendingPins, ['1_2']);
      store.pinPile(pile, false);
      expect(store.pendingPins, isEmpty);
    },
  );
  test('LRU excludes pins and current or downloading tracks', () {
    for (var i = 1; i <= 3; i++) {
      store.saveAsset(CachedAudio('1_$i', 'path$i', 'hash', 100, 120));
    }
    store.pinTrack('1_1', true);
    expect(store.evictionOrder({'1_2'}), ['1_3']);
    expect(store.usedBytes(pinned: true), 100);
    expect(store.usedBytes(pinned: false), 200);
    expect(store.rows(view: 'offline'), hasLength(3));
  });
  test(
    'qualified listens count once and recent includes unqualified starts',
    () {
      final first = store.startPlay('1_1');
      store.listen(first, 29000, 120);
      expect(store.rows(view: 'most'), isEmpty);
      store.listen(first, 30000, 120);
      store.listen(first, 60000, 120);
      final short = store.startPlay('1_2');
      store.listen(short, 20000, 40);
      final repeat = store.startPlay('1_1');
      store.listen(repeat, 30000, 120);
      store.startPlay('1_3');
      expect(store.rows(view: 'most').map((r) => r.track.id), ['1_1', '1_2']);
      expect(store.rows(view: 'recent').map((r) => r.track.id), [
        '1_3',
        '1_1',
        '1_2',
      ]);
    },
  );
  test(
    'metadata refresh keeps discovery order and new additions come first',
    () {
      store.merge(const [
        Track('3_1', 'First', 'Artist', 4),
        Track('3_2', 'Second', 'Artist', 4),
      ], discoveredAt: store.now + 1000);
      store.merge(const [
        Track('3_3', 'Third', 'Artist', 4),
      ], discoveredAt: store.now + 1000);
      final before = store.rows().map((r) => r.track.id).toList();
      store.merge(const [
        Track('3_2', 'Renamed', 'Artist', 4),
      ], discoveredAt: store.now + 5000);
      expect(store.rows().map((r) => r.track.id).toList(), before);
      store.merge(const [
        Track('3_4', 'New', 'Artist', 4),
      ], discoveredAt: store.now + 10000);
      expect(store.rows().first.track.id, '3_4');
    },
  );
  test('invalid metadata rolls the entire merge back', () {
    expect(
      () => store.merge(const [
        Track('1_4', 'Valid', 'Artist', 4),
        Track('invalid', 'Bad', 'Artist', 4),
      ]),
      throwsA(isA<ProofFailure>()),
    );
    expect(store.track('1_4'), isNull);
    expect(store.count, 3);
  });
  test('corrected Cyrillic metadata survives restart without changing identity, cache or organization', () {
    // Keep a generated recording's organization and validated cache independent of display text.
    final original = store.track('1_1')!;
    // Preserve its first-import timestamp when corrected source metadata is merged later.
    final imported = store.db
        .select("SELECT updated FROM tracks WHERE id='1_1'")
        .single['updated'];
    // Retain a Pile occurrence and listening record through the same identity.
    final pile = store.createPile('Generated');
    store.addToPile(pile, '1_1');
    store.pinTrack('1_1', true);
    store.startPlay('1_1');
    store.saveAsset(
      const CachedAudio('1_1', 'generated.mp3', 'generated', 100, 120),
    );
    store.mergeMetadata('1_1', {'album': 'Generated album'});
    // Model the damaged text already persisted by the old permissive decoder.
    final damaged = String.fromCharCodes([65533, 65533, 65533]);
    store.merge([Track('1_1', damaged, damaged, 120)]);
    // A correctly decoded fresh listing restores text using the same stable identity.
    store.merge([original], discoveredAt: store.now + 1000);
    store.close();
    store = LibraryStore(folder);
    expect(store.track('1_1')!.title, original.title);
    expect(store.track('1_1')!.artist, original.artist);
    expect(store.count, 3);
    expect(store.isPinned('1_1'), isTrue);
    expect(store.asset('1_1')!.bytes, 100);
    expect(store.metadata('1_1')['album'], 'Generated album');
    expect(store.rows(pile: pile).single.track.id, '1_1');
    expect(
      store.db.select('SELECT COUNT(*) AS n FROM plays').single['n'],
      1,
    );
    expect(
      store.db
          .select("SELECT updated FROM tracks WHERE id='1_1'")
          .single['updated'],
      imported,
    );
  });

  test('pins, settings and saved assets survive reopen without fixtures', () {
    store.pinTrack('1_2', true);
    store.setSetting('auto_sync', true);
    store.saveAsset(const CachedAudio('1_2', 'audio.mp3', 'hash', 123, 40));
    store.close();
    store = LibraryStore(folder);
    expect(store.setting('auto_sync'), isTrue);
    expect(store.isPinned('1_2'), isTrue);
    expect(store.asset('1_2')!.bytes, 123);
    expect(store.count, 3);
  });
}
