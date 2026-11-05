// Synthetic MP3 files for tests: real frame headers, silent frames.

import 'dart:convert';

/// One MPEG-1 Layer III frame header at 320 kbit/s, 44.1 kHz, stereo: each
/// frame is 1044 bytes and plays 1152 samples.
const _header320 = [0xFF, 0xFB, 0xE0, 0x00];
const _frameBytes = 1044;
const frameSeconds = 1152 / 44100;

/// An ID3v2.3 tag with a UTF-16 title frame holding [title], padded with
/// [padding] zero bytes (a cover picture makes tags this long).
List<int> id3Tag(String title, {int padding = 0}) {
  final text = [0x01, 0xFF, 0xFE];
  for (final unit in title.codeUnits) {
    text
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  final frame = [
    ...ascii.encode('TIT2'),
    0, 0, (text.length >> 8) & 0xFF, text.length & 0xFF, // size
    0, 0, // flags
    ...text,
  ];
  final size = frame.length + padding;
  return [
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...frame,
    ...List.filled(padding, 0),
  ];
}

/// [count] CBR frames; the first is a LAME "Info" frame naming the count
/// when [infoCount] is given.
List<int> cbrFrames(int count, {int? infoCount}) {
  final bytes = <int>[];
  for (var i = 0; i < count; i++) {
    final frame = List<int>.filled(_frameBytes, 0)..setRange(0, 4, _header320);
    if (i == 0 && infoCount != null) {
      // After 4 header bytes and 32 bytes of stereo side information.
      frame.setRange(36, 40, ascii.encode('Info'));
      frame[43] = 1; // frame count present
      frame[44] = (infoCount >> 24) & 0xFF;
      frame[45] = (infoCount >> 16) & 0xFF;
      frame[46] = (infoCount >> 8) & 0xFF;
      frame[47] = infoCount & 0xFF;
    }
    bytes.addAll(frame);
  }
  return bytes;
}

/// A file that plays [seconds] at 320 kbit/s, as frames would add up.
List<int> songOf(double seconds, {List<int> tag = const []}) => [
  ...tag,
  ...cbrFrames((seconds / frameSeconds).round()),
];
