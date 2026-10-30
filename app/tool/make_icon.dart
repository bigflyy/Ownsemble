// Draws the app icon "Overlap" (picked in the B2 design) and writes it as
// the Windows icon file, one PNG image per size Windows asks for.
//
// The design, on a 64 x 64 grid: a rounded square (corner radius 14, color
// #1a1d25) with three circles of radius 12.5 in the source colors, blue
// (32, 23), orange (22.5, 39) and green (41.5, 39). Where circles overlap
// their colors are combined with "screen" (the colors light each other up),
// so the middle where all three meet is nearly white.
//
// Run from app/:
//   dart run tool/make_icon.dart [--out windows/runner/resources/app_icon.ico]
//       [--png-dir DIR]  (also writes each size as a PNG file, to look at)

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Sizes in pixels that Windows picks from for the taskbar, title bar,
/// Explorer views and shortcuts at the usual display scales.
const iconSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];

/// One color as 0..1 channels.
typedef Rgb = (double, double, double);

Rgb _hex(int value) => (
  ((value >> 16) & 0xff) / 255,
  ((value >> 8) & 0xff) / 255,
  (value & 0xff) / 255,
);

final _background = _hex(0x1a1d25);
final _circles = [
  (x: 32.0, y: 23.0, color: _hex(0x5b9bff)),
  (x: 22.5, y: 39.0, color: _hex(0xff8a5c)),
  (x: 41.5, y: 39.0, color: _hex(0x43c98f)),
];
const _circleRadius = 12.5;
const _cornerRadius = 14.0;

/// Whether the design point (x, y) on the 64 grid is inside the rounded
/// square.
bool _insideSquare(double x, double y) {
  if (x < 0 || y < 0 || x > 64 || y > 64) return false;
  // Distance into the nearest corner's quarter circle, if in a corner box.
  final cx = x < _cornerRadius
      ? _cornerRadius
      : (x > 64 - _cornerRadius ? 64 - _cornerRadius : x);
  final cy = y < _cornerRadius
      ? _cornerRadius
      : (y > 64 - _cornerRadius ? 64 - _cornerRadius : y);
  final dx = x - cx;
  final dy = y - cy;
  return dx * dx + dy * dy <= _cornerRadius * _cornerRadius;
}

/// Color of the design point (x, y), or null outside the icon.
Rgb? _colorAt(double x, double y) {
  if (!_insideSquare(x, y)) return null;
  // "Screen": 1 - (1 - a)(1 - b) per channel, over the circles that cover
  // the point. The circles blend only with each other (the design isolates
  // them), so a single circle shows its own color, not one mixed with the
  // dark square.
  var (r, g, b) = (1.0, 1.0, 1.0);
  var covered = false;
  for (final circle in _circles) {
    final dx = x - circle.x;
    final dy = y - circle.y;
    if (dx * dx + dy * dy > _circleRadius * _circleRadius) continue;
    covered = true;
    r *= 1 - circle.color.$1;
    g *= 1 - circle.color.$2;
    b *= 1 - circle.color.$3;
  }
  return covered ? (1 - r, 1 - g, 1 - b) : _background;
}

/// The icon drawn at [size] x [size] pixels as RGBA bytes. Each pixel
/// averages 16 x 16 samples so edges stay smooth at 16 px too.
Uint8List renderIcon(int size, {int samples = 16}) {
  final pixels = Uint8List(size * size * 4);
  final scale = 64 / size;
  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var (r, g, b, a) = (0.0, 0.0, 0.0, 0.0);
      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final color = _colorAt(
            (px + (sx + 0.5) / samples) * scale,
            (py + (sy + 0.5) / samples) * scale,
          );
          if (color == null) continue;
          // Summed premultiplied, so transparent samples add no color.
          r += color.$1;
          g += color.$2;
          b += color.$3;
          a += 1;
        }
      }
      final offset = (py * size + px) * 4;
      if (a > 0) {
        pixels[offset] = (r / a * 255).round();
        pixels[offset + 1] = (g / a * 255).round();
        pixels[offset + 2] = (b / a * 255).round();
      }
      pixels[offset + 3] = (a / (samples * samples) * 255).round();
    }
  }
  return pixels;
}

/// [rgba] ([size] x [size]) as a PNG file.
Uint8List encodePng(int size, Uint8List rgba) {
  final out = BytesBuilder();
  void chunk(String type, List<int> data) {
    final typed = [...type.codeUnits, ...data];
    out
      ..add(_uint32(data.length))
      ..add(typed)
      ..add(_uint32(_crc32(typed)));
  }

  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  // Width, height, 8 bits per channel, color type 6 (RGBA), deflate,
  // standard filters, no interlace.
  chunk('IHDR', [..._uint32(size), ..._uint32(size), 8, 6, 0, 0, 0]);
  // Every row starts with filter type 0 (none).
  final raw = BytesBuilder();
  for (var row = 0; row < size; row++) {
    raw
      ..addByte(0)
      ..add(Uint8List.sublistView(rgba, row * size * 4, (row + 1) * size * 4));
  }
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

/// An .ico file holding one PNG image per size (Windows Vista and later
/// read PNG images inside .ico files at every size).
Uint8List encodeIco(Map<int, Uint8List> pngBySize) {
  final out = BytesBuilder();
  final count = pngBySize.length;
  // Header: reserved 0, type 1 (icon), image count.
  out.add([..._uint16(0), ..._uint16(1), ..._uint16(count)]);
  var offset = 6 + 16 * count;
  for (final MapEntry(key: size, value: png) in pngBySize.entries) {
    // Width and height bytes; 0 means 256.
    out.add([size == 256 ? 0 : size, size == 256 ? 0 : size, 0, 0]);
    // Color planes 1, 32 bits per pixel, data size, data offset.
    out.add([
      ..._uint16(1),
      ..._uint16(32),
      ..._uint32le(png.length),
      ..._uint32le(offset),
    ]);
    offset += png.length;
  }
  for (final png in pngBySize.values) {
    out.add(png);
  }
  return out.takeBytes();
}

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _uint32le(int value) => _uint32(value).reversed.toList();

List<int> _uint16(int value) => [value & 0xff, (value >> 8) & 0xff];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// CRC-32 as PNG chunks need it.
int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}

void main(List<String> args) {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final out = valueOf('--out') ?? 'windows/runner/resources/app_icon.ico';
  final pngDir = valueOf('--png-dir');
  final pngBySize = <int, Uint8List>{};
  for (final size in iconSizes) {
    pngBySize[size] = encodePng(size, renderIcon(size));
    if (pngDir != null) {
      Directory(pngDir).createSync(recursive: true);
      File(p.join(pngDir, 'overlap-$size.png'))
          .writeAsBytesSync(pngBySize[size]!);
    }
  }
  final ico = encodeIco(pngBySize);
  File(out).writeAsBytesSync(ico);
  final total = pngBySize.values.fold(0, (sum, png) => sum + png.length);
  print(
    'Wrote $out: ${iconSizes.join(', ')} px, ${ico.length} bytes '
    '($total in images).',
  );
}
