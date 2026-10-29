import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Retains demand only for a settled, painted cover, not ListView cache extent.
class ArtworkViewport extends StatefulWidget {
  final Object identity;
  final ValueChanged<Object> onVisible, onHidden;
  final Widget child;
  const ArtworkViewport({
    super.key,
    required this.identity,
    required this.onVisible,
    required this.onHidden,
    required this.child,
  });
  @override
  State<ArtworkViewport> createState() => _ArtworkViewportState();
}

class _ArtworkViewportState extends State<ArtworkViewport> {
  final _owner = Object();
  ScrollPosition? _position;
  Timer? _dwell;
  bool _active = false, _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _detach();
      _position = position;
      position?.addListener(_movement);
      position?.isScrollingNotifier.addListener(_movement);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(ArtworkViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _dwell?.cancel();
      _dwell = null;
      if (_active) oldWidget.onHidden(_owner);
      _active = false;
    }
    _schedule();
  }

  void _detach() {
    _position?.removeListener(_movement);
    _position?.isScrollingNotifier.removeListener(_movement);
  }

  void _movement() {
    _dwell?.cancel();
    _dwell = null;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _measure();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool get _visible {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return true;
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(viewport),
      Offset.zero & box.size,
    );
    return bounds.overlaps(viewport.paintBounds);
  }

  void _measure() {
    if (!_visible) {
      _dwell?.cancel();
      _dwell = null;
      if (_active) widget.onHidden(_owner);
      _active = false;
      return;
    }
    if (_active || _position?.isScrollingNotifier.value == true) return;
    _dwell ??= Timer(const Duration(milliseconds: 120), () {
      _dwell = null;
      if (!mounted ||
          !_visible ||
          _position?.isScrollingNotifier.value == true) {
        return;
      }
      _active = true;
      widget.onVisible(_owner);
    });
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _detach();
    if (_active) widget.onHidden(_owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
