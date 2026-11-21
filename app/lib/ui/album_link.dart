import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../library/track.dart';
import 'artist_links.dart';

/// "Artist  -  Album" as one line of text, the album a link that opens the
/// album. One line, so it takes no more height than the artist alone, and
/// the whole line shortens with an ellipsis when it does not fit.
///
/// With [track] under an [ArtistLinkScope], each artist name is a link to
/// the artist's page too (plan 09, D3). An empty [album] leaves the artist
/// alone: a song row's artist line.
class ArtistAlbumLine extends StatefulWidget {
  const ArtistAlbumLine({
    super.key,
    required this.artist,
    required this.album,
    required this.style,
    required this.albumStyle,
    this.onOpenAlbum,
    this.whole = false,
    this.track,
  });

  /// The artist text shown; when it starts with [track]'s artist text, the
  /// rest (a note such as the filler's) stays plain.
  final String artist;

  /// The whole line without an ellipsis, for a line that scrolls.
  final bool whole;

  /// Empty for a song without an album: the artist alone.
  final String album;
  final TextStyle style;
  final TextStyle albumStyle;
  final VoidCallback? onOpenAlbum;

  /// The song whose artists the names link to; null: plain names.
  final Track? track;

  @override
  State<ArtistAlbumLine> createState() => _ArtistAlbumLineState();
}

class _ArtistAlbumLineState extends State<ArtistAlbumLine> {
  final _tap = TapGestureRecognizer();
  var _hovered = false;

  /// One recognizer per artist link, reused while the line stays.
  final _artistTaps = <TapGestureRecognizer>[];

  /// The artist link under the mouse, by its place among the links.
  int? _hoveredArtist;

  @override
  void dispose() {
    _tap.dispose();
    for (final tap in _artistTaps) {
      tap.dispose();
    }
    super.dispose();
  }

  TextStyle _underlined(TextStyle style) => style.copyWith(
    decoration: TextDecoration.underline,
    decorationColor: style.color,
  );

  /// The artist part of the line: plain text, or a span per piece with the
  /// names as links.
  List<InlineSpan> _artistSpans(BuildContext context) {
    final track = widget.track;
    final scope = track == null ? null : ArtistLinkScope.maybeOf(context);
    if (track == null || scope == null) {
      return [TextSpan(text: widget.artist, style: widget.style)];
    }
    final parts = [...scope.partsOf(track)];
    if (widget.artist != track.artist &&
        widget.artist.startsWith(track.artist)) {
      parts.add((
        text: widget.artist.substring(track.artist.length),
        key: null,
      ));
    } else if (widget.artist != track.artist) {
      return [TextSpan(text: widget.artist, style: widget.style)];
    }
    final spans = <InlineSpan>[];
    var link = 0;
    for (final part in parts) {
      final key = part.key;
      if (key == null) {
        spans.add(TextSpan(text: part.text, style: widget.style));
        continue;
      }
      if (_artistTaps.length <= link) _artistTaps.add(TapGestureRecognizer());
      final at = link++;
      _artistTaps[at].onTap = () => scope.open(key);
      spans.add(
        TextSpan(
          text: part.text,
          style: _hoveredArtist == at
              ? _underlined(widget.style)
              : widget.style,
          recognizer: _artistTaps[at],
          mouseCursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoveredArtist = at),
          onExit: (_) {
            if (_hoveredArtist == at) setState(() => _hoveredArtist = null);
          },
        ),
      );
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpenAlbum;
    _tap.onTap = onOpen;
    final link = onOpen != null;
    return Text.rich(
      TextSpan(
        children: [
          ..._artistSpans(context),
          if (widget.album.isNotEmpty) ...[
            TextSpan(text: '  -  ', style: widget.albumStyle),
            TextSpan(
              text: widget.album,
              style: _hovered && link
                  ? _underlined(widget.albumStyle)
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
      softWrap: !widget.whole,
      overflow: widget.whole ? TextOverflow.visible : TextOverflow.ellipsis,
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
