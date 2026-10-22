import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:ownsemble/media/hls_mp3.dart';

// Reproduce the generated preview asset from the checked-in synthetic probe
// fixtures. No account media is read and encoded audio is not re-encoded.
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent.parent;
  final fixtures = Directory('${root.path}/spikes/vk-flutter/assets');
  final key = SecretKey(
    await File('${fixtures.path}/synthetic-mp3.key').readAsBytes(),
  );
  final aes = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
  final output = BytesBuilder(copy: false);
  final transport = BytesBuilder(copy: false);
  for (var i = 0; i < 5; i++) {
    final bytes = await File(
      '${fixtures.path}/synthetic-mp3-${i.toString().padLeft(3, '0')}.ts',
    ).readAsBytes();
    final plain = await aes.decrypt(
      SecretBox(bytes, nonce: List.filled(16, 0), mac: Mac.empty),
      secretKey: key,
    );
    output.add(normalizeMp3Segment(Uint8List.fromList(plain)));
    final tsBytes = await File(
      '${fixtures.path}/synthetic-ts-mp3-${i.toString().padLeft(3, '0')}.ts',
    ).readAsBytes();
    transport.add(
      await aes.decrypt(
        SecretBox(tsBytes, nonce: List.filled(16, 0), mac: Mac.empty),
        secretKey: key,
      ),
    );
  }
  await File('${root.path}/app/assets/preview.mp3')
      .writeAsBytes(output.takeBytes());
  await File('${root.path}/app/assets/preview.ts')
      .writeAsBytes(transport.takeBytes());
}
