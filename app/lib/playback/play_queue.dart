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
///
/// Songs the user queued ("Play next", "Add to queue") play before the rest
/// of the context, once each, and stay queued when another song is clicked.
class PlayQueue {
  PlayQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  List<Track> _context = const [];

  /// Songs waiting to play, first one next.
  final List<Track> _queued = [];

  /// Queued songs that already started. Kept so that previous can step back
  /// through them; a new round of the context drops them.
  final List<Track> _played = [];

  /// Entries in play order: identity, or shuffled. An entry below
  /// `_context.length` is an index into [_context]; a higher one is a song
  /// of [_played], placed at the moment it started. None lies ahead of
  /// [_position].
  List<int> _order = const [];

  /// Position of the current song in [_order].
  int _position = -1;
  bool _shuffle = false;
  Repeat repeat = Repeat.off;

  /// Previous restarts the current song once it has played longer than this.
  static const restartAfter = Duration(seconds: 3);

  bool get shuffle => _shuffle;
  List<Track> get context => _context;

  /// The songs waiting to play, first one next.
  List<Track> get queued => List.unmodifiable(_queued);

  /// The current song, or null before anything was started.
  Track? get current => _position < 0 ? null : _songAt(_order[_position]);

  /// Makes [context] the play list and [index] in it the current song. The
  /// songs waiting in the queue stay there.
  Track start(List<Track> context, int index) {
    _context = List.unmodifiable(context);
    _played.clear();
    _order = List.generate(_context.length, (i) => i);
    _position = index;
    if (_shuffle) _shuffleKeepingCurrent();
    return current!;
  }

  /// Puts [track] right after the current song, ahead of the queue.
  void playNext(Track track) => _queued.insert(0, track);

  /// Puts [track] at the end of the queue.
  void addToQueue(Track track) => _queued.add(track);

  /// Takes the song at [index] of [queued] out of the queue.
  void removeQueued(int index) => _queued.removeAt(index);

  /// Makes the song at [index] of [queued] the current song.
  Track takeQueued(int index) => _startQueued(_queued.removeAt(index));

  /// Turns shuffle on or off; the current song stays current.
  set shuffle(bool on) {
    if (on == _shuffle) return;
    _shuffle = on;
    if (_position < 0) return;
    if (on) {
      _shuffleKeepingCurrent();
    } else {
      // During a queued song the list goes on from the song before it.
      final entry = _order[_position];
      final listEntry = _order
          .take(_position + 1)
          .lastWhere(_isListEntry, orElse: () => -1);
      _order = List.generate(_context.length, (i) => i);
      _position = listEntry;
      if (entry != listEntry) _order.insert(++_position, entry);
    }
  }

  /// Repeat off, then list, then one, then off again.
  Repeat cycleRepeat() =>
      repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];

  /// The song to play when the current one ends by itself ([auto]) or Next
  /// is pressed, or null to stop. A queued song comes first, even on repeat
  /// one: a song the user asked for must not wait forever.
  Track? next({required bool auto}) {
    if (_queued.isNotEmpty) return _startQueued(_queued.removeAt(0));
    if (_position < 0) return null;
    if (auto && repeat == Repeat.one) return current;
    var position = _position + 1;
    if (position >= _order.length) {
      if (auto && repeat == Repeat.off) return null;
      // A new round of shuffle gets a new order, not the same one again.
      if (_shuffle && _context.length > 1) {
        _reshuffleRound();
      } else {
        _order.removeWhere((entry) => !_isListEntry(entry));
      }
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
    // A queued song plays once: going back past it takes it out of the way.
    if (!_isListEntry(_order[_position])) _order.removeAt(_position);
    _position = (_position - 1) % _order.length;
    return current;
  }

  /// Indexes into [context] of up to [count] songs of the list that play
  /// after the queue (Up next), without moving. Wraps only with repeat list.
  List<int> upcoming(int count) {
    if (_position < 0) return const [];
    if (repeat == Repeat.one) {
      final entry = _order[_position];
      return _queued.isEmpty && _isListEntry(entry) ? [entry] : const [];
    }
    final result = <int>[];
    var position = _position;
    while (result.length < count) {
      position++;
      if (position >= _order.length) {
        if (repeat == Repeat.off || _order.length < 2) break;
        position = 0;
      }
      if (position == _position) break;
      if (_isListEntry(_order[position])) result.add(_order[position]);
    }
    return result;
  }

  /// Whether an entry of [_order] is a song of [_context].
  bool _isListEntry(int entry) => entry < _context.length;

  Track _songAt(int entry) =>
      _isListEntry(entry) ? _context[entry] : _played[entry - _context.length];

  /// Makes queued [track] the current song, placed right after the song
  /// that was current. With nothing started it becomes a list of its own.
  Track _startQueued(Track track) {
    if (_position < 0) return start([track], 0);
    _played.add(track);
    _order.insert(++_position, _context.length + _played.length - 1);
    return track;
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
