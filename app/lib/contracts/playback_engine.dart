class PlaybackState {
  final bool playing, buffering, completed;
  final Duration position, duration, buffer;
  final double volume;
  const PlaybackState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.volume = 0,
  });
}

class PlaybackLog {
  final String level, text;
  const PlaybackLog(this.level, this.text);
}

class PlaybackEvents {
  final Stream<bool> playing, buffering, completed;
  final Stream<Duration> position;
  final Stream<String> error;
  final Stream<PlaybackLog> log;
  const PlaybackEvents({
    required this.playing,
    required this.buffering,
    required this.completed,
    required this.position,
    required this.error,
    required this.log,
  });
}

abstract interface class PlaybackEngine {
  PlaybackState get state;
  PlaybackEvents get stream;
  Future<void> openLocal(String path, {bool play = true});
  Future<void> openStream(Uri uri, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  // Native clock verification is separate from delayed UI position events.
  Future<bool> isPaused();
  Future<double?> clockSeconds();
  Future<void> dispose();
}

typedef AudioDecoder = Future<double> Function(String path);
