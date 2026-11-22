// Check for plan 10 G1: libmpv's decoding for the aligner
// (lib/lyrics/audio_decode.dart) against ffmpeg's, on one file.
//
//   dart run tool/compare_decode.dart AUDIO LIBMPV.dll OUT_DIR
//
// Writes OUT_DIR/mpv.f32 and OUT_DIR/ffmpeg.f32 (16 kHz mono float) for a
// closer look, and prints their lengths. Prints numbers only.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/lyrics/audio_decode.dart';

void main(List<String> args) {
  final audio = File(args[0]).absolute.path;
  final mpv = decodeForModel(args[1], audio, Directory.systemTemp.path);
  final ff = Process.runSync('ffmpeg', [
    '-v', 'error', '-i', audio, '-ac', '1', '-ar', '16000', //
    '-f', 'f32le', '-',
  ], stdoutEncoding: null);
  final ffBytes = Uint8List.fromList(ff.stdout as List<int>);
  File('${args[2]}/mpv.f32').writeAsBytesSync(
    mpv.buffer.asUint8List(mpv.offsetInBytes, mpv.lengthInBytes),
  );
  File('${args[2]}/ffmpeg.f32').writeAsBytesSync(ffBytes);
  print('mpv ${mpv.length} samples, ffmpeg ${ffBytes.length ~/ 4} samples');
}
