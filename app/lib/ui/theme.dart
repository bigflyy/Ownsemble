import 'package:flutter/material.dart';

/// The B2 design's colors ("Stage v2" board), as one theme extension so
/// every widget reads the same names the design uses.
///
/// Sources have their own colors (source 1 = VK, 2 and 3 for later sources);
/// violet is the library's own accent.
@immutable
class OwnColors extends ThemeExtension<OwnColors> {
  const OwnColors({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.dim,
    required this.dim2,
    required this.hover,
    required this.accent,
    required this.accentStrong,
    required this.accentBg,
    required this.onAccent,
    required this.source1,
    required this.source2,
    required this.source3,
    required this.source4,
    required this.source5,
    required this.source6,
    required this.shadow,
    required this.isDark,
  });

  static const dark = OwnColors(
    bg: Color(0xFF0F1115),
    surface: Color(0xFF161920),
    raised: Color(0xFF1D212A),
    line: Color(0xFF262B36),
    text: Color(0xFFECEEF3),
    dim: Color(0xFFA2A8B6),
    dim2: Color(0xFF868D9C),
    hover: Color(0xFF1B1F28),
    accent: Color(0xFFA594FF),
    accentStrong: Color(0xFFBCAFFF),
    accentBg: Color(0xFF221D3D),
    onAccent: Color(0xFF0F1115),
    source1: Color(0xFF5B9BFF),
    source2: Color(0xFFFF8A5C),
    source3: Color(0xFF43C98F),
    source4: Color(0xFFF2C14E),
    source5: Color(0xFFE56BB5),
    source6: Color(0xFF4FD0E0),
    shadow: Color(0x80000000),
    isDark: true,
  );

  static const light = OwnColors(
    bg: Color(0xFFF4F5F8),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFFFFFFF),
    line: Color(0xFFE0E4EB),
    text: Color(0xFF151821),
    dim: Color(0xFF525A69),
    dim2: Color(0xFF646B7A),
    hover: Color(0xFFECEFF4),
    accent: Color(0xFF5B45D6),
    accentStrong: Color(0xFF4632B8),
    accentBg: Color(0xFFECE9FD),
    onAccent: Color(0xFFFFFFFF),
    source1: Color(0xFF2A68D8),
    source2: Color(0xFFC94F22),
    source3: Color(0xFF16875A),
    source4: Color(0xFF9A7000),
    source5: Color(0xFFB83B8A),
    source6: Color(0xFF0F7F93),
    shadow: Color(0x29151821),
    isDark: false,
  );

  final Color bg;
  final Color surface;
  final Color raised;
  final Color line;
  final Color text;
  final Color dim;
  final Color dim2;
  final Color hover;
  final Color accent;
  final Color accentStrong;
  final Color accentBg;
  final Color onAccent;

  /// Source colors: 1 is VK; 2 and 3 are for sources added later.
  final Color source1;
  final Color source2;
  final Color source3;
  final Color source4;
  final Color source5;
  final Color source6;

  /// The color of slot [slot], from 1; see `SourceInfo.color`.
  Color sourceColor(int slot) => switch ((slot - 1) % 6) {
    0 => source1,
    1 => source2,
    2 => source3,
    3 => source4,
    4 => source5,
    _ => source6,
  };
  final Color shadow;
  final bool isDark;

  /// The accent for text on the current row: the stronger one in dark.
  Color get currentText => isDark ? accentStrong : accent;

  /// The colors of the current theme; outside the app's theme (widget
  /// tests) the built-in set matching its brightness.
  static OwnColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<OwnColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  OwnColors copyWith() => this;

  @override
  OwnColors lerp(OwnColors? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

/// The app's font. A `textStyle` given to a button or a theme replaces the
/// label style instead of adding to it, so it must name this family too, or
/// that text falls back to the system font.
const appFontFamily = 'Golos Text';

/// The app's theme for [colors]: Golos Text, the design's colors, and
/// Material widgets (sliders, menus, tooltips) dressed to match.
ThemeData buildTheme(OwnColors colors) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: colors.accent,
        brightness: colors.isDark ? Brightness.dark : Brightness.light,
      ).copyWith(
        primary: colors.accent,
        onPrimary: colors.onAccent,
        secondary: colors.accent,
        surface: colors.surface,
        onSurface: colors.text,
        outline: colors.line,
        outlineVariant: colors.line,
        error: colors.isDark
            ? const Color(0xFFFF7A7A)
            : const Color(0xFFC62828),
      );
  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: appFontFamily,
    scaffoldBackgroundColor: colors.bg,
    extensions: [colors],
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: colors.text,
      displayColor: colors.text,
    ),
    dividerColor: colors.line,
    iconTheme: IconThemeData(color: colors.dim, size: 20),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: colors.text,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(
        fontFamily: appFontFamily,
        color: colors.bg,
        fontSize: 12,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      textStyle: TextStyle(
        fontFamily: appFontFamily,
        color: colors.text,
        fontSize: 14,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 6,
      activeTrackColor: colors.accent,
      inactiveTrackColor: colors.line,
      // The saved part of a song on the seek bar.
      secondaryActiveTrackColor: colors.accent.withValues(alpha: 0.35),
      thumbColor: colors.text,
      overlayColor: colors.accent.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      trackShape: const RoundedRectSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.onDrag,
      valueIndicatorColor: colors.text,
      valueIndicatorTextStyle: TextStyle(color: colors.bg, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.text,
      contentTextStyle: TextStyle(color: colors.bg, fontSize: 14),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// A stand-in tile for a song without a cover: two initials on a color
/// derived from [name] (album, else artist), as in the design.
({Color bg, Color fg, String initials}) standInTile(
  String name, {
  required bool dark,
}) {
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) % 360;
  }
  final initials = name
      .split(RegExp(r'\s+'))
      .where(
        (w) => w.isNotEmpty && RegExp(r'[\p{L}]', unicode: true).hasMatch(w[0]),
      )
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();
  final hue = hash.toDouble();
  return dark
      ? (
          bg: HSLColor.fromAHSL(1, hue, 0.30, 0.24).toColor(),
          fg: HSLColor.fromAHSL(1, hue, 0.55, 0.80).toColor(),
          initials: initials,
        )
      : (
          bg: HSLColor.fromAHSL(1, hue, 0.45, 0.86).toColor(),
          fg: HSLColor.fromAHSL(1, hue, 0.45, 0.26).toColor(),
          initials: initials,
        );
}
