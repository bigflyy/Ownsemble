import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:ownsemble_flutter_proof/audio_cache.dart';
import 'package:ownsemble_flutter_proof/proof_core.dart';
import 'package:ownsemble_flutter_proof/proof_player.dart';
import 'package:ownsemble_flutter_proof/proof_store.dart';
import 'package:ownsemble_flutter_proof/self_test.dart';

void main() {
  final library = File('build/windows/x64/runner/Debug/libmpv-2.dll');
  final skip = !Platform.isWindows || !library.existsSync();
  test(
    'native backend fully decodes and seeks generated encrypted AAC HLS',
    () async {
      MediaKit.ensureInitialized(libmpv: library.absolute.path);
      final path = File('assets/synthetic.m3u8').absolute.path;
      expect(await decodeLocalAudio(path), closeTo(4, 0.2));
      await checkLocalPlayer(path);
    },
    skip: skip,
  );

  test(
    'encrypted MP3 HLS normalizes into a strictly decoded seekable cache',
    () async {
      MediaKit.ensureInitialized(libmpv: library.absolute.path);
      final folder = await Directory.systemTemp.createTemp(
        'ownsemble-mp3-cache-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final name = request.uri.path.substring(1);
        if (!RegExp(r'^synthetic(?:-(?:ts-)?mp3)?(?:\.m3u8|\.key|-\d+\.ts)$')
            .hasMatch(name)) {
          request.response.statusCode = 404;
        } else {
          request.response.add(await File('assets/$name').readAsBytes());
        }
        await request.response.close();
      });
      try {
        final cache = AudioCache(
          folder,
          decodeLocalAudio,
          fixturePort: server.port,
        );
        for (final item in [
          ('synthetic', 'ts', '1_2'),
          ('synthetic-mp3', 'mp3', '1_3'),
          ('synthetic-ts-mp3', 'mp3', '1_4'),
        ]) {
          final asset = await cache.save(
            Track(item.$3, 'Synthetic', 'Tone', 4),
            Uri.parse('http://127.0.0.1:${server.port}/${item.$1}.m3u8'),
          );
          expect(asset.entry, endsWith('audio.${item.$2}'));
          expect(asset.duration, closeTo(4, 0.2));
          expect(await File(asset.entry).parent.list().length, 2);
          await cache.verify(asset);
          await checkLocalPlayer(asset.entry);
          if (item.$1 == 'synthetic-ts-mp3') {
            final store = ProofStore(Directory('${folder.path}/proof'));
            try {
              store.saveAsset(asset);
              store.merge(const [
                Track('1_4', 'Synthetic', 'Tone', 4),
                Track('1_5', 'Second', 'Tone', 4),
              ]);
              final checkpoint = File('${store.directory.path}/resume.json');
              // Reproduce the old successful checkpoint without a sample ID.
              await checkpoint.writeAsString('{"phase":"finished"}');
              await runOfflineProof(store);
              expect(jsonDecode(await checkpoint.readAsString())['id'], '1_4');
              // A second offline launch must verify the same complete cache.
              await runOfflineProof(store);
              expect(
                jsonDecode(
                  await File('${store.directory.path}/status.json')
                      .readAsString(),
                )['passed'],
                isTrue,
              );
            } finally {
              store.close();
            }
          }
        }
      } finally {
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
    skip: skip,
  );
}
