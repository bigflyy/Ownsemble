import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble_flutter_proof/proof_core.dart';
import 'package:ownsemble_flutter_proof/ts_audio.dart';

Uint8List packets(List<int> audio, [int pid = 256]) {
  final size = audio.length + 3;
  final pes = [0, 0, 1, 192, size >> 8, size & 255, 128, 0, 0, ...audio];
  final result = BytesBuilder();
  for (var offset = 0, counter = 0; offset < pes.length; counter++) {
    final count = (pes.length - offset).clamp(0, 184);
    final packet = Uint8List.fromList(List.filled(188, 255));
    packet[0] = 71;
    packet[1] = (pid >> 8) | (offset == 0 ? 64 : 0);
    packet[2] = pid & 255;
    packet[3] = (count == 184 ? 16 : 48) | (counter % 16);
    var start = 4;
    if (count < 184) {
      packet[4] = 183 - count;
      if (packet[4] > 0) packet[5] = 0;
      start = 188 - count;
    }
    packet.setRange(start, 188, pes.sublist(offset, offset + count));
    result.add(packet);
    offset += count;
  }
  return result.takeBytes();
}

void main() {
  test('TS PES extraction preserves payload across packets and removes only transport framing', () {
    final payload = List.generate(1000, (i) => i % 256);
    expect(mpegAudioFromTs(packets(payload)), payload);
  });
  test(
    'TS PES extraction rejects lost packets, truncated PES and ambiguous audio',
    () {
      final full = packets(List.filled(1000, 1));
      for (final broken in [
        full.sublist(0, full.length - 1),
        full.sublist(0, full.length - 188),
        [
          ...packets([1, 2, 3]),
          ...packets([4, 5, 6], 257),
        ],
      ]) {
        expect(
          () => mpegAudioFromTs(Uint8List.fromList(broken)),
          throwsA(isA<ProofFailure>()),
        );
      }
    },
  );
  test(
    'scrambled or transport-error packets are not accepted as complete audio',
    () {
      for (final mask in [0x80, 0x40]) {
        final broken = packets([1, 2, 3]);
        if (mask == 0x80) {
          broken[1] |= mask;
        } else {
          broken[3] |= mask;
        }
        expect(() => mpegAudioFromTs(broken), throwsA(isA<ProofFailure>()));
      }
    },
  );
}
