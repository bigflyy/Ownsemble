import 'package:flutter/material.dart';

import 'theme.dart';

/// Tells the widgets inside a song row whether the mouse is over the row,
/// so the row's heart can show its outline only then (plan 05). Only those
/// widgets rebuild when the mouse comes and goes, not the whole row.
class RowHoverScope extends StatefulWidget {
  const RowHoverScope({super.key, required this.child});

  final Widget child;

  /// Whether the mouse is over the row around [context]; false outside a
  /// row.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_RowHover>()
          ?.notifier
          ?.value ??
      false;

  @override
  State<RowHoverScope> createState() => _RowHoverScopeState();
}

class _RowHoverScopeState extends State<RowHoverScope> {
  final _hovered = ValueNotifier(false);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _hovered.value = true,
    onExit: (_) => _hovered.value = false,
    child: _RowHover(notifier: _hovered, child: widget.child),
  );
}

class _RowHover extends InheritedNotifier<ValueNotifier<bool>> {
  const _RowHover({required super.notifier, required super.child});
}

/// The heart on a song row: filled for a favorite; for any other song an
/// outline while the mouse is over the row, as in other players.
class RowHeart extends StatelessWidget {
  const RowHeart({super.key, required this.favorite, required this.onPressed});

  final bool favorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!favorite && !RowHoverScope.of(context)) return const SizedBox();
    return FavoriteHeart(favorite: favorite, onPressed: onPressed, small: true);
  }
}

/// A heart button that makes a song a favorite or no longer one. In the
/// player it is a standard button, as big as the buttons beside it; on a
/// row ([small]) it is a small one that fits the row's slot.
class FavoriteHeart extends StatelessWidget {
  const FavoriteHeart({
    super.key,
    required this.favorite,
    required this.onPressed,
    this.small = false,
  });

  final bool favorite;
  final VoidCallback onPressed;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final icon = Icon(
      favorite ? Icons.favorite : Icons.favorite_border,
      color: favorite ? colors.accent : colors.dim,
    );
    final tooltip = favorite ? 'Remove from Favorites' : 'Add to Favorites';
    if (!small) {
      return IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      iconSize: 18,
      icon: icon,
    );
  }
}
