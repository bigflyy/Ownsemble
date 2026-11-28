/// The still background of a karaoke video (plan 11): the song's cover
/// scaled to fill the frame, blurred and darkened so the lines stay easy to
/// read; a plain dark frame when there is no cover. Made once per export
/// with Flutter's painting (on the UI isolate) and written as a PNG that
/// ffmpeg loops under the lines.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'karaoke_script.dart';

/// The app's dark background colour (OwnColors.dark.bg), used when there is
/// no cover and under the darkened cover.
const _plain = ui.Color(0xFF0F1115);

/// How much of the cover shows through the dark layer (0..1), at most and
/// at least: a light cover is darkened more (see [_showThrough]).
const coverShowsThroughMax = 0.45;
const coverShowsThroughMin = 0.2;

/// How light the lighter parts of the darkened cover may be (0..1, the
/// lightness of the cover's 90th percentile after darkening), so the dim
/// lines stay readable on a white or grey cover too (session 66 clips: a
/// light grey cover at 0.45 left the dim lines grey on grey).
const _lightestAfter = 0.25;

/// The PNG background for [shape] made from [cover] (the cover file's
/// bytes, any format Flutter decodes: the stored `covers/<key>.jpg` may hold
/// a PNG or WebP), or a plain one when [cover] is null or cannot be
/// decoded.
Future<Uint8List> karaokeBackground(
  Uint8List? cover,
  KaraokeShape shape,
) async {
  final width = shape.width.toDouble(), height = shape.height.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width, height),
    ui.Paint()..color = _plain,
  );
  final image = cover == null ? null : await _decode(cover);
  if (image != null) {
    // Scale to fill the frame (crop the overflow), plus a margin of three
    // blur radii on every side, so the blur never pulls in the edge.
    final sigma = height / 24;
    final margin = sigma * 3;
    final scale = [
      (width + 2 * margin) / image.width,
      (height + 2 * margin) / image.height,
    ].reduce((a, b) => a > b ? a : b);
    final drawnW = image.width * scale, drawnH = image.height * scale;
    final target = ui.Rect.fromLTWH(
      (width - drawnW) / 2,
      (height - drawnH) / 2,
      drawnW,
      drawnH,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      target,
      ui.Paint()
        ..filterQuality = ui.FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: ui.TileMode.clamp,
        ),
    );
    final show = await _showThrough(image);
    image.dispose();
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = _plain.withValues(alpha: 1 - show),
    );
  }
  final picture = recorder.endRecording();
  final frame = await picture.toImage(shape.width, shape.height);
  picture.dispose();
  final png = await frame.toByteData(format: ui.ImageByteFormat.png);
  frame.dispose();
  return png!.buffer.asUint8List();
}

/// How much of [image] may show through the dark layer: the most that
/// keeps its lighter parts (90th percentile of lightness, measured on a
/// 24 x 24 copy) at [_lightestAfter], within the min and max.
Future<double> _showThrough(ui.Image image) async {
  const side = 24;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    const ui.Rect.fromLTWH(0, 0, side + 0.0, side + 0.0),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(side, side);
  picture.dispose();
  final pixels = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  if (pixels == null) return coverShowsThroughMax;
  final lightness = <double>[
    for (var i = 0; i + 3 < pixels.lengthInBytes; i += 4)
      (0.2126 * pixels.getUint8(i) +
              0.7152 * pixels.getUint8(i + 1) +
              0.0722 * pixels.getUint8(i + 2)) /
          255,
  ]..sort();
  final light = lightness[(lightness.length * 0.9).floor()];
  const plain = (0.2126 * 0x0F + 0.7152 * 0x11 + 0.0722 * 0x15) / 255;
  if (light <= _lightestAfter) return coverShowsThroughMax;
  return ((_lightestAfter - plain) / (light - plain)).clamp(
    coverShowsThroughMin,
    coverShowsThroughMax,
  );
}

/// [bytes] decoded, or null when they are not an image Flutter reads.
Future<ui.Image?> _decode(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } on Object {
    return null;
  }
}
