import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../library/track.dart';
import '../storage/cover_store.dart';
import 'theme.dart';

/// Gives the tiles below it their [CoverStore]. Tiles without one show only
/// stand-ins.
class CoverScope extends InheritedWidget {
  const CoverScope({super.key, required this.store, required super.child});

  final CoverStore store;

  /// Reads the store without depending on the scope: it never changes.
  static CoverStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CoverScope>()?.store;

  @override
  bool updateShouldNotify(CoverScope oldWidget) => store != oldWidget.store;
}

/// A cover file decoded for one size on screen, so the image cache holds
/// row-sized bitmaps and not the full image. Its own key is ready at once,
/// which lets a tile ask the cache whether the bitmap is there already.
@immutable
class CoverFileImage extends ImageProvider<CoverFileImage> {
  const CoverFileImage(this.path, this.pixels);

  /// How many covers were decoded in this run, for the speed bench.
  static int decodeCount = 0;

  final String path;

  /// Length of the image's shorter side after decoding, in device pixels.
  final int pixels;

  @override
  Future<CoverFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CoverFileImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_decode(decode));

  Future<ImageInfo> _decode(ImageDecoderCallback decode) async {
    decodeCount++;
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final codec = await decode(
      buffer,
      getTargetSize: (width, height) {
        final shorter = width < height ? width : height;
        // Decoding never enlarges: a small cover is shown as it is.
        if (shorter <= pixels) return const ui.TargetImageSize();
        return ui.TargetImageSize(
          width: (width * pixels / shorter).round(),
          height: (height * pixels / shorter).round(),
        );
      },
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is CoverFileImage && other.path == path && other.pixels == pixels;

  @override
  int get hashCode => Object.hash(path, pixels);
}

/// A song's tile: its cover when it has one, else the design's stand-in tile
/// from the album name or the artist.
///
/// The large cover is used only where a tile is bigger than the small one
/// (the Now playing panel); until it comes, the small cover stands in for it.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.size,
    required this.radius,
  });

  /// Side of VK's small cover, in pixels.
  static const smallCoverPixels = 135;

  final Track track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final standIn = _StandIn(track: track, size: size, radius: radius);
    final covers = CoverScope.maybeOf(context);
    final smallLinks = track.smallCovers;
    if (covers == null || smallLinks.isEmpty) return standIn;

    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final tint = track.tint;
    // While a cover loads its main color shows, not initials that flash by.
    final Widget loading = tint == null
        ? standIn
        : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Color(tint),
              borderRadius: BorderRadius.circular(radius),
            ),
          );
    Widget tile = _Cover(
      covers: covers,
      urls: smallLinks,
      pixels: pixels,
      size: size,
      radius: radius,
      loading: loading,
      failed: standIn,
    );
    final largeLinks = track.largeCovers;
    if (largeLinks.isNotEmpty && pixels > smallCoverPixels) {
      tile = _Cover(
        covers: covers,
        urls: largeLinks,
        pixels: pixels,
        size: size,
        radius: radius,
        loading: tile,
        failed: tile,
      );
    }
    return tile;
  }
}

/// The design's tile: a color from the name, with two initials.
class _StandIn extends StatelessWidget {
  const _StandIn({
    required this.track,
    required this.size,
    required this.radius,
  });

  final Track track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final name = (track.album?.trim().isNotEmpty ?? false)
        ? track.album!
        : track.artist;
    final tile = standInTile(name, dark: colors.isDark);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tile.bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        tile.initials,
        style: TextStyle(
          color: tile.fg,
          fontSize: size * 0.3,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One cover image that loads itself from disk or the network, from the
/// first of [urls] that is stored, else the first that VK serves.
///
/// It waits [settleDelay] before doing any work, so a row that scrolls past
/// costs nothing: no download, no file read, no decode. A bitmap already in
/// the image cache shows at once.
class _Cover extends StatefulWidget {
  const _Cover({
    required this.covers,
    required this.urls,
    required this.pixels,
    required this.size,
    required this.radius,
    required this.loading,
    required this.failed,
  });

  /// About as long as a row stays near the screen in a very fast scroll.
  static const settleDelay = Duration(milliseconds: 80);

  final CoverStore covers;

  /// Links of the same image, best first; not empty.
  final List<String> urls;
  final int pixels;
  final double size;
  final double radius;
  final Widget loading;
  final Widget failed;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  CoverFileImage? _image;
  bool _failed = false;
  Timer? _settle;
  CoverRequest? _request;

  /// Index in the links of the next one to ask for.
  int _nextLink = 0;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(_Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A list reuses its rows for other songs when the search text changes.
    if (!listEquals(oldWidget.urls, widget.urls) ||
        oldWidget.pixels != widget.pixels) {
      _stop();
      _image = null;
      _failed = false;
      _begin();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _settle?.cancel();
    _settle = null;
    _request?.cancel();
    _request = null;
  }

  /// The file of the first link that is on disk.
  String? _storedPath() {
    for (final url in widget.urls) {
      final path = widget.covers.storedPath(url);
      if (path != null) return path;
    }
    return null;
  }

  void _begin() {
    final path = _storedPath();
    if (path != null) {
      final image = CoverFileImage(path, widget.pixels);
      if (PaintingBinding.instance.imageCache.containsKey(image)) {
        _image = image;
        return;
      }
    }
    _settle = Timer(_Cover.settleDelay, _load);
  }

  void _load() {
    final path = _storedPath();
    if (path != null) {
      setState(() => _image = CoverFileImage(path, widget.pixels));
    } else {
      _nextLink = 0;
      _fetchNext();
    }
  }

  /// Asks for the next link that may work; with none left, gives up.
  void _fetchNext() {
    while (_nextLink < widget.urls.length) {
      final url = widget.urls[_nextLink++];
      if (!widget.covers.isUnavailable(url)) {
        _request = widget.covers.fetch(url, _onFetched);
        return;
      }
    }
    setState(() => _failed = true);
  }

  void _onFetched(String? path) {
    _request = null;
    if (!mounted) return;
    if (path == null) {
      _fetchNext();
    } else {
      setState(() => _image = CoverFileImage(path, widget.pixels));
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_failed) return widget.failed;
    if (image == null) return widget.loading;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Image(
        image: image,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        excludeFromSemantics: true,
        frameBuilder: (_, child, frame, _) =>
            frame == null ? widget.loading : child,
        errorBuilder: (_, _, _) => widget.failed,
      ),
    );
  }
}
