import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Tells an [IntrinsicWidth] above it that [child] needs at most [cap]
/// pixels, while laying the child out at whatever width it is given. The
/// bottom bar uses it so the song's block takes the title's width and a
/// longer artist line is cut there instead of widening the block.
class CapIntrinsicWidth extends SingleChildRenderObjectWidget {
  const CapIntrinsicWidth({super.key, required this.cap, super.child});

  final double cap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCapIntrinsicWidth(cap);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCapIntrinsicWidth renderObject,
  ) => renderObject.cap = cap;
}

class RenderCapIntrinsicWidth extends RenderProxyBox {
  RenderCapIntrinsicWidth(this._cap);

  double _cap;
  set cap(double value) {
    if (value == _cap) return;
    _cap = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.min(super.computeMinIntrinsicWidth(height), _cap);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.min(super.computeMaxIntrinsicWidth(height), _cap);
}

/// One line of text that ends with "..." when it does not fit and, while
/// the mouse is over it, scrolls slowly to show the rest (Spotify's way;
/// the user picked it 2026-11-08). Nothing moves while the mouse is
/// elsewhere, so an idle window draws no frames for it.
///
/// [builder] builds the line: cut with an ellipsis when `whole` is false,
/// the whole text on one line (no wrap, no ellipsis) when it is true.
class HoverMarquee extends StatefulWidget {
  const HoverMarquee({super.key, required this.builder});

  final Widget Function(BuildContext context, bool whole) builder;

  /// How fast the line moves, in pixels per second.
  static const speed = 40.0;

  @override
  State<HoverMarquee> createState() => _HoverMarqueeState();
}

class _HoverMarqueeState extends State<HoverMarquee> {
  final _scroll = ScrollController();
  var _whole = false;

  /// Counts mouse visits; a scrolling loop stops when it is no longer the
  /// visit that started it.
  var _visit = 0;

  @override
  void dispose() {
    _visit++;
    _scroll.dispose();
    super.dispose();
  }

  /// Whether a text inside was cut with its ellipsis.
  bool _isCut() {
    var cut = false;
    void visit(RenderObject object) {
      if (object is RenderParagraph && object.didExceedMaxLines) {
        cut = true;
      } else {
        object.visitChildren(visit);
      }
    }

    final root = context.findRenderObject();
    if (root != null) visit(root);
    return cut;
  }

  void _enter(PointerEnterEvent event) {
    if (_whole || !_isCut()) return;
    setState(() => _whole = true);
    _loop(++_visit);
  }

  void _exit(PointerExitEvent event) {
    _visit++;
    if (_whole) setState(() => _whole = false);
  }

  /// Scrolls to the end, rests, comes back, rests, again, while the mouse
  /// stays.
  Future<void> _loop(int visit) async {
    bool stays() => mounted && visit == _visit && _scroll.hasClients;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    while (stays()) {
      final extent = _scroll.position.maxScrollExtent;
      if (extent <= 0) return;
      await _scroll.animateTo(
        extent,
        duration: Duration(
          milliseconds: (extent / HoverMarquee.speed * 1000).round(),
        ),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!stays()) return;
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: _enter,
    onExit: _exit,
    child: _whole
        ? SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: widget.builder(context, true),
          )
        : widget.builder(context, false),
  );
}
