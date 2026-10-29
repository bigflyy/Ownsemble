import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'proof_core.dart';
import 'ts_audio.dart';

bool _has(List<int> bytes, int offset, String marker) {
  if (offset < 0 || offset + marker.length > bytes.length) return false;
  for (var i = 0; i < marker.length; i++) {
    if (bytes[offset + i] != marker.codeUnitAt(i)) return false;
  }
  return true;
}

int _skipTags(Uint8List bytes, int offset) {
  while (_has(bytes, offset, 'ID3')) {
    if (offset + 10 > bytes.length || ![2, 3, 4].contains(bytes[offset + 3])) {
      throw const ProofFailure('hls_mp3_tag_invalid');
    }
    var size = 0;
    for (var i = offset + 6; i < offset + 10; i++) {
      if (bytes[i] >= 128) throw const ProofFailure('hls_mp3_tag_invalid');
      size = (size << 7) | bytes[i];
    }
    final footer = bytes[offset + 3] == 4 && (bytes[offset + 5] & 16) != 0;
    offset += 10 + size + (footer ? 10 : 0);
    if (offset > bytes.length || footer && !_has(bytes, offset - 10, '3DI')) {
      throw const ProofFailure('hls_mp3_tag_invalid');
    }
  }
  return offset;
}

bool _isMp3(Uint8List bytes, int offset) =>
    offset + 4 <= bytes.length &&
    bytes[offset] == 255 &&
    (bytes[offset + 1] & 224) == 224 &&
    ((bytes[offset + 1] >> 1) & 3) == 1 &&
    ((bytes[offset + 1] >> 3) & 3) != 1;

// Keep complete MPEG Layer III audio frames byte-for-byte. Standalone segment
// ID3 and Xing/Info/VBRI headers describe each segment, not the joined file.
// Reject malformed/truncated frames instead of scanning past damaged audio.
Uint8List normalizeMp3Segment(Uint8List bytes) {
  final output = BytesBuilder(copy: false);
  var offset = 0;
  while (offset < bytes.length) {
    offset = _skipTags(bytes, offset);
    if (offset == bytes.length) break;
    if (bytes.length - offset == 128 && _has(bytes, offset, 'TAG')) break;
    if (!_isMp3(bytes, offset)) {
      throw const ProofFailure('hls_mp3_frame_invalid');
    }
    final version = (bytes[offset + 1] >> 3) & 3;
    final bitrateIndex = bytes[offset + 2] >> 4;
    final rateIndex = (bytes[offset + 2] >> 2) & 3;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) {
      throw const ProofFailure('hls_mp3_frame_unsupported');
    }
    const mpeg1 = [
      0,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
    ];
    const mpeg2 = [
      0,
      8,
      16,
      24,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
    ];
    final bitrate = (version == 3 ? mpeg1 : mpeg2)[bitrateIndex];
    final rate =
        [44100, 48000, 32000][rateIndex] ~/
        (version == 3
            ? 1
            : version == 2
            ? 2
            : 4);
    final length =
        ((version == 3 ? 144000 : 72000) * bitrate ~/ rate) +
        ((bytes[offset + 2] >> 1) & 1);
    if (offset + length > bytes.length) {
      throw const ProofFailure('hls_mp3_frame_incomplete');
    }
    final mono = bytes[offset + 3] >> 6 == 3;
    final sideInfo = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final frame = Uint8List.sublistView(bytes, offset, offset + length);
    final marker = 4 + sideInfo;
    final crcMarker = marker + ((bytes[offset + 1] & 1) == 0 ? 2 : 0);
    final metadata =
        _has(frame, marker, 'Xing') ||
        _has(frame, marker, 'Info') ||
        _has(frame, crcMarker, 'Xing') ||
        _has(frame, crcMarker, 'Info') ||
        _has(frame, 36, 'VBRI');
    if (!metadata) output.add(frame);
    offset += length;
  }
  if (output.isEmpty) throw const ProofFailure('hls_mp3_no_frames');
  return output.takeBytes();
}

Uint8List _iv(BigInt sequence, String? explicit) {
  final value = explicit == null ? sequence : BigInt.parse(explicit, radix: 16);
  if (value.isNegative || value.bitLength > 128) {
    throw const ProofFailure('hls_iv_invalid');
  }
  return Uint8List.fromList(
    List.generate(
      16,
      (i) => ((value >> (8 * (15 - i))) & BigInt.from(255)).toInt(),
    ),
  );
}

// This receives only the app-generated LOCAL playlist after all approved CDN
// resources have been downloaded. It has no HTTP client or credential access.
Future<String?> materializeHlsAudio(
  Directory folder,
  List<String> playlist, {
  void Function(String)? onTransport,
}) async {
  if (playlist.any((line) => line.startsWith('#EXT-X-MAP:'))) {
    onTransport?.call('isobmff');
    return null;
  }
  final cipher = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
  SecretKey? key;
  String? explicitIv;
  var sequence = BigInt.zero;
  String? transport, entry;
  IOSink? sink;
  try {
    for (final line in playlist) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = BigInt.parse(line.substring(line.indexOf(':') + 1));
      } else if (line.startsWith('#EXT-X-KEY:')) {
        if (RegExp(r'(?:[:,])METHOD=NONE(?:,|$)').hasMatch(line)) {
          key = null;
          explicitIv = null;
          continue;
        }
        if (!RegExp(r'(?:[:,])METHOD=AES-128(?:,|$)').hasMatch(line)) {
          throw const ProofFailure('hls_encryption_unsupported');
        }
        final format = RegExp(r'KEYFORMAT="([^"]+)"')
            .firstMatch(line)
            ?.group(1);
        if (format != null && format != 'identity') {
          throw const ProofFailure('hls_encryption_unsupported');
        }
        final name = RegExp(r'URI="(part-\d+\.key)"')
            .firstMatch(line)
            ?.group(1);
        if (name == null) {
          throw const ProofFailure('hls_local_reference_invalid');
        }
        final bytes = await File('${folder.path}/$name').readAsBytes();
        if (bytes.length != 16) throw const ProofFailure('hls_key_invalid');
        key = SecretKey(bytes);
        final value = RegExp(r'(?:[:,])IV=([^,]+)').firstMatch(line)?.group(1);
        if (value != null &&
            !RegExp(r'^0x[0-9a-fA-F]{1,32}$').hasMatch(value)) {
          throw const ProofFailure('hls_iv_invalid');
        }
        explicitIv = value?.substring(2);
      } else if (!line.startsWith('#') && line.isNotEmpty) {
        if (!RegExp(r'^part-\d+\.ts$').hasMatch(line)) {
          throw const ProofFailure('hls_local_reference_invalid');
        }
        var bytes = await File('${folder.path}/$line').readAsBytes();
        if (key != null) {
          try {
            bytes = Uint8List.fromList(
              await cipher.decrypt(
                SecretBox(
                  bytes,
                  nonce: _iv(sequence, explicitIv),
                  mac: Mac.empty,
                ),
                secretKey: key,
              ),
            );
          } catch (_) {
            throw const ProofFailure('hls_decryption_failed');
          }
        }
        sequence += BigInt.one;
        final start = _skipTags(bytes, 0);
        final ts =
            bytes.length > start &&
            (bytes.length - start) % 188 == 0 &&
            Iterable<int>.generate((bytes.length - start) ~/ 188)
                .every((i) => bytes[start + i * 188] == 0x47);
        final kind = _isMp3(bytes, start)
            ? 'mp3'
            : ts
            ? 'mpegts'
            : 'unknown';
        if (transport == null) {
          onTransport?.call(kind);
          if (kind == 'unknown') return null;
          transport = kind;
          entry = kind == 'mp3' ? 'audio.mp3' : 'audio.ts';
        } else if (kind != transport) {
          throw const ProofFailure('hls_transport_changed');
        }
        sink ??= File('${folder.path}/$entry').openWrite();
        sink.add(
          transport == 'mp3'
              ? normalizeMp3Segment(bytes)
              : Uint8List.sublistView(bytes, start),
        );
      }
    }
    await sink?.close();
    sink = null;
    if (transport == 'mpegts') {
      final audio = mpegAudioFromTs(
        await File('${folder.path}/$entry').readAsBytes(),
      );
      if (audio != null && _isMp3(audio, _skipTags(audio, 0))) {
        final frames = normalizeMp3Segment(audio);
        await File('${folder.path}/audio.mp3')
            .writeAsBytes(frames, flush: true);
        onTransport?.call('mp3_in_ts');
        return 'audio.mp3';
      }
    }
    return entry;
  } finally {
    await sink?.close();
  }
}
