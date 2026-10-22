import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../media/audio_cache.dart';
import '../media/audio_policy.dart';
import '../media/hls_mp3.dart';
import '../media/local_audio.dart';

/// Generated metadata/tone, in a separate database. Never mixed with VK data.
Future<void> seedPreview(LibraryStore store) async {
  const titles = [
    'Light through the window',
    'Quiet orbit',
    'Отголоски',
    'A place to return',
    'Sunday, slowly',
    'After the rain',
    'Soft focus',
    'On the way home',
  ];
  const artists = [
    'The Paper Satellites',
    'Juniper Field',
    'Северный свет',
    'Low Tide Club',
    'Mira Lane',
    'The Paper Satellites',
    'Juniper Field',
    'Северный свет',
  ];
  if (store.count == 0) {
    store.merge(
      List.generate(
        1200,
        (i) => Track(
          '900000000000001_${i + 1}',
          i < 8 ? titles[i] : '${titles[i % 8]} · ${i + 1}',
          artists[i % 8],
          i < 3 ? 4.048 : 180 + (i % 120).toDouble(),
        ),
      ),
    );
    final pile = store.piles().first.id;
    store.addToPile(pile, '900000000000001_1');
    store.addToPile(pile, '900000000000001_2');
    store.addToPile(pile, '900000000000001_1');
    store.createPile('Late-night favourites');
    store.createPile('For the long way home');
  }
  store.db.execute('UPDATE tracks SET updated=1');
  store.merge(
    List.generate(
      3,
      (i) => Track('900000000000001_${i + 1}', titles[i], artists[i], 4.048),
    ),
    discoveredAt: 1,
  );
  final bytes = normalizeMp3Segment(
    (await rootBundle.load('assets/preview.mp3')).buffer.asUint8List(),
  );
  final source = File('${store.directory.path}/preview-source.mp3');
  await source.writeAsBytes(bytes);
  final digest = sha256.convert(bytes).toString();
  final cache = AudioCache(
    Directory('${store.directory.path}/audio'),
    decodeLocalAudio,
  );
  for (var i = 1; i <= 3; i++) {
    final id = '900000000000001_$i';
    if (store.asset(id) == null) {
      store.saveAsset(
        await cache.importLocal(store.track(id)!, source, digest),
      );
    }
  }
  await source.delete();
}
