import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// "Artist  -  Album" as one line of text, the album a link that opens the
/// album. One line, so it takes no more height than the artist alone, and
/// the whole line shortens with an ellipsis when it does not fit.
class ArtistAlbumLine extends StatefulWidget {
  const ArtistAlbumLine({
    super.key,
    required this.artist,
    required this.album,
    required this.style,
    required this.albumStyle,
    this.onOpenAlbum,
  });

  final String artist;

  /// Empty for a song without an album: the artist alone.
  final String album;
  final TextStyle style;
  final TextStyle albumStyle;
  final VoidCallback? onOpenAlbum;

  @override
  State<ArtistAlbumLine> createState() => _ArtistAlbumLineState();
}

class _ArtistAlbumLineState extends State<ArtistAlbumLine> {
  final _tap = TapGestureRecognizer();
  var _hovered = false;

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpenAlbum;
    _tap.onTap = onOpen;
    final link = onOpen != null;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: widget.artist, style: widget.style),
          if (widget.album.isNotEmpty) ...[
            TextSpan(text: '  -  ', style: widget.albumStyle),
            TextSpan(
              text: widget.album,
              style: _hovered && link
                  ? widget.albumStyle.copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: widget.albumStyle.color,
                    )
                  : widget.albumStyle,
              recognizer: link ? _tap : null,
              mouseCursor: link ? SystemMouseCursors.click : null,
              onEnter: link ? (_) => setState(() => _hovered = true) : null,
              onExit: link ? (_) => setState(() => _hovered = false) : null,
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A song's album name that opens the album when clicked: the hand cursor
/// and an underline on hover say that it is a link. Without [onOpen] it is
/// plain text.
class AlbumLink extends StatefulWidget {
  const AlbumLink({
    super.key,
    required this.album,
    required this.style,
    this.onOpen,
    this.maxLines = 1,
  });

  final String album;
  final TextStyle style;
  final VoidCallback? onOpen;
  final int maxLines;

  @override
  State<AlbumLink> createState() => _AlbumLinkState();
}

class _AlbumLinkState extends State<AlbumLink> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpen;
    final text = Text(
      widget.album,
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
      style: _hovered && onOpen != null
          ? widget.style.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: widget.style.color,
            )
          : widget.style,
    );
    if (onOpen == null) return text;
    // Only the name itself is the link, not the empty rest of its column: a
    // click there still plays the row's song.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      heightFactor: 1,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: Tooltip(
            message: 'Open the album',
            waitDuration: const Duration(milliseconds: 600),
            child: text,
          ),
        ),
      ),
    );
  }
}
