/// Text widths for breaking karaoke lines into rows (plan 11 C1), measured
/// with Flutter's own text layout so they match what libass draws in the
/// video: the same font (bold Segoe UI, found by DirectWrite on Windows)
/// at the same em size.
library;

import 'package:flutter/painting.dart';

import 'karaoke_script.dart';

/// A [TextWidth] that lays the text out with [TextPainter]. Widths are
/// remembered, since a song asks for the same lines at the same sizes
/// several times.
class KaraokeMeasure {
  /// [fontFamily] is [karaokeFont] in the app; a test or tool that loads
  /// the font file itself passes the name it registered.
  KaraokeMeasure({this.fontFamily = karaokeFont});

  final String fontFamily;
  final _widths = <(String, int), double>{};

  /// The width in video pixels of [text] at the ASS font size [size].
  double call(String text, int size) =>
      _widths[(text, size)] ??= _measure(text, size);

  double _measure(String text, int size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.bold,
          fontSize: size * segoeUiEmPerAssSize,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
