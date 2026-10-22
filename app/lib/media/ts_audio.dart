import 'dart:typed_data';

import 'audio_policy.dart';

class _AudioPackets {
  final bytes = BytesBuilder(copy: false);
  int? remaining;
  void append(Uint8List payload) {
    final count = remaining == null
        ? payload.length
        : payload.length.clamp(0, remaining!);
    bytes.add(Uint8List.sublistView(payload, 0, count));
    if (remaining != null) remaining = remaining! - count;
  }
}

// Extract only standard MPEG audio PES packets from one MPEG-TS audio PID.
// PAT/PMT/video/private metadata remain transport data; no codec is decoded here.
// Truncated PES data and multiple audio streams are rejected, never guessed.
Uint8List? mpegAudioFromTs(Uint8List stream) {
  if (stream.length % 188 != 0) {
    throw const ProofFailure('hls_ts_packet_invalid');
  }
  final tracks = <int, _AudioPackets>{};
  for (var offset = 0; offset < stream.length; offset += 188) {
    final packet = Uint8List.sublistView(stream, offset, offset + 188);
    if (packet[0] != 0x47 || packet[1] & 0x80 != 0 || packet[3] & 0xc0 != 0) {
      throw const ProofFailure('hls_ts_packet_invalid');
    }
    final pid = ((packet[1] & 31) << 8) | packet[2];
    final control = (packet[3] >> 4) & 3;
    if (control == 0) throw const ProofFailure('hls_ts_packet_invalid');
    if (control & 1 == 0) continue;
    var start = 4;
    if (control & 2 != 0) start += 1 + packet[4];
    if (start > 188) throw const ProofFailure('hls_ts_packet_invalid');
    if (start == 188) continue;
    final payload = Uint8List.sublistView(packet, start);
    if (packet[1] & 0x40 != 0) {
      final current = tracks[pid];
      if (current?.remaining != null && current!.remaining! > 0) {
        throw const ProofFailure('hls_ts_pes_incomplete');
      }
      final pes =
          payload.length >= 9 &&
          payload[0] == 0 &&
          payload[1] == 0 &&
          payload[2] == 1;
      if (!pes || payload[3] < 0xc0 || payload[3] > 0xdf) {
        if (current != null) throw const ProofFailure('hls_ts_audio_changed');
        continue;
      }
      if (payload[6] & 0xc0 != 0x80) {
        throw const ProofFailure('hls_ts_pes_unsupported');
      }
      final header = 9 + payload[8];
      final declared = (payload[4] << 8) | payload[5];
      if (header > payload.length || declared != 0 && declared < header - 6) {
        throw const ProofFailure('hls_ts_pes_unsupported');
      }
      final track = tracks.putIfAbsent(pid, _AudioPackets.new);
      if (tracks.length > 1) throw const ProofFailure('hls_ts_audio_ambiguous');
      track.remaining = declared == 0 ? null : declared - (header - 6);
      track.append(Uint8List.sublistView(payload, header));
    } else {
      tracks[pid]?.append(payload);
    }
  }
  if (tracks.isEmpty) return null;
  final audio = tracks.values.single;
  if (audio.remaining != null && audio.remaining! > 0) {
    throw const ProofFailure('hls_ts_pes_incomplete');
  }
  return audio.bytes.takeBytes();
}
