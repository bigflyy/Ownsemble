import 'package:flutter/material.dart';

import 'theme.dart';

/// Opens [builder]'s panel under the widget of [anchor] (above it when
/// there is more room there), like a menu: a click outside or Escape closes
/// it. Resolves to what the panel pops with.
Future<T?> showAnchoredPanel<T>(
  BuildContext anchor, {
  required WidgetBuilder builder,
  double width = 300,
  bool alignRight = false,
}) {
  final navigator = Navigator.of(anchor);
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final rect = Rect.fromPoints(
    box.localToGlobal(Offset.zero, ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  return navigator.push(
    _AnchoredRoute<T>(
      anchor: rect,
      builder: builder,
      width: width,
      alignRight: alignRight,
    ),
  );
}

class _AnchoredRoute<T> extends PopupRoute<T> {
  _AnchoredRoute({
    required this.anchor,
    required this.builder,
    required this.width,
    required this.alignRight,
  });

  final Rect anchor;
  final WidgetBuilder builder;
  final double width;
  final bool alignRight;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 90);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final colors = OwnColors.of(context);
    return CustomSingleChildLayout(
      delegate: _AnchoredLayout(anchor, width: width, alignRight: alignRight),
      child: Material(
        color: colors.raised,
        elevation: 8,
        shadowColor: colors.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Builder(builder: builder),
      ),
    );
  }
}

class _AnchoredLayout extends SingleChildLayoutDelegate {
  _AnchoredLayout(this.anchor, {required this.width, required this.alignRight});

  final Rect anchor;
  final double width;
  final bool alignRight;

  static const _gap = 6.0;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final below = constraints.maxHeight - anchor.bottom - _gap - _margin;
    final above = anchor.top - _gap - _margin;
    final height = below >= 280 || below >= above ? below : above;
    return BoxConstraints(
      maxWidth: (constraints.maxWidth - 2 * _margin).clamp(0, width),
      maxHeight: height.clamp(0, constraints.maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (alignRight ? anchor.right - child.width : anchor.left).clamp(
      _margin,
      (size.width - child.width - _margin).clamp(_margin, double.infinity),
    );
    final fitsBelow = anchor.bottom + _gap + child.height <= size.height;
    final y = fitsBelow || anchor.top - _gap - child.height < 0
        ? anchor.bottom + _gap
        : anchor.top - _gap - child.height;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AnchoredLayout old) =>
      old.anchor != anchor ||
      old.width != width ||
      old.alignRight != alignRight;
}
