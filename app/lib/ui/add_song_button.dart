/// The + of a found song and the check it turns into (plan 06, B3 and C3).
///
/// + takes the colour of the account it adds to, so the button already says
/// where the song goes; with several accounts ticked it is violet. Once the
/// song is in, a filled check in the colour of the account that has it,
/// violet with a dot per account when several have it. The change is the
/// quiet 0.3 s animation of board v4: the circle fades in, the check draws.
library;

import 'package:flutter/material.dart';

import 'catalog_search.dart';
import 'theme.dart';

class AddSongButton extends StatefulWidget {
  const AddSongButton({
    super.key,
    required this.state,
    required this.colors,
    required this.onAdd,
    this.addTip = 'Add to your library and VK',
    this.haveTip = 'In your library',
    this.large = false,
  });

  final FoundState state;

  /// For +: the colours of the accounts it adds to. For the check: the
  /// colours of the accounts that have the song.
  final List<Color> colors;

  final VoidCallback? onAdd;
  final String addTip;
  final String haveTip;

  /// The player's size (a standard 48 px button) instead of a row's 28 px.
  final bool large;

  @override
  State<AddSongButton> createState() => _AddSongButtonState();
}

class _AddSongButtonState extends State<AddSongButton>
    with SingleTickerProviderStateMixin {
  /// 0 to 1 while the check comes in; 1 when it stands.
  late final _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.state == FoundState.inLibrary ? 1 : 0,
  );

  @override
  void didUpdateWidget(AddSongButton old) {
    super.didUpdateWidget(old);
    if (widget.state == old.state) return;
    if (widget.state != FoundState.inLibrary) {
      _shown.value = 0;
    } else if (old.state == FoundState.adding &&
        !MediaQuery.of(context).disableAnimations) {
      _shown.forward(from: 0);
    } else {
      _shown.value = 1;
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final size = widget.large ? 48.0 : 28.0;
    final iconSize = widget.large ? 24.0 : 21.0;
    final one = widget.colors.length == 1 ? widget.colors.first : null;
    final color = one ?? colors.accent;
    if (widget.state != FoundState.inLibrary) {
      final adding = widget.state == FoundState.adding;
      return IconButton(
        key: const ValueKey('add-song'),
        tooltip: adding ? 'Adding...' : widget.addTip,
        onPressed: adding ? null : widget.onAdd,
        padding: EdgeInsets.zero,
        visualDensity: widget.large ? null : VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        iconSize: iconSize,
        // Waiting for VK's yes: the same +, faded, not a spinner.
        icon: Icon(
          Icons.add_circle_outline,
          color: adding ? color.withValues(alpha: 0.45) : color,
        ),
      );
    }
    final check = SizedBox(
      width: iconSize,
      height: iconSize,
      child: AnimatedBuilder(
        animation: _shown,
        builder: (context, _) => CustomPaint(
          painter: _CheckPainter(
            fill: color,
            mark: one == null ? colors.onAccent : _onColor(one),
            progress: _shown.value,
          ),
        ),
      ),
    );
    return Tooltip(
      message: widget.haveTip,
      child: SizedBox(
        key: const ValueKey('song-added'),
        width: size,
        height: size,
        child: Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              check,
              // A dot per account when several have the song, as a row in
              // two accounts shows its second one.
              if (one == null)
                Positioned(
                  right: -4,
                  bottom: -3,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final dot in widget.colors)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 1),
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.bg),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The check's colour on a fill of [fill]: white on a dark fill, the
  /// app's near black on a light one (the dark theme's account colours).
  Color _onColor(Color fill) =>
      fill.computeLuminance() > 0.35 ? const Color(0xFF0F1115) : Colors.white;
}

/// A filled circle with a check, drawn as far as [progress]: the circle
/// fades and grows in over the first 60 %, the check draws from a third on.
class _CheckPainter extends CustomPainter {
  _CheckPainter({
    required this.fill,
    required this.mark,
    required this.progress,
  });

  final Color fill;
  final Color mark;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on Material's 24-unit grid: circle r 10, check as on board v4.
    final unit = size.width / 24;
    final circle = Curves.easeOut.transform((progress / 0.6).clamp(0, 1));
    final stroke = Curves.easeOut.transform(
      ((progress - 1 / 3) / (2 / 3)).clamp(0, 1),
    );
    canvas.drawCircle(
      Offset(12 * unit, 12 * unit),
      10 * unit * (0.85 + 0.15 * circle),
      Paint()..color = fill.withValues(alpha: fill.a * circle),
    );
    if (stroke <= 0) return;
    final path = Path()
      ..moveTo(7.4 * unit, 12.4 * unit)
      ..lineTo(10.5 * unit, 15.5 * unit)
      ..lineTo(16.6 * unit, 8.9 * unit);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * stroke),
      Paint()
        ..color = mark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.3 * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.progress != progress || old.fill != fill || old.mark != mark;
}
