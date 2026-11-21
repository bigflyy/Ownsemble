/// The Artists place (plan 09, D1; design A picked by the user 2026-11-20):
/// every artist of the library as a round tile, its photo from VK or its
/// letters (a dashed ring: VK has no id for the name), its name and song
/// count; sort buttons Most songs / A-Z / Recently added / Most heard,
/// remembered; the search box filters the tiles by name. Photos are asked
/// of VK while the place is open, the visible tiles first, and fill in as
/// each batch lands.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/artist_index.dart';
import '../library/library_records.dart' show StoredArtistPhoto;
import '../library/track.dart';
import 'artists.dart';
import 'cover_tile.dart';
import 'cover_viewer.dart';
import 'for_you_page.dart' show PageMessage, songCountText;
import 'library_controller.dart';
import 'theme.dart';

/// The words of each sort button.
String artistSortLabel(ArtistSort sort) => switch (sort) {
  ArtistSort.mostSongs => 'Most songs',
  ArtistSort.name => 'A-Z',
  ArtistSort.recentlyAdded => 'Recently added',
  ArtistSort.mostHeard => 'Most heard',
};

/// "1 artist", "89 artists", or "3 of 89 artists" while a search filters.
String artistCountText(int shown, int all) {
  final noun = all == 1 ? '1 artist' : '$all artists';
  return shown == all ? noun : '$shown of $noun';
}

/// The round photo of an artist: VK's photo when one is stored, else its
/// letters on a color from its name; a dashed ring around a name-only
/// artist (VK has no id for it).
class ArtistPhoto extends StatelessWidget {
  const ArtistPhoto({
    super.key,
    required this.name,
    required this.size,
    this.photo,
    this.photoUrl,
    this.tint,
    this.nameOnly = false,
    this.opens = false,
  });

  final String name;
  final double size;

  /// The stored photo (small and large links).
  final StoredArtistPhoto? photo;

  /// A single photo link instead of [photo] (VK's similar artists).
  final String? photoUrl;
  final int? tint;
  final bool nameOnly;

  /// Whether a click opens the photo big, as a cover opens (the artist
  /// page's header; user, 2026-11-21: "i want to be able to" click it).
  final bool opens;

  /// VK's artist photos are at most 270 px: shown bigger than this they
  /// only blur.
  static const viewerSide = 480.0;

  @override
  Widget build(BuildContext context) {
    final small = photo?.small ?? photoUrl;
    final track = Track(
      id: 0,
      sourceId: 0,
      source: TrackSource.vk,
      artist: name,
      title: name,
      durationSec: 0,
      coverUrl: small,
      coverLargeUrl: photo?.large,
      tint: small == null ? null : tint,
    );
    Widget tile = TrackTile(track: track, size: size, radius: size / 2);
    if (opens && small != null) {
      tile = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Tooltip(
          message: 'Show the photo bigger',
          waitDuration: const Duration(milliseconds: 600),
          child: GestureDetector(
            key: const ValueKey('artist-photo-open'),
            onTap: () => showCoverViewer(
              context,
              track,
              // The whole square photo, not the round crop of the tiles.
              maxSide: viewerSide,
            ),
            child: tile,
          ),
        ),
      );
    }
    if (!nameOnly) return tile;
    final colors = OwnColors.of(context);
    return Tooltip(
      message:
          'VK names no artist for this text: its songs are grouped by '
          'the text alone',
      waitDuration: const Duration(milliseconds: 600),
      child: CustomPaint(
        foregroundPainter: _DashedRing(color: colors.dim2),
        child: tile,
      ),
    );
  }
}

class _DashedRing extends CustomPainter {
  _DashedRing({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final radius = size.shortestSide / 2 - 1;
    final center = size.center(Offset.zero);
    const dashes = 36;
    const sweep = 2 * math.pi / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        i * sweep,
        sweep * 0.55,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRing oldDelegate) => oldDelegate.color != color;
}

/// The sort buttons of the Artists place; one menu button when [compact].
class ArtistSortButtons extends StatelessWidget {
  const ArtistSortButtons({
    super.key,
    required this.artists,
    this.compact = false,
  });

  final LibraryArtists artists;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: artists,
      builder: (context, _) {
        final current = artists.sort;
        if (compact) {
          return PopupMenuButton<ArtistSort>(
            key: const ValueKey('artists-sort-menu'),
            tooltip: 'Sort the artists',
            initialValue: current,
            onSelected: (sort) => artists.sort = sort,
            itemBuilder: (context) => [
              for (final sort in ArtistSort.values)
                PopupMenuItem(
                  key: ValueKey('artists-sort-${sort.name}'),
                  value: sort,
                  child: Text(artistSortLabel(sort)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort, size: 18, color: colors.dim),
                  const SizedBox(width: 6),
                  Text(
                    artistSortLabel(current),
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final sort in ArtistSort.values) ...[
              const SizedBox(width: 6),
              _SortChip(
                key: ValueKey('artists-sort-${sort.name}'),
                label: artistSortLabel(sort),
                selected: sort == current,
                onPressed: () => artists.sort = sort,
                colors: colors,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.colors,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
      backgroundColor: selected ? colors.accentBg : null,
      foregroundColor: selected ? colors.accentStrong : colors.text,
      side: BorderSide(color: selected ? colors.accent : colors.line),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    ),
  );
}

/// The Artists place: the grid.
class ArtistsPage extends StatefulWidget {
  const ArtistsPage({super.key, required this.artists, required this.library});

  final LibraryArtists artists;
  final LibraryController library;

  /// The widest a tile's photo gets.
  static const photoSide = 132.0;

  /// The narrowest a tile gets: columns are added while each stays wider.
  static const minTileWidth = 150.0;

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final _scroll = ScrollController();

  /// The tiles laid out last: their order and the grid's measures, for
  /// telling which tiles are on screen.
  List<Artist> _shown = const [];
  int _columns = 1;
  double _rowExtent = 1;

  @override
  void initState() {
    super.initState();
    final clock = Stopwatch()..start();
    widget.artists.placeOpen(true);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.artists.log?.call(
        'artists place: first frame in ${clock.elapsedMilliseconds} ms, '
        '${widget.artists.index.length} artists',
      );
      _askPhotos();
    });
  }

  @override
  void dispose() {
    widget.artists.placeOpen(false);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() => _askPhotos();

  /// Photos for the tiles from the first one on screen, then the rest.
  void _askPhotos() {
    if (!mounted || _shown.isEmpty) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final firstRow = (offset / _rowExtent).floor();
    final first = (firstRow * _columns).clamp(0, _shown.length);
    widget.artists.wantPhotos([
      ..._shown.sublist(first),
      ..._shown.sublist(0, first),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final artists = widget.artists;
    return ListenableBuilder(
      listenable: Listenable.merge([artists, widget.library.searchText]),
      builder: (context, _) {
        final query = widget.library.searchText.text;
        final shown = artists.shown(query);
        if (artists.index.length == 0) {
          return PageMessage(
            'No artists yet. Your songs come here grouped by artist once the '
            'library has songs.',
            colors: colors,
          );
        }
        if (shown.isEmpty) {
          return PageMessage(
            'No artist matches "${query.trim()}"',
            colors: colors,
          );
        }
        final orderChanged = !identical(shown, _shown);
        _shown = shown;
        final heard = artists.sort == ArtistSort.mostHeard
            ? artists.plays?.call()
            : null;
        return LayoutBuilder(
          builder: (context, constraints) {
            const padding = 20.0;
            const spacing = 12.0;
            final width = constraints.maxWidth - 2 * padding;
            final columns = math.max(
              2,
              ((width + spacing) / (ArtistsPage.minTileWidth + spacing))
                  .floor(),
            );
            final tileWidth = (width - spacing * (columns - 1)) / columns;
            final photo = math.min(ArtistsPage.photoSide, tileWidth - 16);
            final extent = photo + 62;
            _columns = columns;
            _rowExtent = extent + spacing;
            if (orderChanged) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _askPhotos());
            }
            return Scrollbar(
              controller: _scroll,
              child: GridView.builder(
                key: const ValueKey('artists-grid'),
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(padding, 4, padding, 20),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: extent,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                ),
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final artist = shown[index];
                  final plays = heard == null
                      ? null
                      : artist.heard(heard).plays;
                  return _ArtistTile(
                    key: ValueKey('artist-${artist.key}'),
                    artist: artist,
                    photo: artists.photoOf(artist),
                    photoSide: photo,
                    line: [
                      songCountText(artist.songs.length),
                      if (plays != null) plays == 1 ? '1 play' : '$plays plays',
                    ].join(', '),
                    onOpen: () => widget.library.openArtist(artist.key),
                    colors: colors,
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _ArtistTile extends StatelessWidget {
  const _ArtistTile({
    super.key,
    required this.artist,
    required this.photo,
    required this.photoSide,
    required this.line,
    required this.onOpen,
    required this.colors,
  });

  final Artist artist;
  final StoredArtistPhoto? photo;
  final double photoSide;
  final String line;
  final VoidCallback onOpen;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    hoverColor: colors.hover,
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 4),
      child: Column(
        children: [
          ArtistPhoto(
            name: artist.name,
            size: photoSide,
            photo: photo,
            tint: artist.tint,
            nameOnly: artist.nameOnly,
          ),
          const SizedBox(height: 8),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.dim),
          ),
        ],
      ),
    ),
  );
}
