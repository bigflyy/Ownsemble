import 'package:flutter/foundation.dart';

import 'library_controller.dart' show LibraryView;

/// Somewhere the song list has been: its view, search text and scroll offset.
@immutable
class Place {
  const Place({required this.view, required this.search, this.scroll = 0});

  final LibraryView view;
  final String search;
  final double scroll;

  @override
  bool operator ==(Object other) =>
      other is Place &&
      other.view == view &&
      other.search == search &&
      other.scroll == scroll;

  @override
  int get hashCode => Object.hash(view, search, scroll);
}

/// The previous and next places, like a browser's back and forward. Kept in
/// memory only: a new run starts with none.
class PlaceHistory {
  /// Places kept behind the current one; older ones are forgotten.
  static const limit = 50;

  final _back = <Place>[];
  final _forward = <Place>[];

  /// Remembers [place] as the one being left for a new place. The places
  /// ahead no longer lead anywhere, so they go.
  void leave(Place place) {
    _forward.clear();
    if (_back.isNotEmpty && _back.last == place) return;
    _back.add(place);
    if (_back.length > limit) _back.removeAt(0);
  }

  /// The place before [here], which then lies ahead; null at the oldest.
  Place? back(Place here) => _step(from: _back, to: _forward, here: here);

  /// The place after [here], which then lies behind; null at the newest.
  Place? forward(Place here) => _step(from: _forward, to: _back, here: here);

  Place? _step({
    required List<Place> from,
    required List<Place> to,
    required Place here,
  }) {
    if (from.isEmpty) return null;
    to.add(here);
    return from.removeLast();
  }
}
