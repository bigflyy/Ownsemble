import 'package:flutter/material.dart';

import '../library/track.dart';
import 'cover_tile.dart';

/// Shows a song's cover as big as the window allows, over everything else.
/// Esc or a click anywhere closes it; the song goes on playing behind it.
Future<void> showCoverViewer(BuildContext context, Track track) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close the cover',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (context, _, _) => GestureDetector(
        key: const ValueKey('cover-viewer'),
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              child: TrackTile(
                track: track,
                size: constraints.biggest.shortestSide,
                radius: 12,
                biggest: true,
              ),
            ),
          ),
        ),
      ),
    );

/// A player's tile: a click opens the song's cover. A song without a cover
/// has only a stand-in, so there is nothing to open.
class OpensCover extends StatelessWidget {
  const OpensCover({super.key, required this.track, required this.child});

  final Track track;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!track.hasCover) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const ValueKey('open-cover'),
        onTap: () => showCoverViewer(context, track),
        child: child,
      ),
    );
  }
}
