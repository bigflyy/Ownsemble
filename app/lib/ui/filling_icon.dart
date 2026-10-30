import 'package:flutter/material.dart';

import '../library/track.dart';
import '../storage/audio_storage.dart';

/// An icon that fills up from the bottom while [track] is being saved, so the
/// icon itself is the progress: [icon] drawn faint, with [filled] on top of
/// it, cut at the share of the song saved so far.
class FillingIcon extends StatelessWidget {
  const FillingIcon({
    super.key,
    required this.storage,
    required this.track,
    required this.icon,
    required this.filled,
    required this.size,
    required this.color,
  });

  final AudioStorage storage;
  final Track track;
  final IconData icon;
  final IconData filled;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: storage.progress,
      builder: (context, _) => Stack(
        children: [
          Icon(icon, size: size, color: color.withValues(alpha: 0.4)),
          ClipRect(
            clipper: _BottomPart(storage.savedShare(track)),
            child: Icon(filled, size: size, color: color),
          ),
        ],
      ),
    );
  }
}

/// Keeps the bottom [share] (0 to 1) of what it clips.
class _BottomPart extends CustomClipper<Rect> {
  const _BottomPart(this.share);

  final double share;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, size.height * (1 - share), size.width, size.height);

  @override
  bool shouldReclip(_BottomPart oldClipper) => oldClipper.share != share;
}
