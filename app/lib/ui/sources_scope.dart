import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../library/library_store.dart';
import '../library/track.dart';
import 'theme.dart';

/// Gives the widgets below it the library's sources, for their names and
/// colors, and rebuilds them when a source changes.
class SourcesScope
    extends InheritedNotifier<ValueListenable<List<SourceInfo>>> {
  const SourcesScope({
    super.key,
    required ValueListenable<List<SourceInfo>> sources,
    required super.child,
  }) : super(notifier: sources);

  /// The sources; empty outside a scope, as in widget tests of single parts.
  static List<SourceInfo> of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SourcesScope>()
          ?.notifier
          ?.value ??
      const [];
}

SourceInfo? _sourceWithId(List<SourceInfo> sources, int id) =>
    sources.where((source) => source.id == id).firstOrNull;

/// The color of source [sourceId]. Generated songs have the third color, and a
/// source not known here the first one.
Color _colorOf(
  OwnColors colors,
  List<SourceInfo> sources,
  int sourceId,
  TrackSource kind,
) {
  if (kind == TrackSource.generated) return colors.source3;
  final source = _sourceWithId(sources, sourceId);
  return source == null ? colors.source1 : colors.sourceColor(source.color);
}

/// The color of [track]'s listed source.
Color sourceColor(BuildContext context, Track track) => _colorOf(
  OwnColors.of(context),
  SourcesScope.of(context),
  track.sourceId,
  track.source,
);

/// The colors of every account that has [track], its listed source first.
List<Color> sourceColors(BuildContext context, Track track) {
  final colors = OwnColors.of(context);
  final sources = SourcesScope.of(context);
  return [
    for (final copy in track.allCopies)
      _colorOf(colors, sources, copy.sourceId, track.source),
  ];
}

/// The names of the accounts that have [track], for showing where it is from.
String sourceNames(BuildContext context, Track track) {
  if (track.source == TrackSource.generated) return 'Generated';
  final sources = SourcesScope.of(context);
  return {
    for (final copy in track.allCopies)
      _sourceWithId(sources, copy.sourceId)?.name ?? 'VK',
  }.join(', ');
}
