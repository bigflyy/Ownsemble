import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/track.dart';
import 'play_queue.dart';
import 'player_service.dart';

/// What the player controls do: playing from a list, previous and next,
/// shuffle, repeat, auto-advance, seeking and volume. Records every song
/// that starts playing in the History.
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.player,
    required this.recordPlay,
    PlayQueue? queue,
  }) : queue = queue ?? PlayQueue() {
    _ended = player.ended.listen((_) => unawaited(_onEnded()));
  }

  final PlayerService player;
  final PlayQueue queue;

  /// Writes a History entry for a song that started playing.
  final void Function(Track track) recordPlay;

  late final StreamSubscription<void> _ended;

  /// Counts play requests, so an automatic skip stops when the user picks
  /// another song meanwhile.
  int _request = 0;

  double _volume = 100;
  bool _mutedByUser = false;
  bool _showRemaining = false;

  /// At most this many songs in a row are skipped because they cannot play
  /// (blocked by VK, gone and not stored) before auto-advance gives up.
  static const maxSkips = 20;

  double get volume => _volume;
  bool get mutedByUser => _mutedByUser;
  bool get shuffle => queue.shuffle;
  Repeat get repeat => queue.repeat;

  /// Whether the time label shows the remaining time instead of the total.
  bool get showRemaining => _showRemaining;

  /// A click on the song at [index] of [list]: the song that is already
  /// loaded pauses or resumes; any other song starts, and [list] becomes the
  /// list next and previous move in. A song that failed is retried.
  Future<PlayTiming?> playFrom(List<Track> list, int index) async {
    if (!player.isReady) return null;
    final track = list[index];
    if (track.id == player.current?.id && player.currentLoaded) {
      await player.playOrPause();
      return null;
    }
    return _play(queue.start(list, index));
  }

  Future<void> playOrPause() => player.playOrPause();

  /// The Next button: the next song of the list (wraps at the end).
  Future<PlayTiming?> next() async {
    final track = queue.next(auto: false);
    return track == null ? null : _play(track);
  }

  /// The Previous button: back to the start of the song after 3 s of it,
  /// else the previous song of the list.
  Future<PlayTiming?> previous() async {
    if (queue.current == null) return null;
    final track = queue.previous(player.position);
    if (track == null) {
      await player.seek(Duration.zero);
      return null;
    }
    return _play(track);
  }

  Future<void> seek(Duration to) => player.seek(to);

  void toggleShuffle() {
    queue.shuffle = !queue.shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    queue.cycleRepeat();
    notifyListeners();
  }

  void toggleRemaining() {
    _showRemaining = !_showRemaining;
    notifyListeners();
  }

  /// Sets the volume (0 to 100); moving the slider also unmutes.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100);
    if (_mutedByUser && _volume > 0) {
      _mutedByUser = false;
      await player.setMuted(false);
    }
    notifyListeners();
    await player.setVolume(_volume);
  }

  Future<void> toggleMute() async {
    _mutedByUser = !_mutedByUser;
    notifyListeners();
    await player.setMuted(_mutedByUser);
  }

  /// Plays [track] and records it in the History once sound starts.
  Future<PlayTiming> _play(Track track) async {
    final request = ++_request;
    final timing = await player.play(track);
    if (timing.ok && request == _request) recordPlay(track);
    notifyListeners();
    return timing;
  }

  /// A song played to its end: the next one per shuffle and repeat. Songs
  /// that cannot play are skipped, up to [maxSkips] in a row.
  Future<void> _onEnded() async {
    for (var skips = 0; skips < maxSkips; skips++) {
      final track = queue.next(auto: true);
      if (track == null) return;
      final request = _request + 1;
      final timing = await _play(track);
      // Stop once a song plays, when the user picked another song meanwhile,
      // or when repeat one would retry the same failing song.
      if (timing.ok || request != _request) return;
      if (queue.repeat == Repeat.one) return;
    }
  }

  @override
  void dispose() {
    _ended.cancel();
    super.dispose();
  }
}
