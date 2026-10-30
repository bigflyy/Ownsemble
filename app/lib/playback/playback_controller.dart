import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/track.dart';
import '../vk/vk_client.dart';
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
    String? Function(String key)? readSetting,
    this._writeSetting,
  }) : queue = queue ?? PlayQueue() {
    final saved = double.tryParse(readSetting?.call(volumeSetting) ?? '');
    if (saved != null) _volume = saved.clamp(0, 100);
    _mutedByUser = readSetting?.call(muteSetting) == 'on';
    _ended = player.ended.listen((_) => unawaited(_onEnded()));
    player.playing.addListener(_onPlayingChanged);
  }

  /// Settings with the chosen volume and whether the user muted.
  static const volumeSetting = 'player.volume';
  static const muteSetting = 'player.mute';

  final PlayerService player;
  final PlayQueue queue;
  final void Function(String key, String? value)? _writeSetting;

  /// Writes a History entry for a song that started playing.
  final void Function(Track track) recordPlay;

  late final StreamSubscription<void> _ended;

  /// Counts play requests, so an automatic skip stops when the user picks
  /// another song meanwhile.
  int _request = 0;

  /// Whether nothing plays or is about to: nothing started yet, the list
  /// ended, or the last song failed. A paused song does not count.
  bool _idle = true;

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

  /// Moving back in a song that ended leaves it paused there, which is not
  /// idle: the song can go on from that place.
  Future<void> seek(Duration to) {
    _idle = false;
    return player.seek(to);
  }

  /// Sound from any cause means something plays, for example the last song
  /// of a list resumed after it ended.
  void _onPlayingChanged() {
    if (player.playing.value) _idle = false;
  }

  /// "Play next": [track] plays right after the current song.
  Future<void> playNext(Track track) {
    queue.playNext(track);
    return _queueGrew();
  }

  /// "Add to queue": [track] plays after the songs already queued.
  Future<void> addToQueue(Track track) {
    queue.addToQueue(track);
    return _queueGrew();
  }

  /// Takes the song at [index] of the queue out of it.
  void removeQueued(int index) {
    queue.removeQueued(index);
    notifyListeners();
  }

  /// A click on a queued song in Up next: it plays now.
  Future<PlayTiming?> playQueued(int index) async {
    if (!player.isReady) return null;
    return _play(queue.takeQueued(index));
  }

  /// With nothing playing a song just queued starts at once, since no song
  /// will end to make room for it.
  Future<void> _queueGrew() async {
    notifyListeners();
    if (!_idle || !player.isReady) return;
    final track = queue.next(auto: false);
    if (track != null) await _play(track);
  }

  /// Downloads [track] (keeps its audio for good). Returns why it failed,
  /// or null on success.
  Future<String?> download(Track track) async {
    final storage = player.storage;
    final vk = player.vk;
    if (storage == null) return 'no storage';
    try {
      VkStream? stream;
      await storage.download(
        track,
        () async {
          if (vk == null || track.sourceKey == null) return null;
          final resolved = await vk.resolveStream(
            track.sourceKey!,
            track.accessKey,
          );
          if (resolved.link == null) {
            throw StateError(noStreamReason(resolved));
          }
          stream = resolved;
          return resolved.link;
        },
        alternative: () async =>
            stream == null ? null : vk?.releaseLink(stream!),
      );
      return null;
    } catch (error) {
      return describePlayError(error);
    }
  }

  /// Makes a downloaded song plain cache again.
  void removeDownload(Track track) =>
      player.storage?.removeDownload(track, keep: {?player.current?.id});

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

  /// Sets the volume (0 to 100); moving the slider also unmutes. Called for
  /// every step of a drag, so it does not save: see [saveVolume].
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100);
    if (_mutedByUser && _volume > 0) {
      _mutedByUser = false;
      await player.setMuted(false);
    }
    notifyListeners();
    await player.setVolume(_volume);
  }

  /// Keeps the volume for the next run, once the slider is let go.
  void saveVolume() {
    _writeSetting?.call(volumeSetting, _volume.toStringAsFixed(1));
    _saveMute();
  }

  void _saveMute() =>
      _writeSetting?.call(muteSetting, _mutedByUser ? 'on' : 'off');

  Future<void> toggleMute() async {
    _mutedByUser = !_mutedByUser;
    _saveMute();
    notifyListeners();
    await player.setMuted(_mutedByUser);
  }

  /// Plays [track] and records it in the History once sound starts.
  Future<PlayTiming> _play(Track track) async {
    final request = ++_request;
    _idle = false;
    final timing = await player.play(track);
    if (request == _request) {
      if (timing.ok) {
        recordPlay(track);
      } else {
        _idle = true;
      }
    }
    notifyListeners();
    return timing;
  }

  /// A song played to its end: the next one per shuffle and repeat. Songs
  /// that cannot play are skipped, up to [maxSkips] in a row.
  Future<void> _onEnded() async {
    for (var skips = 0; skips < maxSkips; skips++) {
      final track = queue.next(auto: true);
      if (track == null) {
        _idle = true;
        return;
      }
      final request = _request + 1;
      final timing = await _play(track);
      // Stop once a song plays, when the user picked another song meanwhile,
      // or when repeat one would retry the same failing song.
      if (timing.ok || request != _request) return;
      if (queue.repeat == Repeat.one && queue.queued.isEmpty) return;
    }
  }

  @override
  void dispose() {
    player.playing.removeListener(_onPlayingChanged);
    _ended.cancel();
    super.dispose();
  }
}
