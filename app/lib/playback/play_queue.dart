import 'dart:math';

import '../library/track.dart';

/// Repeat modes, in the order the repeat button cycles through them.
enum Repeat {
  /// Stop after the last song of the list.
  off,

  /// Start the list again after its last song.
  list,

  /// Play the current song again when it ends.
  one,
}

/// The list a song was started from and the way through it.
///
/// Clicking a song makes the list it is in (as shown at that moment) the
/// play context; next and previous move within that snapshot, so searching
/// or a sync changing the visible list does not change what plays next.
/// With shuffle on, the context is walked in a random order that plays every
/// song once before any repeats; previous goes back along that order.
class PlayQueue {
  PlayQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  List<Track> _context = const [];

  /// Indexes into [_context] in play order: identity, or shuffled.
  List<int> _order = const [];

  /// Position of the current song in [_order].
  int _position = -1;
  bool _shuffle = false;
  Repeat repeat = Repeat.off;

  /// Previous restarts the current song once it has played longer than this.
  static const restartAfter = Duration(seconds: 3);

  bool get shuffle => _shuffle;
  List<Track> get context => _context;

  /// The current song, or null before anything was started.
  Track? get current => _position < 0 ? null : _context[_order[_position]];

  /// Makes [context] the play list and [index] in it the current song.
  Track start(List<Track> context, int index) {
    _context = List.unmodifiable(context);
    _order = List.generate(_context.length, (i) => i);
    _position = index;
    if (_shuffle) _shuffleKeepingCurrent();
    return current!;
  }

  /// Turns shuffle on or off; the current song stays current.
  set shuffle(bool on) {
    if (on == _shuffle) return;
    _shuffle = on;
    if (_position < 0) return;
    if (on) {
      _shuffleKeepingCurrent();
    } else {
      final index = _order[_position];
      _order = List.generate(_context.length, (i) => i);
      _position = index;
    }
  }

  /// Repeat off, then list, then one, then off again.
  Repeat cycleRepeat() =>
      repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];

  /// The song to play when the current one ends by itself, or null to stop.
  Track? next({required bool auto}) {
    if (_position < 0) return null;
    if (auto && repeat == Repeat.one) return current;
    var position = _position + 1;
    if (position >= _order.length) {
      if (auto && repeat == Repeat.off) return null;
      // A new round of shuffle gets a new order, not the same one again.
      if (_shuffle && _order.length > 1) _reshuffleRound();
      position = 0;
    }
    _position = position;
    return current;
  }

  /// What Previous does at [position] into the current song: null means
  /// restart the current song; otherwise the song to play instead.
  Track? previous(Duration position) {
    if (_position < 0) return null;
    if (position > restartAfter) return null;
    _position = (_position - 1) % _order.length;
    return current;
  }

  /// Indexes into [context] of up to [count] songs that play next by
  /// themselves (Up next), without moving. Wraps only with repeat list.
  List<int> upcoming(int count) {
    if (_position < 0) return const [];
    if (repeat == Repeat.one) return [_order[_position]];
    final result = <int>[];
    var position = _position;
    while (result.length < count) {
      position++;
      if (position >= _order.length) {
        if (repeat == Repeat.off || _order.length < 2) break;
        position = 0;
      }
      if (position == _position) break;
      result.add(_order[position]);
    }
    return result;
  }

  /// Puts the current song first and the rest in random order after it.
  void _shuffleKeepingCurrent() {
    final currentIndex = _order[_position];
    final rest = [
      for (var i = 0; i < _context.length; i++)
        if (i != currentIndex) i,
    ]..shuffle(_random);
    _order = [currentIndex, ...rest];
    _position = 0;
  }

  /// A fresh random order for the next round, not starting with the song
  /// that just ended (it would play twice in a row).
  void _reshuffleRound() {
    final last = _order.last;
    final order = List.generate(_context.length, (i) => i)..shuffle(_random);
    if (order.first == last) {
      final swap = 1 + _random.nextInt(order.length - 1);
      order[0] = order[swap];
      order[swap] = last;
    }
    _order = order;
  }
}
